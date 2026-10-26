const std = @import("std");
const types = @import("types.zig");
const SecretMap = types.SecretMap;

pub const ProviderConfig = struct {
    name: []const u8,
    path: []const u8,
    field: ?[]const u8 = null,
    target_key: ?[]const u8 = null, // If set, maps output directly to this env var name
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ctx: *anyopaque) []const u8,
        fetch: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!SecretMap,
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn name(self: Provider) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn fetch(self: Provider, allocator: std.mem.Allocator, path: []const u8) !SecretMap {
        return self.vtable.fetch(self.ptr, allocator, path);
    }

    pub fn deinit(self: Provider, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};
