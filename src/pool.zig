const std = @import("std");
const entities = @import("entities.zig");

// TODO: Remove once Zig has finished migrating to unmanaged-style containers.
const ArrayList = std.ArrayListUnmanaged;
const TransformComponent = entities.TransformComponent;

pub const PoolId = struct {
    index: u32,

    pub fn equals(self: PoolId, other: ?PoolId) bool {
        return other != null and
            self.index == other.?.index;
    }
};

pub fn Pool(comptime PooledType: type) type {
    return struct {
        const Self = @This();

        const PoolEntry = struct {
            is_used: bool,
            item: PooledType,
        };

        entries: ArrayList(PoolEntry),
        entries_free: ArrayList(u32),

        pub fn init(initial_count: u32, allocator: std.mem.Allocator) !Self {
            var entries: ArrayList(PoolEntry) = .empty;
            var entries_slice = try entries.addManyAsSlice(allocator, initial_count);
            for (0..initial_count) |i| {
                entries_slice[i].is_used = false;
                entries_slice[i].item.pool_id = .{
                    .index = @intCast(i),
                };
            }

            var entries_free: ArrayList(u32) = .empty;
            var entries_free_slice = try entries_free.addManyAsSlice(allocator, initial_count);
            for (0..initial_count) |i| {
                entries_free_slice[i] = @intCast(i);
            }

            return Self{
                .entries = entries,
                .entries_free = entries_free,
            };
        }

        pub fn getOrCreate(self: *Self, allocator: std.mem.Allocator) !*PooledType {
            var result: *PooledType = undefined;

            if (self.entries_free.pop()) |free_index| {
                var entry = &self.entries.items[free_index];
                entry.is_used = true;

                result = &entry.item;
            } else {
                var entry = PoolEntry{
                    .is_used = true,
                    .item = undefined,
                };
                entry.item.pool_id.index = @intCast(self.entries.items.len);
                try self.entries.append(allocator, entry);

                result = &entry.item;
            }

            return result;
        }

        pub fn free(self: *Self, id: PoolId, allocator: std.mem.Allocator) !void {
            var entry = &self.entries.items[id.index];
            entry.is_used = false;

            try self.entries_free.append(allocator, id.index);
        }
    };
}
