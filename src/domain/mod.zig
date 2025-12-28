// Domain module - pure game logic, no SDL dependencies
//
// Re-exports for convenience. Individual files can also be imported directly.

pub const world = @import("world.zig");
pub const events = @import("events.zig");
pub const apply = @import("apply.zig");
pub const tick = @import("tick.zig");
pub const resolution = @import("resolution.zig");
pub const random = @import("random.zig");
pub const entity = @import("entity.zig");
pub const slot_map = @import("slot_map.zig");
pub const cards = @import("cards.zig");
pub const card_list = @import("card_list.zig");
pub const deck = @import("deck.zig");
pub const combat = @import("combat.zig");
pub const body = @import("body.zig");
pub const damage = @import("damage.zig");
pub const armour = @import("armour.zig");
pub const weapon = @import("weapon.zig");
pub const weapon_list = @import("weapon_list.zig");
pub const stats = @import("stats.zig");
pub const inventory = @import("inventory.zig");
pub const player = @import("player.zig");
pub const rules = @import("rules.zig");

// Common type aliases
pub const World = world.World;
pub const Event = events.Event;
pub const EventSystem = events.EventSystem;
