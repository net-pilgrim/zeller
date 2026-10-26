const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../provider.zig");
const SecretMap = types.SecretMap;
const Provider = provider_mod.Provider;

pub const ExecProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ExecProvider {
        return .{ .allocator = allocator };
    }

    pub fn provider(self: *ExecProvider) Provider {
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
        return "exec";
    }

    fn fetchImpl(ctx: *anyopaque, allocator: std.mem.Allocator, command_str: []const u8) anyerror!SecretMap {
        const self: *ExecProvider = @ptrCast(@alignCast(ctx));
        _ = self;

        var map = SecretMap.init(allocator);
        errdefer types.freeSecretMap(allocator, &map);

        // Run the command via `sh -c "<command_str>"`
        const argv = [_][]const u8{ "sh", "-c", command_str };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        var stdout_list = std.ArrayList(u8).init(allocator);
        defer stdout_list.deinit();

        var stderr_list = std.ArrayList(u8).init(allocator);
        defer stderr_list.deinit();

        try child.collectOutput(&stdout_list, &stderr_list, 1024 * 1024);
        const term = try child.wait();

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    std.debug.print("exec provider command failed with code {d}: {s}\n", .{ code, stderr_list.items });
                    return error.CommandFailed;
                }
            },
            else => return error.CommandTerminatedAbnormally,
        }

        const raw_output = std.mem.trim(u8, stdout_list.items, " \t\r\n");

        // Try parsing output as JSON object: {"KEY": "VAL", ...}
        if (std.mem.startsWith(u8, raw_output, "{") and std.mem.endsWith(u8, raw_output, "}")) {
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                raw_output,
                .{},
            ) catch null;

            if (parsed) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    var it = p.value.object.iterator();
                    while (it.next()) |entry| {
                        const k = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(k);

                        const v: []const u8 = switch (entry.value_ptr.*) {
                            .string => |s| try allocator.dupe(u8, s),
                            else => blk: {
                                // Convert other types to JSON string representation
                                var str_buf = std.ArrayList(u8).init(allocator);
                                defer str_buf.deinit();
                                try std.json.stringify(entry.value_ptr.*, .{}, str_buf.writer());
                                break :blk try str_buf.toOwnedSlice();
                            },
                        };
                        errdefer allocator.free(v);

                        try map.put(k, v);
                    }
                    return map;
                }
            }
        }

        // If not JSON object, parse as dotenv-style key=value lines
        var line_it = std.mem.splitScalar(u8, raw_output, '\n');
        var parsed_any_kv = false;
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.indexOfScalar(u8, line, '=')) |eq_idx| {
                const k_raw = std.mem.trim(u8, line[0..eq_idx], " \t");
                const v_raw = std.mem.trim(u8, line[eq_idx + 1 ..], " \t\"");
                if (k_raw.len > 0) {
                    const k = try allocator.dupe(u8, k_raw);
                    errdefer allocator.free(k);
                    const v = try allocator.dupe(u8, v_raw);
                    errdefer allocator.free(v);
                    try map.put(k, v);
                    parsed_any_kv = true;
                }
            }
        }

        if (parsed_any_kv) {
            return map;
        }

        // If neither JSON nor KV, return raw output under a default "VALUE" key
        const k = try allocator.dupe(u8, "VALUE");
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, raw_output);
        errdefer allocator.free(v);
        try map.put(k, v);

        return map;
    }

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}
};

test "exec provider runs shell command and parses json" {
    const allocator = std.testing.allocator;
    var exec_p = ExecProvider.init(allocator);
    var p = exec_p.provider();

    var secrets = try p.fetch(allocator, "echo '{\"PORT\": \"8080\", \"STATUS\": \"ok\"}'");
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("8080", secrets.get("PORT").?);
    try std.testing.expectEqualStrings("ok", secrets.get("STATUS").?);
}

test "exec provider runs shell command and parses key-value" {
    const allocator = std.testing.allocator;
    var exec_p = ExecProvider.init(allocator);
    var p = exec_p.provider();

    var secrets = try p.fetch(allocator, "printf 'FOO=bar\\nBAZ=qux\\n'");
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("bar", secrets.get("FOO").?);
    try std.testing.expectEqualStrings("qux", secrets.get("BAZ").?);
}
