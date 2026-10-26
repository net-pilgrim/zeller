const std = @import("std");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const manager_mod = @import("manager.zig");
const runner_mod = @import("runner.zig");
const cli_mod = @import("cli.zig");

const VERSION = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const command = cli_mod.Cli.parse(args) catch |err| {
        switch (err) {
            error.MissingConfigArgument => {
                std.debug.print("Error: --config requires a file path argument.\n\n", .{});
            },
            error.NoCommandSpecified => {
                std.debug.print("Error: 'run' requires a command to execute (e.g. zeller run -- echo hello).\n\n", .{});
            },
        }
        printUsage();
        std.posix.exit(1);
    };

    switch (command) {
        .help => {
            printUsage();
        },
        .version => {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("zeller v{s} (Zig {s})\n", .{ VERSION, @import("builtin").zig_version_string });
        },
        .run => |r| {
            var cfg = config_mod.Config.findAndLoad(allocator, r.config_path) catch |err| {
                std.debug.print("Error loading config: {s}\n", .{@errorName(err)});
                std.posix.exit(1);
            };
            defer cfg.deinit();

            const mgr = manager_mod.Manager.init(allocator);
            var secrets = mgr.fetchAllSecrets(&cfg) catch |err| {
                std.debug.print("Error resolving secrets: {s}\n", .{@errorName(err)});
                std.posix.exit(1);
            };
            defer types.freeSecretMap(allocator, &secrets);

            const runner = runner_mod.Runner.init(allocator);
            const exit_code = runner.run(r.cmd_argv, &secrets) catch |err| {
                std.debug.print("Error executing command: {s}\n", .{@errorName(err)});
                std.posix.exit(1);
            };

            std.posix.exit(exit_code);
        },
        .env => |e| {
            var cfg = config_mod.Config.findAndLoad(allocator, e.config_path) catch |err| {
                std.debug.print("Error loading config: {s}\n", .{@errorName(err)});
                std.posix.exit(1);
            };
            defer cfg.deinit();

            const mgr = manager_mod.Manager.init(allocator);
            var secrets = mgr.fetchAllSecrets(&cfg) catch |err| {
                std.debug.print("Error resolving secrets: {s}\n", .{@errorName(err)});
                std.posix.exit(1);
            };
            defer types.freeSecretMap(allocator, &secrets);

            const stdout = std.io.getStdOut().writer();
            var it = secrets.iterator();
            while (it.next()) |entry| {
                try stdout.print("export {s}=\"", .{entry.key_ptr.*});
                for (entry.value_ptr.*) |byte| {
                    switch (byte) {
                        '"' => try stdout.writeAll("\\\""),
                        '\\' => try stdout.writeAll("\\\\"),
                        '$' => try stdout.writeAll("\\$"),
                        '`' => try stdout.writeAll("\\`"),
                        '\n' => try stdout.writeAll("\\n"),
                        '\r' => try stdout.writeAll("\\r"),
                        '\t' => try stdout.writeAll("\\t"),
                        else => try stdout.writeByte(byte),
                    }
                }
                try stdout.writeAll("\"\n");
            }
        },
        .show => |s| {
            var cfg = config_mod.Config.findAndLoad(allocator, s.config_path) catch |err| {
                std.debug.print("Error loading config: {s}\n", .{@errorName(err)});
                std.posix.exit(1);
            };
            defer cfg.deinit();

            const mgr = manager_mod.Manager.init(allocator);
            var secrets = mgr.fetchAllSecrets(&cfg) catch |err| {
                std.debug.print("Error resolving secrets: {s}\n", .{@errorName(err)});
                std.posix.exit(1);
            };
            defer types.freeSecretMap(allocator, &secrets);

            const stdout = std.io.getStdOut().writer();

            // Calculate max key length for formatting
            var max_key_len: usize = 3; // "Key".len
            var it = secrets.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.len > max_key_len) {
                    max_key_len = entry.key_ptr.len;
                }
            }

            try stdout.print("\nFound {d} secret(s):\n\n", .{secrets.count()});
            try stdout.print("  {s}", .{"KEY"});
            for ("KEY".len..max_key_len + 2) |_| try stdout.writeByte(' ');
            try stdout.print("{s}\n", .{"VALUE"});

            const dashes = try allocator.alloc(u8, max_key_len + 30);
            defer allocator.free(dashes);
            @memset(dashes, '-');
            try stdout.print("  {s}\n", .{dashes});

            var print_it = secrets.iterator();
            while (print_it.next()) |entry| {
                try stdout.print("  {s}", .{entry.key_ptr.*});
                for (entry.key_ptr.len..max_key_len + 2) |_| try stdout.writeByte(' ');
                if (s.reveal) {
                    try stdout.print("{s}\n", .{entry.value_ptr.*});
                } else {
                    const masked_len = @min(entry.value_ptr.len, 8);
                    const mask = "********"[0..@max(masked_len, 4)];
                    try stdout.print("{s}\n", .{mask});
                }
            }
            try stdout.writeAll("\n");
        },
    }
}

fn printUsage() void {
    const usage =
        \\zeller - High-performance secret manager and environment injector
        \\
        \\USAGE:
        \\  zeller run  [options] -- <command> [args...]   Run a command with injected secrets
        \\  zeller env  [options]                          Print export statements for shell eval
        \\  zeller show [options]                          List loaded secrets (values masked by default)
        \\  zeller version                                 Print version information
        \\  zeller help                                    Show this help message
        \\
        \\OPTIONS:
        \\  -c, --config <file>     Path to config file (.teller.yml, .zeller.json, or .env)
        \\      --reveal            Reveal unmasked values in 'show' command
        \\  -h, --help              Show help information
        \\  -v, --version           Show version
        \\
        \\SUPPORTED PROVIDERS:
        \\  - dotenv           Local environment files (.env, .env.local)
        \\  - exec             Arbitrary CLI / shell commands (op, aws, gcloud, scripts)
        \\  - hashicorp_vault  HashiCorp Vault REST API (KV v1 and KV v2)
        \\  - doppler          Doppler Secrets Management REST API
        \\
        \\EXAMPLES:
        \\  zeller run -- node index.js
        \\  zeller run -- cargo run
        \\  eval $(zeller env)
        \\  zeller show --reveal
        \\
    ;
    std.debug.print("{s}", .{usage});
}
