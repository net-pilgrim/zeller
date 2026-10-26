const std = @import("std");
const types = @import("../types.zig");
const provider_mod = @import("../provider.zig");
const sigv4 = @import("../crypto/sigv4.zig");
const SecretMap = types.SecretMap;
const Provider = provider_mod.Provider;

pub const AwsSsmProvider = struct {
    allocator: std.mem.Allocator,
    region: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    endpoint_url: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        region: []const u8,
        access_key: []const u8,
        secret_key: []const u8,
        endpoint_url: ?[]const u8,
    ) AwsSsmProvider {
        return .{
            .allocator = allocator,
            .region = region,
            .access_key = access_key,
            .secret_key = secret_key,
            .endpoint_url = endpoint_url,
        };
    }

    pub fn provider(self: *AwsSsmProvider) Provider {
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
        return "aws_ssm";
    }

    fn fetchImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!SecretMap {
        const self: *AwsSsmProvider = @ptrCast(@alignCast(ctx));

        // Determine URL and Host
        var url: []const u8 = undefined;
        var host: []const u8 = undefined;
        var free_url = false;

        if (self.endpoint_url) |ep| {
            url = ep;
            const stripped = if (std.mem.startsWith(u8, ep, "http://"))
                ep["http://".len..]
            else if (std.mem.startsWith(u8, ep, "https://"))
                ep["https://".len..]
            else
                ep;
            const slash_idx = std.mem.indexOfScalar(u8, stripped, '/') orelse stripped.len;
            host = stripped[0..slash_idx];
        } else {
            url = try std.fmt.allocPrint(allocator, "https://ssm.{s}.amazonaws.com", .{self.region});
            host = try std.fmt.allocPrint(allocator, "ssm.{s}.amazonaws.com", .{self.region});
            free_url = true;
        }
        defer if (free_url) {
            allocator.free(url);
            allocator.free(host);
        };

        const is_path_prefix = std.mem.endsWith(u8, path, "/");
        const target_action = if (is_path_prefix)
            "AmazonSSM.GetParametersByPath"
        else
            "AmazonSSM.GetParameter";

        var payload: []const u8 = undefined;
        if (is_path_prefix) {
            payload = try std.fmt.allocPrint(
                allocator,
                "{{\"Path\":\"{s}\",\"Recursive\":true,\"WithDecryption\":true}}",
                .{path},
            );
        } else {
            payload = try std.fmt.allocPrint(
                allocator,
                "{{\"Name\":\"{s}\",\"WithDecryption\":true}}",
                .{path},
            );
        }
        defer allocator.free(payload);

        const now = std.time.timestamp();
        const dates = sigv4.SigV4.getDates(now);

        const auth_header = try sigv4.SigV4.buildAuthHeader(
            allocator,
            self.access_key,
            self.secret_key,
            self.region,
            "ssm",
            host,
            target_action,
            payload,
            dates,
        );
        defer allocator.free(auth_header);

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-amz-json-1.1" },
            .{ .name = "X-Amz-Target", .value = target_action },
            .{ .name = "X-Amz-Date", .value = &dates.amz_date },
            .{ .name = "Authorization", .value = auth_header },
        };

        const res = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = payload,
            .extra_headers = &headers,
            .response_storage = .{ .dynamic = &body },
        });

        if (res.status != .ok) {
            std.debug.print("SSM request failed with status {d}: {s}\n", .{ @intFromEnum(res.status), body.items });
            return error.SsmRequestFailed;
        }

        return parseSsmJson(allocator, body.items, path, is_path_prefix);
    }

    fn deinitImpl(_: *anyopaque, _: std.mem.Allocator) void {}

    pub fn parseSsmJson(
        allocator: std.mem.Allocator,
        json_str: []const u8,
        requested_path: []const u8,
        is_path_prefix: bool,
    ) !SecretMap {
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
            return error.InvalidSsmResponse;
        }

        if (is_path_prefix) {
            // GetParametersByPath response: { "Parameters": [ { "Name": "...", "Value": "..." } ] }
            const params_val = parsed.value.object.get("Parameters") orelse return error.MissingParameters;
            if (params_val != .array) return error.InvalidParametersFormat;

            for (params_val.array.items) |item| {
                if (item != .object) continue;
                const name_val = item.object.get("Name") orelse continue;
                const val_val = item.object.get("Value") orelse continue;
                if (name_val != .string or val_val != .string) continue;

                var key_raw = name_val.string;
                if (std.mem.startsWith(u8, key_raw, requested_path)) {
                    key_raw = key_raw[requested_path.len..];
                }
                key_raw = std.mem.trimLeft(u8, key_raw, "/");
                if (key_raw.len == 0) continue;

                const k = try allocator.dupe(u8, key_raw);
                errdefer allocator.free(k);
                const v = try allocator.dupe(u8, val_val.string);
                errdefer allocator.free(v);

                try map.put(k, v);
            }
        } else {
            // GetParameter response: { "Parameter": { "Name": "...", "Value": "..." } }
            const param_val = parsed.value.object.get("Parameter") orelse return error.MissingParameter;
            if (param_val != .object) return error.InvalidParameterFormat;

            const name_val = param_val.object.get("Name") orelse return error.MissingParameterName;
            const val_val = param_val.object.get("Value") orelse return error.MissingParameterValue;
            if (name_val != .string or val_val != .string) return error.InvalidParameterValue;

            // Extract basename
            const last_slash = std.mem.lastIndexOfScalar(u8, name_val.string, '/');
            const key_raw = if (last_slash) |idx| name_val.string[idx + 1 ..] else name_val.string;

            const k = try allocator.dupe(u8, key_raw);
            errdefer allocator.free(k);
            const v = try allocator.dupe(u8, val_val.string);
            errdefer allocator.free(v);

            try map.put(k, v);
        }

        return map;
    }
};

test "parse ssm GetParametersByPath json" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{
        \\  "Parameters": [
        \\    {
        \\      "Name": "/prod/myapp/DB_PORT",
        \\      "Type": "String",
        \\      "Value": "5432"
        \\    },
        \\    {
        \\      "Name": "/prod/myapp/SECRET_TOKEN",
        \\      "Type": "SecureString",
        \\      "Value": "token_xyz"
        \\    }
        \\  ]
        \\}
    ;

    var secrets = try AwsSsmProvider.parseSsmJson(allocator, json_str, "/prod/myapp/", true);
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("5432", secrets.get("DB_PORT").?);
    try std.testing.expectEqualStrings("token_xyz", secrets.get("SECRET_TOKEN").?);
}

test "parse ssm GetParameter json" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{
        \\  "Parameter": {
        \\    "Name": "/prod/myapp/API_KEY",
        \\    "Type": "SecureString",
        \\    "Value": "live_key_999"
        \\  }
        \\}
    ;

    var secrets = try AwsSsmProvider.parseSsmJson(allocator, json_str, "/prod/myapp/API_KEY", false);
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("live_key_999", secrets.get("API_KEY").?);
}
