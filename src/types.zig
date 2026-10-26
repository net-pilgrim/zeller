const std = @import("std");

pub const SecretMap = std.StringHashMap([]const u8);

pub const SecretEntry = struct {
    key: []const u8,
    value: []const u8,
    source: []const u8,
};

pub fn cloneSecretMap(allocator: std.mem.Allocator, src: *const SecretMap) !SecretMap {
    var dest = SecretMap.init(allocator);
    var it = src.iterator();
    while (it.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_copy);
        const val_copy = try allocator.dupe(u8, entry.value_ptr.*);
        errdefer allocator.free(val_copy);
        try dest.put(key_copy, val_copy);
    }
    return dest;
}

pub fn freeSecretMap(allocator: std.mem.Allocator, map: *SecretMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}
