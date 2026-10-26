const std = @import("std");
const types = @import("types.zig");
const config_mod = @import("config.zig");
const provider_mod = @import("provider.zig");
const DotenvProvider = @import("providers/dotenv.zig").DotenvProvider;
const ExecProvider = @import("providers/exec.zig").ExecProvider;
const VaultProvider = @import("providers/vault.zig").VaultProvider;
const DopplerProvider = @import("providers/doppler.zig").DopplerProvider;
const AwsSsmProvider = @import("providers/aws_ssm.zig").AwsSsmProvider;

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
            const vault_addr_owned = std.process.getEnvVarOwned(self.allocator, "VAULT_ADDR") catch null;
            defer if (vault_addr_owned) |v| self.allocator.free(v);
            const vault_addr = vault_addr_owned orelse "http://127.0.0.1:8200";

            const vault_token_owned = std.process.getEnvVarOwned(self.allocator, "VAULT_TOKEN") catch null;
            defer if (vault_token_owned) |v| self.allocator.free(v);
            const vault_token = vault_token_owned orelse "";

            var p = VaultProvider.init(self.allocator, vault_addr, vault_token);
            var iface = p.provider();
            return iface.fetch(self.allocator, entry.path);
        } else if (std.mem.eql(u8, entry.kind, "doppler")) {
            const doppler_token_owned = std.process.getEnvVarOwned(self.allocator, "DOPPLER_TOKEN") catch null;
            defer if (doppler_token_owned) |v| self.allocator.free(v);
            const doppler_token = doppler_token_owned orelse "";

            var p = DopplerProvider.init(self.allocator, doppler_token);
            var iface = p.provider();
            return iface.fetch(self.allocator, entry.path);
        } else if (std.mem.eql(u8, entry.kind, "aws_ssm") or std.mem.eql(u8, entry.kind, "ssm")) {
            const region_owned = std.process.getEnvVarOwned(self.allocator, "AWS_REGION") catch
                (std.process.getEnvVarOwned(self.allocator, "AWS_DEFAULT_REGION") catch null);
            defer if (region_owned) |r| self.allocator.free(r);
            const region = region_owned orelse "us-east-1";

            const ak_owned = std.process.getEnvVarOwned(self.allocator, "AWS_ACCESS_KEY_ID") catch null;
            defer if (ak_owned) |ak| self.allocator.free(ak);
            const access_key = ak_owned orelse "test";

            const sk_owned = std.process.getEnvVarOwned(self.allocator, "AWS_SECRET_ACCESS_KEY") catch null;
            defer if (sk_owned) |sk| self.allocator.free(sk);
            const secret_key = sk_owned orelse "test";

            const ep_owned = std.process.getEnvVarOwned(self.allocator, "AWS_ENDPOINT_URL") catch
                (std.process.getEnvVarOwned(self.allocator, "AWS_SSM_ENDPOINT_URL") catch null);
            defer if (ep_owned) |ep| self.allocator.free(ep);

            var p = AwsSsmProvider.init(self.allocator, region, access_key, secret_key, ep_owned);
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
