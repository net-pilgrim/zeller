const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../provider.zig");
const SecretMap = types.SecretMap;
const Provider = provider_mod.Provider;

pub const VaultProvider = struct {
    allocator: std.mem.Allocator,
    addr: []const u8,
    token: []const u8,

    pub fn init(allocator: std.mem.Allocator, addr: []const u8, token: []const u8) VaultProvider {
        return .{
            .allocator = allocator,
            .addr = addr,
            .token = token,
        };
    }

    pub fn provider(self: *VaultProvider) Provider {
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
        return "hashicorp_vault";
    }

    fn fetchImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!SecretMap {
        const self: *VaultProvider = @ptrCast(@alignCast(ctx));

        // Format full URL: <addr>/v1/<path>
        // Ensure addr doesn't end with slash and path doesn't start with slash
        const clean_addr = std.mem.trimRight(u8, self.addr, "/");
        const clean_path = std.mem.trimLeft(u8, path, "/");
        const url = try std.fmt.allocPrint(allocator, "{s}/v1/{s}", .{ clean_addr, clean_path });
        defer allocator.free(url);

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();

        const headers = [_]std.http.Header{
            .{ .name = "X-Vault-Token", .value = self.token },
            .{ .name = "Accept", .value = "application/json" },
        };

        const res = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = &headers,
            .response_storage = .{ .dynamic = &body },
        });

        if (res.status != .ok) {
            std.debug.print("vault request failed: status {d}\n", .{@intFromEnum(res.status)});
            return error.VaultRequestFailed;
        }

        return parseVaultJson(allocator, body.items);
    }

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    pub fn parseVaultJson(allocator: std.mem.Allocator, json_str: []const u8) !SecretMap {
        var map = SecretMap.init(allocator);
        errdefer types.freeSecretMap(allocator, &map);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            json_str,
            .{},
        );
        defer parsed.deinit();

        if (parsed.value != .object) {
            return error.InvalidVaultResponse;
        }

        // Vault KV v2 has { "data": { "data": { ... } } }
        // Vault KV v1 has { "data": { ... } }
        var target_obj: ?std.json.ObjectMap = null;

        if (parsed.value.object.get("data")) |data_val| {
            if (data_val == .object) {
                if (data_val.object.get("data")) |inner_data| {
                    if (inner_data == .object) {
                        target_obj = inner_data.object;
                    }
                }
                if (target_obj == null) {
                    target_obj = data_val.object;
                }
            }
        }

        if (target_obj == null) {
            target_obj = parsed.value.object;
        }

        if (target_obj) |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const k = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(k);

                const v: []const u8 = switch (entry.value_ptr.*) {
                    .string => |s| try allocator.dupe(u8, s),
                    .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
                    .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
                    .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
                    else => blk: {
                        var str_buf = std.ArrayList(u8).init(allocator);
                        defer str_buf.deinit();
                        try std.json.stringify(entry.value_ptr.*, .{}, str_buf.writer());
                        break :blk try str_buf.toOwnedSlice();
                    },
                };
                errdefer allocator.free(v);

                try map.put(k, v);
            }
        }

        return map;
    }
};

test "parse vault kv v2 response" {
    const allocator = std.testing.allocator;
    const kv2_response =
        \\{
        \\  "request_id": "test-id",
        \\  "data": {
        \\    "data": {
        \\      "API_KEY": "supersecret",
        \\      "PORT": 8080,
        \\      "DEBUG": true
        \\    },
        \\    "metadata": {
        \\      "version": 1
        \\    }
        \\  }
        \\}
    ;

    var secrets = try VaultProvider.parseVaultJson(allocator, kv2_response);
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("supersecret", secrets.get("API_KEY").?);
    try std.testing.expectEqualStrings("8080", secrets.get("PORT").?);
    try std.testing.expectEqualStrings("true", secrets.get("DEBUG").?);
}

test "parse vault kv v1 response" {
    const allocator = std.testing.allocator;
    const kv1_response =
        \\{
        \\  "data": {
        \\    "DB_PASS": "pass123"
        \\  }
        \\}
    ;

    var secrets = try VaultProvider.parseVaultJson(allocator, kv1_response);
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("pass123", secrets.get("DB_PASS").?);
}
