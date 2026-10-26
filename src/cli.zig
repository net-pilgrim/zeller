const std = @import("std");

pub const Command = union(enum) {
    run: struct {
        cmd_argv: []const []const u8,
        config_path: ?[]const u8,
    },
    env: struct {
        config_path: ?[]const u8,
    },
    show: struct {
        config_path: ?[]const u8,
        reveal: bool,
    },
    version,
    help,
};

pub const Cli = struct {
    pub fn parse(args: []const []const u8) !Command {
        if (args.len <= 1) {
            return .help;
        }

        var i: usize = 1;
        var config_path: ?[]const u8 = null;
        var subcommand: ?[]const u8 = null;
        var reveal = false;

        while (i < args.len) {
            const arg = args[i];

            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "help")) {
                return .help;
            } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "version")) {
                return .version;
            } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
                if (i + 1 >= args.len) return error.MissingConfigArgument;
                i += 1;
                config_path = args[i];
                i += 1;
            } else if (std.mem.startsWith(u8, arg, "--config=")) {
                config_path = arg["--config=".len..];
                i += 1;
            } else if (std.mem.eql(u8, arg, "--reveal")) {
                reveal = true;
                i += 1;
            } else if (std.mem.eql(u8, arg, "--")) {
                // If we encounter `--`, everything following is the child command
                i += 1;
                if (subcommand == null) {
                    subcommand = "run";
                }
                break;
            } else if (subcommand == null and !std.mem.startsWith(u8, arg, "-")) {
                subcommand = arg;
                i += 1;
                if (std.mem.eql(u8, arg, "run")) {
                    // Check if next arg is `--`
                    if (i < args.len and std.mem.eql(u8, args[i], "--")) {
                        i += 1;
                    }
                    break;
                }
            } else {
                i += 1;
            }
        }

        const sub = subcommand orelse return .help;

        if (std.mem.eql(u8, sub, "run")) {
            const cmd_argv = args[i..];
            if (cmd_argv.len == 0) {
                return error.NoCommandSpecified;
            }
            return .{
                .run = .{
                    .cmd_argv = cmd_argv,
                    .config_path = config_path,
                },
            };
        } else if (std.mem.eql(u8, sub, "env")) {
            return .{
                .env = .{
                    .config_path = config_path,
                },
            };
        } else if (std.mem.eql(u8, sub, "show")) {
            return .{
                .show = .{
                    .config_path = config_path,
                    .reveal = reveal,
                },
            };
        } else {
            return .help;
        }
    }
};

test "parse cli run with --" {
    const args = [_][]const u8{ "zeller", "run", "--", "echo", "hello", "world" };
    const cmd = try Cli.parse(&args);

    switch (cmd) {
        .run => |r| {
            try std.testing.expectEqual(@as(usize, 3), r.cmd_argv.len);
            try std.testing.expectEqualStrings("echo", r.cmd_argv[0]);
            try std.testing.expectEqualStrings("hello", r.cmd_argv[1]);
            try std.testing.expectEqualStrings("world", r.cmd_argv[2]);
            try std.testing.expectEqual(null, r.config_path);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse cli show with config and reveal" {
    const args = [_][]const u8{ "zeller", "--config", "custom.yml", "show", "--reveal" };
    const cmd = try Cli.parse(&args);

    switch (cmd) {
        .show => |s| {
            try std.testing.expectEqualStrings("custom.yml", s.config_path.?);
            try std.testing.expect(s.reveal);
        },
        else => return error.TestUnexpectedResult,
    }
}
