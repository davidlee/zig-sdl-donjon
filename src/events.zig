const std = @import("std");
const EntityID = @import("entity.zig").EntityID;
const Slot = void; // TODO what's this look like?
//
pub const CardWithSlot = struct {
    card: EntityID,
    slot: Slot,
};

pub const CardWithEvent = struct {
    card: EntityID,
    event_index: usize, // in the EventSystem.current_events queue - must exist
};

// tagged union: events
pub const Event = union(enum) {
    entity_died: u32, // Payload: just the ID
    mob_died: EntityID,

    played_action: EntityID,
    played_reaction: CardWithEvent,

    equipped_item: CardWithSlot,
    unequipped_item: CardWithSlot,

    equipped_spell: CardWithSlot,
    unequipped_spell: CardWithSlot,

    equipped_passive: CardWithSlot,
    unequipped_passive: CardWithSlot,

    play_sound: struct { // Payload: struct
        id: u16,
        volume: f32,
    },
    player_turn_ended: void, // Payload: none
};

pub const EventSystem = struct {
    // We use two buffers to avoid "modifying the list while iterating it"
    current_events: std.ArrayList(Event),
    next_events: std.ArrayList(Event),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !EventSystem {
        return .{
            .current_events = try std.ArrayList(Event).initCapacity(alloc, 1000),
            .next_events = try std.ArrayList(Event).initCapacity(alloc, 1000),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *EventSystem) void {
        self.current_events.deinit(self.alloc);
        self.next_events.deinit(self.alloc);
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
