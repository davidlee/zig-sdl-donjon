const std = @import("std");

// tagged union: events
pub const Event = union(enum) {
    EntityDied: u32, // Payload: just the ID
    PlaySound: struct { // Payload: struct
        id: u16,
        volume: f32,
    },
    RestartLevel: void, // Payload: none
};

pub const EventSystem = struct {
    // We use two buffers to avoid "modifying the list while iterating it"
    current_events: std.ArrayList(Event),
    next_events: std.ArrayList(Event),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EventSystem {
        return .{
            .current_events = std.ArrayList(Event).init(allocator),
            .next_events = std.ArrayList(Event).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventSystem) void {
        self.current_events.deinit();
        self.next_events.deinit();
    }

    // Systems call this to queue something for NEXT frame
    pub fn push(self: *EventSystem, event: Event) !void {
        try self.next_events.append(event);
    }

    // Call this at the start of your frame (or end)
    pub fn swap_buffers(self: *EventSystem) void {
        // Clear the "old" current list (which we just finished processing)
        self.current_events.clearRetainingCapacity();

        // Swap the lists.
        // 'next' becomes 'current' (to be read).
        // 'current' becomes 'next' (empty, ready to be written to).
        std.mem.swap(std.ArrayList(Event), &self.current_events, &self.next_events);
    }
};
