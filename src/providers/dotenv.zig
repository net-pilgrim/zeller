const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../provider.zig");
const SecretMap = types.SecretMap;
const Provider = provider_mod.Provider;

pub const DotenvProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DotenvProvider {
        return .{ .allocator = allocator };
    }

    pub fn provider(self: *DotenvProvider) Provider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .name = getName,
        .fetch = fetchImpl,
        .deinit = deinitImpl,
    };

    fn getName(_: *anyopaque) []const u8 {
        return "dotenv";
    }

    fn fetchImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!SecretMap {
        const self: *DotenvProvider = @ptrCast(@alignCast(ctx));
        // Use the caller's allocator to return secrets
        var p = DotenvProvider.init(allocator);
        _ = self;
        return p.parseFile(path);
    }

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    pub fn parseSlice(self: DotenvProvider, content: []const u8) !SecretMap {
        var map = SecretMap.init(self.allocator);
        errdefer types.freeSecretMap(self.allocator, &map);

        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') {
                continue;
            }

            var line_slice = line;
            if (std.mem.startsWith(u8, line_slice, "export ")) {
                line_slice = std.mem.trimLeft(u8, line_slice[7..], " \t");
            }

            const eq_idx = std.mem.indexOfScalar(u8, line_slice, '=') orelse continue;
            const key_raw = std.mem.trim(u8, line_slice[0..eq_idx], " \t");
            if (key_raw.len == 0) continue;

            const val_raw = std.mem.trimLeft(u8, line_slice[eq_idx + 1 ..], " \t");
            const val_parsed = try parseValue(self.allocator, val_raw);
            errdefer self.allocator.free(val_parsed);

            const key_copy = try self.allocator.dupe(u8, key_raw);
            errdefer self.allocator.free(key_copy);

            if (map.fetchRemove(key_copy)) |old_entry| {
                self.allocator.free(old_entry.key);
                self.allocator.free(old_entry.value);
            }

            try map.put(key_copy, val_parsed);
        }

        return map;
    }

    pub fn parseFile(self: DotenvProvider, file_path: []const u8) !SecretMap {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        return self.parseSlice(content);
    }
};

fn parseValue(allocator: std.mem.Allocator, val_raw: []const u8) ![]const u8 {
    if (val_raw.len == 0) {
        return try allocator.dupe(u8, "");
    }

    if (val_raw[0] == '"') {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var i: usize = 1;
        while (i < val_raw.len) : (i += 1) {
            const c = val_raw[i];
            if (c == '"') {
                return result.toOwnedSlice();
            } else if (c == '\\' and i + 1 < val_raw.len) {
                i += 1;
                switch (val_raw[i]) {
                    'n' => try result.append('\n'),
                    'r' => try result.append('\r'),
                    't' => try result.append('\t'),
                    '\\' => try result.append('\\'),
                    '"' => try result.append('"'),
                    else => |esc| {
                        try result.append('\\');
                        try result.append(esc);
                    },
                }
            } else {
                try result.append(c);
            }
        }
        return result.toOwnedSlice();
    } else if (val_raw[0] == '\'') {
        const end_idx = std.mem.indexOfScalarPos(u8, val_raw, 1, '\'') orelse val_raw.len;
        return try allocator.dupe(u8, val_raw[1..end_idx]);
    } else {
        var end_idx: usize = val_raw.len;
        var in_whitespace = false;
        for (val_raw, 0..) |c, idx| {
            if (c == ' ' or c == '\t') {
                in_whitespace = true;
            } else if (c == '#' and in_whitespace) {
                end_idx = idx;
                break;
            } else {
                in_whitespace = false;
            }
        }

        const trimmed = std.mem.trimRight(u8, val_raw[0..end_idx], " \t\r");
        return try allocator.dupe(u8, trimmed);
    }
}

test "dotenv parsing basic" {
    const allocator = std.testing.allocator;
    var provider_instance = DotenvProvider.init(allocator);
    const p = provider_instance.provider();
    try std.testing.expectEqualStrings("dotenv", p.name());

    const input =
        \\# This is a comment
        \\DB_HOST=localhost
        \\DB_PORT=5432
        \\export SECRET_KEY="my-secret-key\nwith-newline"
        \\API_KEY='single-quoted-raw\nvalue'
        \\UNQUOTED_VAL=some_value # trailing comment
        \\EMPTY_VAL=
        \\
    ;

    var secrets = try provider_instance.parseSlice(input);
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("localhost", secrets.get("DB_HOST").?);
    try std.testing.expectEqualStrings("5432", secrets.get("DB_PORT").?);
    try std.testing.expectEqualStrings("my-secret-key\nwith-newline", secrets.get("SECRET_KEY").?);
    try std.testing.expectEqualStrings("single-quoted-raw\\nvalue", secrets.get("API_KEY").?);
    try std.testing.expectEqualStrings("some_value", secrets.get("UNQUOTED_VAL").?);
    try std.testing.expectEqualStrings("", secrets.get("EMPTY_VAL").?);
}
