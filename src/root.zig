pub const types = @import("types.zig");
pub const provider = @import("provider.zig");
pub const config = @import("config.zig");
pub const manager = @import("manager.zig");
pub const runner = @import("runner.zig");
pub const cli = @import("cli.zig");
pub const sigv4 = @import("crypto/sigv4.zig");
pub const providers = struct {
    pub const dotenv = @import("providers/dotenv.zig");
    pub const exec = @import("providers/exec.zig");
    pub const vault = @import("providers/vault.zig");
    pub const doppler = @import("providers/doppler.zig");
    pub const aws_ssm = @import("providers/aws_ssm.zig");
};

test {
    _ = @import("types.zig");
    _ = @import("provider.zig");
    _ = @import("config.zig");
    _ = @import("manager.zig");
    _ = @import("runner.zig");
    _ = @import("cli.zig");
    _ = @import("crypto/sigv4.zig");
    _ = @import("providers/dotenv.zig");
    _ = @import("providers/exec.zig");
    _ = @import("providers/vault.zig");
    _ = @import("providers/doppler.zig");
    _ = @import("providers/aws_ssm.zig");
}
