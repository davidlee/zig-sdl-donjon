const std = @import("std");
const EntityID = @import("entity.zig").EntityID;

// generational index - dispenses valid entity IDs (in the absence of an ECS)
// the generation is just a version number to guard against collisions / undefined
// behaviour in the event a previously dead entity's ID is recycled.
//
pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        // Parallel arrays (SoA-ish)
        items: std.ArrayList(T),
        generations: std.ArrayList(u32),

        // The "Freelist" - a stack of indices we can reuse
        free_indices: std.ArrayList(u32),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .items = std.ArrayList(T).init(allocator),
                .generations = std.ArrayList(u32).init(allocator),
                .free_indices = std.ArrayList(u32).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit();
            self.generations.deinit();
            self.free_indices.deinit();
        }

        // Create a new item and return its stable ID
        pub fn insert(self: *Self, item: T) !EntityID {
            if (self.free_indices.popOrNull()) |idx| {
                // REUSE SLOT:
                // Overwrite the data at the old index
                self.items.items[idx] = item;
                // Update generation is NOT needed here; we increment on *deletion*
                // so the current generation is already "fresh" for this new user.
                return EntityID{ .index = idx, .generation = self.generations.items[idx] };
            } else {
                // NEW SLOT:
                const idx = @as(u32, @intCast(self.items.items.len));
                try self.items.append(item);
                try self.generations.append(1); // Generation starts at 1
                return EntityID{ .index = idx, .generation = 1 };
            }
        }

        // Get pointer to item IF the ID is valid
        pub fn get(self: *Self, id: EntityID) ?*T {
            // 1. Bounds check
            if (id.index >= self.items.items.len) return null;

            // 2. Generation check
            // If the slot's generation doesn't match the ID's generation,
            // it means this slot was freed and reused for someone else.
            if (self.generations.items[id.index] != id.generation) return null;

            return &self.items.items[id.index];
        }

        // Remove an item, invalidating all IDs pointing to it
        pub fn remove(self: *Self, id: EntityID) void {
            // Verify ID is valid before deleting
            if (id.index >= self.items.items.len) return;
            if (self.generations.items[id.index] != id.generation) return;

            // Increment generation so all existing IDs for this slot become invalid
            self.generations.items[id.index] += 1;

            // Add index to freelist so we can reuse it later
            self.free_indices.append(id.index) catch unreachable; // memory error handling omitted for brevity
        }
    };
}
