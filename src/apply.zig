const std = @import("std");
const lib = @import("infra");

const damage = @import("damage.zig");
const stats = @import("stats.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const combat = @import("combat.zig");
const events = @import("events.zig");
const world = @import("world.zig");
const entity = @import("entity.zig");

const Event = events.Event;
const EventSystem = events.EventSystem;
const EventTag = std.meta.Tag(Event);
const World = world.World;
const Player = @import("player.zig").Player;
const Mob = combat.Mob;
const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Expression = cards.Expression;
const Technique = cards.Technique;

const log = std.debug.print;

pub const CommandError = error{
    CommandInvalid,
    InsufficientStamina,
    InsufficientTime,
    InvalidGameState,
    CardNotInHand,
    NotImplemented,
};

const EffectContext = struct {
    card: *cards.Instance,
    effect: *const cards.Effect,
    target: *std.ArrayList(*Mob), // TODO: will need to be polymorphic (player, body part)
    actor: *Player,
    technique: ?TechniqueContext = null,

    fn applyModifiers(self: *EffectContext, alloc: std.mem.Allocator) void {
        if (self.technique) |tc| {
            var instances = try std.ArrayList(damage.Instances).initCapacity(alloc, tc.base_damage.instances.len);
            defer instances.deinit(alloc);

            // const t = tc.technique;
            // const bd = tc.base_damage;
            const eff = blk: switch (tc.base_damage.scaling.stats) {
                .stat => |accessor| self.actor.stats.get(accessor),
                .average => |arr| {
                    const a = self.actor.stats.get(arr[0]);
                    const b = self.actor.stats.get(arr[1]);
                    break :blk (a + b) / 2.0;
                },
            } * tc.base_damage.scaling.ratio;
            for (tc.base_damage.instances) |inst| {
                const adjusted = damage.Instance{
                    .amount = eff * inst.amount,
                    .types = inst.types, // same slice
                };
                try instances.append(alloc, adjusted);
            }
            tc.calc_damage = try instances.toOwnedSlice(alloc);
        }
    }
};

const TechniqueContext = struct {
    technique: *const cards.Technique,
    base_damage: *const damage.Base,
    calc_damage: ?[]damage.Instance = null,
    calc_difficulty: ?f32 = null,
};

pub const EventProcessor = struct {
    world: *World,
    pub fn init(ctx: *World) EventProcessor {
        return EventProcessor{
            .world = ctx,
        };
    }

    pub fn dispatchEvent(self: *EventProcessor, event_system: *EventSystem) !bool {
        const result = event_system.pop();
        if (result) |event| {
            // std.debug.print("             -> dispatchEvent: {}\n", .{event});
            switch (event) {
                .game_state_transitioned_to => |state| {
                    std.debug.print("\n game state ==> {}\n", .{state});
                    for (self.world.encounter.?.enemies.items) |mob| {
                        for (mob.in_play.items) |instance| {
                            log("cards in play (mob): {s}\n", .{instance.template.name});
                        }
                    }
                },
                // .played_action_card => |data| {
                //     // g  try self.world.deck.move(data.instance, .hand, .in_play);
                //     // try event_system.push(Event{ .card_moved = .{ .instance = data.instance, .from = .hand, .to = .in_play } });
                // },
                else => |data| std.debug.print("event processed: {}\n", .{data}),
            }
            return true;
        } else return false;
    }
};

pub const CommandHandler = struct {
    world: *World,

    pub fn init(ctx: *World) CommandHandler {
        return CommandHandler{
            .world = ctx,
        };
    }

    pub fn gameStateTransition(self: *CommandHandler, target_state: world.GameState) !void {
        if (self.world.fsm.canTransitionTo(target_state)) {
            try self.world.fsm.transitionTo(target_state);
            try self.world.events.push(Event{ .game_state_transitioned_to = target_state });
        } else {
            return CommandError.InvalidGameState;
        }
    }

    pub fn playActionCard(self: *CommandHandler, card: *cards.Instance) !void {
        const player = &self.world.player;
        const game_state = self.world.fsm.currentState();
        var event_system = &self.world.events;

        // check if it's valid to play
        // first, game and template requirements
        if (game_state != .player_card_selection)
            return CommandError.InvalidGameState;

        if (player.stamina_available < card.template.cost.stamina)
            return CommandError.InsufficientStamina;

        if (player.time_available < card.template.cost.time)
            return CommandError.InsufficientTime;

        if (!self.world.deck.instanceInZone(card.id, .hand)) return CommandError.CardNotInHand;

        // WARN: for now we assume the trigger is fine (caller's responsibility)

        // if all rules have valid predicates, the card is valid to play;
        for (card.template.rules) |rule| {
            switch (rule.valid) {
                .always => {},
                else => return error.CommandInvalid,
            }
        }

        // lock it in: move the card
        try self.world.deck.move(card.id, .hand, .in_play);
        try event_system.push(
            Event{
                .card_moved = .{ .instance = card.id, .from = .hand, .to = .in_play },
            },
        );

        // sink an event for the card being played
        try event_system.push(
            Event{
                .played_action_card = .{
                    .instance = card.id,
                    .template = card.template.id,
                },
            },
        );

        // put a hold on the time & stamina costs for the UI to display / player state
        player.stamina_available -= card.template.cost.stamina;
        player.time_available -= card.template.cost.time;
        try event_system.push(
            Event{
                .card_cost_reserved = .{
                    .stamina = 0,
                    .time = 0,
                },
            },
        );
    }
};

//     pub fn playCardFull(self: *CommandHandler, card: *cards.Instance) !bool {
//         const alloc = self.world.alloc;
//         const encounter = &self.world.encounter.?;
//         const player = &self.world.player;
//         const game_state = self.world.fsm.currentState();
//         const techniques = self.world.deck.techniques;
//         const event_system = self.world.events;
//
//         var ecs = try std.ArrayList(EffectContext).initCapacity(alloc, 5);
//
//         // check if it's valid to play
//         // first, template-level requirements
//         // WARN: for now we assume the trigger is fine (caller's responsibility)
//         if (player.stamina < card.template.cost.stamina)
//             return CommandError.InsufficientStamina;
//
//         if (game_state != .wait_for_player)
//             return CommandError.InvalidGameState;
//
//         // TODO: check other shared criteria
//         // - time remaining in round
//
//         // if all rules have valid predicates, the card is valid to play;
//         for (card.template.rules) |rule| {
//             switch (rule.valid) {
//                 .always => {},
//                 else => return error.CommandInvalid,
//             }
//         }
//
//         for (card.template.rules) |rule| {
//
//             // if all rules have valid predicates, the card is valid to play;
//             // the predicates for each Effect determine whether it fires.
//
//             switch (rule.valid) {
//                 .always => {},
//                 else => return CommandError.NotImplemented,
//             }
//
//             // evaluate targets first, and apply the predicate as a filter
//             // against each target. This is somewhat inefficient in the event
//             // that the predicate is target agnostic, but - don't need to
//             // optimise that just yet.
//
//             for (rule.expressions) |expr| {
//                 if (expr.filter) |predicate| {
//                     switch (predicate) {
//                         .always => {},
//                         else => continue, // NOT IMPLEMENTED YET
//                     }
//                 }
//
//                 // build an EffectContext, and evaluate target, then run .filter over each target
//                 var target_list = try std.ArrayList(*Mob).initCapacity(alloc, 0);
//                 defer target_list.deinit(alloc);
//
//                 switch (expr.target) {
//                     .all_enemies => {
//                         for (encounter.enemies.items) |target| {
//                             const applicable: bool =
//                                 if (expr.filter) |*predicate|
//                                     evaluatePredicate(predicate, card, player, target)
//                                 else
//                                     true;
//
//                             if (applicable)
//                                 try target_list.append(alloc, target);
//                         }
//                     },
//                     else => return CommandError.NotImplemented,
//                 }
//
//                 var ctx = EffectContext{
//                     .card = card,
//                     .effect = &expr.effect,
//                     .actor = player,
//                     .target = &target_list,
//                 };
//
//                 switch (expr.effect) {
//                     .combat_technique => |value| {
//                         const tn = techniques.get(value.name).?;
//                         ctx.technique = .{
//                             .technique = tn,
//                             .base_damage = &tn.damage,
//                         };
//                     },
//                     else => return CommandError.NotImplemented,
//                 }
//                 try ecs.append(alloc, ctx);
//             }
//
//             // : sink an event for the card
//             try event_system.push(Event{
//                 .played_card = .{ .instance = card.id, .template = card.template.id },
//             });
//             // for (ecs.items) |ec| {}
//
//             // : sink an event for each effect
//             // : apply costs / sink more events
//         }
//         //return ecs.toOwnedSlice(alloc);
//     }
// };

fn evaluatePredicate(p: *const cards.Predicate, card: *const cards.Instance, actor: *Player, target: *Mob) bool {
    return switch (p.*) {
        .always => true,
        .has_tag => |tag| card.template.tags.hasTag(tag),
        .not => |predicate| !evaluatePredicate(predicate, card, actor, target),
        .all => false, // not implemented
        .any => false, // not implemented
    };
}

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
