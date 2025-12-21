const std = @import("std");
// const assert = std.testing.expectEqual
const lib = @import("infra");
const cards = @import("cards.zig");
const Cost = @import("cards.zig").Cost;

// const Event = @import("events.zig").Event;
// const EventTag = std.meta.Tag(Event); // std.meta.activeTag(event) for cmp
// const EntityID = @import("entity.zig").EntityID;
// const damage = @import("damage.zig");
// const stats = @import("stats.zig");

pub const ID= ?u32;

pub const Spec= struct {
    id: ID,
    duration: f32 = 1.0,
    cost: Cost,
    // animation 
    // 
};