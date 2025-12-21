const std = @import("std");
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event);

const EntityID = @import("entity.zig").EntityID;
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const World = @import("world.zig").World;

const cards = @import("cards.zig");

const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Expression = cards.Expression;
const Technique = cards.Technique;

pub const CommandHandler = struct {
    world: *World,

    pub fn init(world: *World) @This() {
        return @This(){
            .world = world,
        };
    }
    pub fn playCard(self: *World, card: cards.Instance) !bool {
        _ = .{self, card};
    }
};

// event -> state mutation
//
// keep the core as:
// State: all authoritative game data
// Command: a player/AI intent (“PlayCard {card_id, target}”)
// Resolver: validates + applies rules
// Event log: what happened (“DamageDealt”, “StatusApplied”, “CardMovedZones”)
// RNG stream: explicit, seeded, reproducible
//
// for:
//
// deterministic replays
// easy undo/redo (event-sourcing or snapshots)
// “what-if” simulations for AI / balance tools
// clean separation from rendering
//
// resolve a command into events, then apply events to state in a predictable way.
