const std = @import("std");
const lib = @import("infra");

const damage = @import("damage.zig");
const stats = @import("stats.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const combat = @import("combat.zig");
const events = @import("events.zig");
const world = @import("world.zig");
const random = @import("random.zig");
const entity = lib.entity;
const tick = @import("tick.zig");
const combat = @import("combat.zig");

const Event = events.Event;
const EventSystem = events.EventSystem;
const EventTag = std.meta.Tag(Event);
const World = world.World;
const Agent = combat.Agent;
const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Expression = cards.Expression;
const Technique = cards.Technique;
const AIDirector = combat.AIDirector;

// pub const PlayCardStrategy = struct {
//     // alloc?
//     agent: *Agent,
//     events: *EventSystem,
//
//     pub fn init(agent: *Agent, events: *EventSystem) PlayCardStrategy {
//         return PlayCardStrategy{
//             .agent = agent,
//             .events = events,
//         };
//     }
//
//     fn strategy(self: *PlayCardStrategy) anytype {}
//
//     pub fn playCards(self: *PlayCardStrategy) !void {}
// };
//
// pub const SimplePlayCardStrategy = struct {
//     // alloc?
//     agent: *Agent,
//     events: *EventSystem,
//
//     pub fn init(agent: *Agent, events: *EventSystem) PlayCardStrategy {}
// };
