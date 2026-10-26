const std = @import("std");
const types = @import("types.zig");

pub const Runner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Runner {
        return .{ .allocator = allocator };
    }

    pub fn run(self: Runner, argv: []const []const u8, secrets: *const types.SecretMap) !u8 {
        if (argv.len == 0) {
            return error.EmptyCommand;
        }

        var env_map = try std.process.getEnvMap(self.allocator);
        defer env_map.deinit();

        var it = secrets.iterator();
        while (it.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        var child = std.process.Child.init(argv, self.allocator);
        child.env_map = &env_map;
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        const term = try child.wait();

        switch (term) {
            .Exited => |code| return code,
            .Signal => |sig| return @as(u8, @truncate(128 + @as(u32, @intCast(sig)))),
            .Stopped => |sig| return @as(u8, @truncate(128 + @as(u32, @intCast(sig)))),
            .Unknown => |code| return @as(u8, @truncate(@as(u32, @intCast(code)))),
        }
    }
};

test "runner executes subprocess with injected env" {
    const allocator = std.testing.allocator;
    const runner = Runner.init(allocator);

    var secrets = types.SecretMap.init(allocator);
    defer types.freeSecretMap(allocator, &secrets);

    const k = try allocator.dupe(u8, "ZELLER_TEST_VAR");
    const v = try allocator.dupe(u8, "zeller_magic_value");
    try secrets.put(k, v);

    const argv = [_][]const u8{ "sh", "-c", "test \"$ZELLER_TEST_VAR\" = \"zeller_magic_value\"" };
    const exit_code = try runner.run(&argv, &secrets);
    try std.testing.expectEqual(@as(u8, 0), exit_code);
}
