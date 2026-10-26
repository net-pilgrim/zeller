const std = @import("std");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const provider_mod = @import("provider.zig");
const DotenvProvider = @import("providers/dotenv.zig").DotenvProvider;
const ExecProvider = @import("providers/exec.zig").ExecProvider;
const VaultProvider = @import("providers/vault.zig").VaultProvider;
const DopplerProvider = @import("providers/doppler.zig").DopplerProvider;

pub const Manager = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn fetchAllSecrets(self: Manager, cfg: *const config_mod.Config) !types.SecretMap {
        var merged = types.SecretMap.init(self.allocator);
        errdefer types.freeSecretMap(self.allocator, &merged);

        for (cfg.providers.items) |entry| {
            var prov_map = try self.fetchFromEntry(entry);
            defer types.freeSecretMap(self.allocator, &prov_map);

            var it = prov_map.iterator();
            while (it.next()) |item| {
                const key_name = if (entry.target_key) |k| k else item.key_ptr.*;

                // If filtering by specific field, ignore other keys
                if (entry.field) |f| {
                    if (!std.mem.eql(u8, item.key_ptr.*, f)) {
                        continue;
                    }
                }

                const k_copy = try self.allocator.dupe(u8, key_name);
                errdefer self.allocator.free(k_copy);

                const v_copy = try self.allocator.dupe(u8, item.value_ptr.*);
                errdefer self.allocator.free(v_copy);

                if (merged.fetchRemove(k_copy)) |old_entry| {
                    self.allocator.free(old_entry.key);
                    self.allocator.free(old_entry.value);
                }

                try merged.put(k_copy, v_copy);
            }
        }

        return merged;
    }

    fn fetchFromEntry(self: Manager, entry: config_mod.ProviderEntry) !types.SecretMap {
        if (std.mem.eql(u8, entry.kind, "dotenv")) {
            var p = DotenvProvider.init(self.allocator);
            return p.parseFile(entry.path);
        } else if (std.mem.eql(u8, entry.kind, "exec")) {
            var p = ExecProvider.init(self.allocator);
            var iface = p.provider();
            return iface.fetch(self.allocator, entry.path);
        } else if (std.mem.eql(u8, entry.kind, "vault") or std.mem.eql(u8, entry.kind, "hashicorp_vault")) {
            const vault_addr = std.posix.getenv("VAULT_ADDR") orelse "http://127.0.0.1:8200";
            const vault_token = std.posix.getenv("VAULT_TOKEN") orelse "";
            var p = VaultProvider.init(self.allocator, vault_addr, vault_token);
            var iface = p.provider();
            return iface.fetch(self.allocator, entry.path);
        } else if (std.mem.eql(u8, entry.kind, "doppler")) {
            const doppler_token = std.posix.getenv("DOPPLER_TOKEN") orelse "";
            var p = DopplerProvider.init(self.allocator, doppler_token);
            var iface = p.provider();
            return iface.fetch(self.allocator, entry.path);
        } else {
            std.debug.print("unrecognized provider kind: {s}\n", .{entry.kind});
            return error.UnknownProviderKind;
        }
    }
};

test "manager merges dotenv and exec providers" {
    const allocator = std.testing.allocator;
    const mgr = Manager.init(allocator);

    var cfg = config_mod.Config.init(allocator);
    defer cfg.deinit();

    const kind = try allocator.dupe(u8, "exec");
    const path = try allocator.dupe(u8, "printf 'SVC_NAME=zeller\\nPORT=9999\\n'");
    try cfg.providers.append(.{ .kind = kind, .path = path });

    var secrets = try mgr.fetchAllSecrets(&cfg);
    defer types.freeSecretMap(allocator, &secrets);

    try std.testing.expectEqualStrings("zeller", secrets.get("SVC_NAME").?);
    try std.testing.expectEqualStrings("9999", secrets.get("PORT").?);
}
