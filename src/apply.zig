const std = @import("std");
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event);

const EntityID = @import("entity.zig").EntityID;
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const World = @import("world.zig").World;
const Player = @import("player.zig").Player;
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const mob = @import("mob.zig");
const Mob = mob.Mob;

const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Expression = cards.Expression;
const Technique = cards.Technique;

pub const CommandError = error{
    CommandInvalid,
    InsufficientStamina,
    InvalidGameState,
    // InsufficientTime,
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

// const TechniqueWithModifiers = struct {
//     technique: *const cards.Technique,
//     scaled_damage: []damage.Instance,
// };

pub const CommandHandler = struct {
    world: *World,

    pub fn init(world: *World) @This() {
        return @This(){
            .world = world,
        };
    }

    pub fn playCard(self: *CommandHandler, card: *cards.Instance) !bool {
        const alloc = self.world.alloc;
        const encounter = &self.world.encounter.?;
        const player = &self.world.player;
        const game_state = self.world.fsm.currentState();
        const techniques = self.world.deck.techniques;
        const events = self.world.events;

        var ecs = try std.ArrayList(EffectContext).initCapacity(alloc, 5);

        // check if it's valid to play
        // first, template-level requirements
        // WARN: for now we assume the trigger is fine (caller's responsibility)
        if (player.stamina < card.template.cost.stamina)
            return CommandError.InsufficientStamina;

        if (game_state != .wait_for_player)
            return CommandError.InvalidGameState;

        // TODO: check other shared criteria
        // - time remaining in round

        // now check each rule's valid predicate
        for (card.template.rules) |rule| {
            switch (rule.valid) {
                .always => {},
                else => return error.CommandInvalid,
            }
        }

        for (card.template.rules) |rule| {

            // if all rules have valid predicates, the card is valid to play;
            // the predicates for each Effect determine whether it fires.

            switch (rule.valid) {
                .always => {},
                else => return CommandError.NotImplemented,
            }

            // evaluate targets first, and apply the predicate as a filter
            // against each target. This is somewhat inefficient in the event
            // that the predicate is target agnostic, but - don't need to
            // optimise that just yet.

            for (rule.expressions) |expr| {
                if (expr.filter) |predicate| {
                    switch (predicate) {
                        .always => {},
                        else => continue, // NOT IMPLEMENTED YET
                    }
                }

                // build an EffectContext, and evaluate target, then run .filter over each target
                var target_list = try std.ArrayList(*Mob).initCapacity(alloc, 0);
                defer target_list.deinit(alloc);

                switch (expr.target) {
                    .all_enemies => {
                        for (encounter.enemies.items) |target| {
                            const applicable: bool =
                                if (expr.filter) |*predicate|
                                    evaluatePredicate(predicate, card, player, target)
                                else
                                    true;

                            if (applicable)
                                try target_list.append(alloc, target);
                        }
                    },
                    else => return CommandError.NotImplemented,
                }

                var ctx = EffectContext{
                    .card = card,
                    .effect = &expr.effect,
                    .actor = player,
                    .target = &target_list,
                };

                switch (expr.effect) {
                    .combat_technique => |value| {
                        const tn = techniques.get(value.name).?;
                        ctx.technique = .{
                            .technique = tn,
                            .base_damage = &tn.damage,
                        };
                    },
                    else => return CommandError.NotImplemented,
                }
                try ecs.append(alloc, ctx);
            }

            // : sink an event for the card
            try events.push(Event{
                .played_card = .{ .instance = card.id, .template = card.template.id },
            });
            for (ecs.items) |ec| {}

            // : sink an event for each effect
            // : apply costs / sink more events
        }
        //return ecs.toOwnedSlice(alloc);
    }
};

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
