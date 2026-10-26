const std = @import("std");

pub const ProviderEntry = struct {
    kind: []const u8,
    path: []const u8,
    field: ?[]const u8 = null,
    target_key: ?[]const u8 = null,
};

pub const Config = struct {
    project: ?[]const u8 = null,
    providers: std.ArrayList(ProviderEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .project = null,
            .providers = std.ArrayList(ProviderEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        if (self.project) |p| {
            self.allocator.free(p);
        }
        for (self.providers.items) |entry| {
            self.allocator.free(entry.kind);
            self.allocator.free(entry.path);
            if (entry.field) |f| self.allocator.free(f);
            if (entry.target_key) |k| self.allocator.free(k);
        }
        self.providers.deinit();
    }

    pub fn parseJson(allocator: std.mem.Allocator, json_str: []const u8) !Config {
        var cfg = Config.init(allocator);
        errdefer cfg.deinit();

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            json_str,
            .{},
        );
        defer parsed.deinit();

        if (parsed.value != .object) {
            return error.InvalidConfigFormat;
        }

        if (parsed.value.object.get("project")) |proj| {
            if (proj == .string) {
                cfg.project = try allocator.dupe(u8, proj.string);
            }
        }

        // Support "providers": [ { "kind": "...", "path": "..." } ]
        if (parsed.value.object.get("providers")) |prov_val| {
            if (prov_val == .array) {
                for (prov_val.array.items) |item| {
                    if (item != .object) continue;
                    const kind_val = item.object.get("kind") orelse continue;
                    const path_val = item.object.get("path") orelse continue;
                    if (kind_val != .string or path_val != .string) continue;

                    const kind = try allocator.dupe(u8, kind_val.string);
                    errdefer allocator.free(kind);
                    const path = try allocator.dupe(u8, path_val.string);
                    errdefer allocator.free(path);

                    var field: ?[]const u8 = null;
                    if (item.object.get("field")) |f| {
                        if (f == .string) field = try allocator.dupe(u8, f.string);
                    }
                    var target_key: ?[]const u8 = null;
                    if (item.object.get("key")) |k| {
                        if (k == .string) target_key = try allocator.dupe(u8, k.string);
                    }

                    try cfg.providers.append(.{
                        .kind = kind,
                        .path = path,
                        .field = field,
                        .target_key = target_key,
                    });
                }
            } else if (prov_val == .object) {
                // Support "providers": { "dotenv": { "path": ".env" }, ... }
                var it = prov_val.object.iterator();
                while (it.next()) |entry| {
                    const kind_name = entry.key_ptr.*;
                    if (entry.value_ptr.* == .object) {
                        const obj = entry.value_ptr.*.object;
                        var path_str: ?[]const u8 = null;

                        if (obj.get("path")) |p| {
                            if (p == .string) path_str = p.string;
                        } else if (obj.get("env")) |env_val| {
                            if (env_val == .object) {
                                if (env_val.object.get("path")) |p| {
                                    if (p == .string) path_str = p.string;
                                }
                            }
                        }

                        if (path_str) |p| {
                            const kind = try allocator.dupe(u8, kind_name);
                            errdefer allocator.free(kind);
                            const path = try allocator.dupe(u8, p);
                            errdefer allocator.free(path);

                            try cfg.providers.append(.{
                                .kind = kind,
                                .path = path,
                            });
                        }
                    }
                }
            }
        }

        return cfg;
    }

    /// Lightweight parser for Teller's YAML format (.teller.yml)
    pub fn parseYaml(allocator: std.mem.Allocator, yaml_str: []const u8) !Config {
        var cfg = Config.init(allocator);
        errdefer cfg.deinit();

        var in_providers = false;
        var current_provider: ?[]const u8 = null;
        var current_provider_indent: usize = 0;

        var line_it = std.mem.splitScalar(u8, yaml_str, '\n');
        while (line_it.next()) |raw_line| {
            // Remove comments
            var line = raw_line;
            if (std.mem.indexOfScalar(u8, line, '#')) |hash_pos| {
                line = line[0..hash_pos];
            }
            if (line.len == 0) continue;

            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Count leading spaces
            var indent: usize = 0;
            while (indent < line.len and line[indent] == ' ') : (indent += 1) {}

            if (indent == 0) {
                if (std.mem.startsWith(u8, trimmed, "project:")) {
                    const val = stripQuotes(trimmed["project:".len..]);
                    if (val.len > 0) {
                        cfg.project = try allocator.dupe(u8, val);
                    }
                } else if (std.mem.startsWith(u8, trimmed, "providers:")) {
                    in_providers = true;
                    current_provider = null;
                } else {
                    in_providers = false;
                    current_provider = null;
                }
                continue;
            }

            if (in_providers) {
                if (current_provider == null or indent <= current_provider_indent) {
                    // New provider under providers, e.g. "  dotenv:" or "  hashicorp_vault:"
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_idx| {
                        const prov_name = std.mem.trim(u8, trimmed[0..colon_idx], " \t");
                        current_provider = prov_name;
                        current_provider_indent = indent;
                    }
                } else if (current_provider) |prov| {
                    // Inside provider block, look for "path: <val>"
                    if (std.mem.startsWith(u8, trimmed, "path:")) {
                        const path_val = stripQuotes(trimmed["path:".len..]);
                        if (path_val.len > 0) {
                            const kind = try allocator.dupe(u8, prov);
                            errdefer allocator.free(kind);
                            const path = try allocator.dupe(u8, path_val);
                            errdefer allocator.free(path);

                            try cfg.providers.append(.{
                                .kind = kind,
                                .path = path,
                            });
                        }
                    }
                }
            }
        }

        return cfg;
    }

    pub fn findAndLoad(allocator: std.mem.Allocator, explicit_path: ?[]const u8) !Config {
        if (explicit_path) |p| {
            return loadFromFile(allocator, p);
        }

        const candidates = [_][]const u8{
            ".zeller.json",
            ".zeller.yaml",
            ".zeller.yml",
            ".teller.yml",
            ".teller.yaml",
            ".env",
        };

        for (candidates) |candidate| {
            if (std.fs.cwd().openFile(candidate, .{})) |file| {
                file.close();
                return loadFromFile(allocator, candidate);
            } else |_| {}
        }

        return error.NoConfigFileFound;
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, file_path: []const u8) !Config {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // If file is .env, construct a dotenv provider config directly
        if (std.mem.endsWith(u8, file_path, ".env")) {
            var cfg = Config.init(allocator);
            errdefer cfg.deinit();

            const kind = try allocator.dupe(u8, "dotenv");
            errdefer allocator.free(kind);
            const path = try allocator.dupe(u8, file_path);
            errdefer allocator.free(path);

            try cfg.providers.append(.{
                .kind = kind,
                .path = path,
            });
            return cfg;
        }

        // Try JSON if ends with .json or starts with '{'
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (std.mem.endsWith(u8, file_path, ".json") or std.mem.startsWith(u8, trimmed, "{")) {
            return parseJson(allocator, content);
        }

        // Otherwise try YAML
        return parseYaml(allocator, content);
    }
};

fn stripQuotes(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r");
    if (trimmed.len >= 2) {
        if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
            (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
        {
            return trimmed[1 .. trimmed.len - 1];
        }
    }
    return trimmed;
}

test "parse zeller json config" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{
        \\  "project": "my-service",
        \\  "providers": [
        \\    { "kind": "dotenv", "path": ".env.local" },
        \\    { "kind": "vault", "path": "secret/data/prod" }
        \\  ]
        \\}
    ;

    var cfg = try Config.parseJson(allocator, json_str);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("my-service", cfg.project.?);
    try std.testing.expectEqual(@as(usize, 2), cfg.providers.items.len);
    try std.testing.expectEqualStrings("dotenv", cfg.providers.items[0].kind);
    try std.testing.expectEqualStrings(".env.local", cfg.providers.items[0].path);
    try std.testing.expectEqualStrings("vault", cfg.providers.items[1].kind);
    try std.testing.expectEqualStrings("secret/data/prod", cfg.providers.items[1].path);
}

test "parse teller yaml config" {
    const allocator = std.testing.allocator;
    const yaml_str =
        \\project: backend-api
        \\providers:
        \\  dotenv:
        \\    env:
        \\      path: .env
        \\  hashicorp_vault:
        \\    env:
        \\      path: secret/data/app
        \\  exec:
        \\    path: op read op://dev/key
    ;

    var cfg = try Config.parseYaml(allocator, yaml_str);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("backend-api", cfg.project.?);
    try std.testing.expectEqual(@as(usize, 3), cfg.providers.items.len);
    try std.testing.expectEqualStrings("dotenv", cfg.providers.items[0].kind);
    try std.testing.expectEqualStrings(".env", cfg.providers.items[0].path);
    try std.testing.expectEqualStrings("hashicorp_vault", cfg.providers.items[1].kind);
    try std.testing.expectEqualStrings("secret/data/app", cfg.providers.items[1].path);
    try std.testing.expectEqualStrings("exec", cfg.providers.items[2].kind);
    try std.testing.expectEqualStrings("op read op://dev/key", cfg.providers.items[2].path);
}
