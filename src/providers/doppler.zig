const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../provider.zig");
const SecretMap = types.SecretMap;
const Provider = provider_mod.Provider;

pub const DopplerProvider = struct {
    allocator: std.mem.Allocator,
    token: []const u8,

    pub fn init(allocator: std.mem.Allocator, token: []const u8) DopplerProvider {
        return .{
            .allocator = allocator,
            .token = token,
        };
    }

    pub fn provider(self: *DopplerProvider) Provider {
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
        return "doppler";
    }

    fn fetchImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!SecretMap {
        const self: *DopplerProvider = @ptrCast(@alignCast(ctx));

        // Doppler URL: if path has query or custom endpoint, use it; default to secrets endpoint
        var url_buf: []const u8 = undefined;
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
            url_buf = try allocator.dupe(u8, path);
        } else if (path.len > 0) {
            url_buf = try std.fmt.allocPrint(allocator, "https://api.doppler.com/v1/configs/config/secrets?{s}", .{path});
        } else {
            url_buf = try allocator.dupe(u8, "https://api.doppler.com/v1/configs/config/secrets");
        }
        defer allocator.free(url_buf);

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();

        const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.token});
        defer allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Accept", .value = "application/json" },
        };

        const res = try client.fetch(.{
            .location = .{ .url = url_buf },
            .method = .GET,
            .extra_headers = &headers,
            .response_storage = .{ .dynamic = &body },
        });

        if (res.status != .ok) {
            std.debug.print("doppler request failed: status {d}\n", .{@intFromEnum(res.status)});
            return error.DopplerRequestFailed;
        }

        return parseDopplerJson(allocator, body.items);
    }

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    pub fn parseDopplerJson(allocator: std.mem.Allocator, json_str: []const u8) !SecretMap {
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
            return error.InvalidDopplerResponse;
        }

        const secrets_obj = parsed.value.object.get("secrets") orelse return error.MissingSecretsKey;
        if (secrets_obj != .object) {
            return error.InvalidSecretsFormat;
        }

        var it = secrets_obj.object.iterator();
        while (it.next()) |entry| {
            const k = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(k);

            var val_str: ?[]const u8 = null;

            switch (entry.value_ptr.*) {
                .object => |obj| {
                    if (obj.get("computed")) |c| {
                        if (c == .string) val_str = c.string;
                    }
                    if (val_str == null) {
                        if (obj.get("raw")) |r| {
                            if (r == .string) val_str = r.string;
                        }
                    }
                },
                .string => |s| {
                    val_str = s;
                },
                else => {},
            }

            const final_val = val_str orelse "";
            const v = try allocator.dupe(u8, final_val);
            errdefer allocator.free(v);

            try map.put(k, v);
        }

        return map;
    }
};

test "parse doppler json response" {
    const allocator = std.testing.allocator;
    const doppler_response =
        \\{
        \\  "secrets": {
        \\    "STRIPE_KEY": {
        \\      "raw": "sk_test_123",
        \\      "computed": "sk_test_123"
        \\    },
        \\    "DATABASE_URL": {
        \\      "raw": "postgres://localhost",
        \\      "computed": "postgres://localhost"
        \\    }
        \\  }
        \\}
    ;

    var secrets = try DopplerProvider.parseDopplerJson(allocator, doppler_response);
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("sk_test_123", secrets.get("STRIPE_KEY").?);
    try std.testing.expectEqualStrings("postgres://localhost", secrets.get("DATABASE_URL").?);
}
