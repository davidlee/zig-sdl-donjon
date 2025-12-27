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
const tick = @import("tick.zig");

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

const log = std.debug.print;

pub const CommandError = error{
    CommandInvalid,
    InsufficientStamina,
    InsufficientTime,
    InvalidGameState,
    CardNotInHand,
    PredicateFailed,
    NotImplemented,
};

const EffectContext = struct {
    card: *cards.Instance,
    effect: *const cards.Effect,
    target: *std.ArrayList(*combat.Agent), // TODO: will need to be polymorphic (player, body part)
    actor: *combat.Agent,
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
                        for (mob.cards.deck.in_play.items) |instance| {
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
        const player = self.world.player;
        const game_state = self.world.fsm.currentState();
        var event_system = &self.world.events;
        var pd = player.cards.deck;

        // check if it's valid to play
        // first, game and template requirements
        if (game_state != .player_card_selection)
            return CommandError.InvalidGameState;

        if (player.stamina_available < card.template.cost.stamina)
            return CommandError.InsufficientStamina;

        if (player.time_available < card.template.cost.time)
            return CommandError.InsufficientTime;

        if (!pd.instanceInZone(card.id, .hand)) return CommandError.CardNotInHand;

        // WARN: for now we assume the trigger is fine (caller's responsibility)

        // check rule.valid predicates (weapon requirements, etc.)
        if (!canUseCard(card.template, player))
            return CommandError.PredicateFailed;

        // lock it in: move the card
        try pd.move(card.id, .hand, .in_play);
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

// ============================================================================
// Card Validity (rule.valid predicates - can this card be used by this actor?)
// ============================================================================

/// Check if a card template can be used by an actor (all rule.valid predicates pass)
pub fn canUseCard(template: *const cards.Template, actor: *const Agent) bool {
    for (template.rules) |rule| {
        if (!evaluateValidityPredicate(rule.valid, template, actor)) return false;
    }
    return true;
}

/// Evaluate a predicate for card validity (no target context)
fn evaluateValidityPredicate(p: cards.Predicate, template: *const cards.Template, actor: *const Agent) bool {
    return switch (p) {
        .always => true,
        .has_tag => |tag| template.tags.hasTag(tag),
        .weapon_category => |cat| actor.weapons.hasCategory(cat),
        .weapon_reach => false, // TODO: needs engagement context
        .range => false, // TODO: needs engagement context
        .advantage_threshold => false, // TODO: needs engagement context
        .not => |inner| !evaluateValidityPredicate(inner.*, template, actor),
        .all => |preds| {
            for (preds) |pred| {
                if (!evaluateValidityPredicate(pred, template, actor)) return false;
            }
            return true;
        },
        .any => |preds| {
            for (preds) |pred| {
                if (evaluateValidityPredicate(pred, template, actor)) return true;
            }
            return false;
        },
    };
}

// ============================================================================
// Effect Filtering (expr.filter predicates - does effect apply to this target?)
// ============================================================================

/// Context for predicate evaluation
const PredicateContext = struct {
    card: *const cards.Instance,
    actor: *const Agent,
    target: *const Agent,
    engagement: ?*const combat.Engagement,
};

fn evaluatePredicate(p: *const cards.Predicate, ctx: PredicateContext) bool {
    return switch (p.*) {
        .always => true,
        .has_tag => |tag| ctx.card.template.tags.hasTag(tag),
        .weapon_category => |cat| ctx.actor.weapons.hasCategory(cat),
        .weapon_reach => |wr| blk: {
            // Compare actor's weapon reach against threshold
            // TODO: get actual weapon reach from actor.weapons
            const weapon_reach: combat.Reach = .sabre; // placeholder
            break :blk compareReach(weapon_reach, wr.op, wr.value);
        },
        .range => |r| blk: {
            const eng = ctx.engagement orelse break :blk false;
            break :blk compareReach(eng.range, r.op, r.value);
        },
        .advantage_threshold => |at| blk: {
            const eng = ctx.engagement orelse break :blk false;
            const value = switch (at.axis) {
                .pressure => eng.pressure,
                .control => eng.control,
                .position => eng.position,
                .balance => ctx.actor.balance,
            };
            break :blk compareF32(value, at.op, at.value);
        },
        .not => |predicate| !evaluatePredicate(predicate, ctx),
        .all => |preds| {
            for (preds) |pred| {
                if (!evaluatePredicate(&pred, ctx)) return false;
            }
            return true;
        },
        .any => |preds| {
            for (preds) |pred| {
                if (evaluatePredicate(&pred, ctx)) return true;
            }
            return false;
        },
    };
}

fn compareReach(lhs: combat.Reach, op: cards.Comparator, rhs: combat.Reach) bool {
    const l = @intFromEnum(lhs);
    const r = @intFromEnum(rhs);
    return switch (op) {
        .lt => l < r,
        .lte => l <= r,
        .eq => l == r,
        .gte => l >= r,
        .gt => l > r,
    };
}

fn compareF32(lhs: f32, op: cards.Comparator, rhs: f32) bool {
    return switch (op) {
        .lt => lhs < rhs,
        .lte => lhs <= rhs,
        .eq => lhs == rhs,
        .gte => lhs >= rhs,
        .gt => lhs > rhs,
    };
}

/// Check if an expression's filter predicate passes for a given target.
/// Returns true if no filter, or if filter evaluates to true.
pub fn expressionAppliesToTarget(
    expr: *const cards.Expression,
    card: *const cards.Instance,
    actor: *const Agent,
    target: *const Agent,
    engagement: ?*const combat.Engagement,
) bool {
    const filter = expr.filter orelse return true;
    return evaluatePredicate(&filter, .{
        .card = card,
        .actor = actor,
        .target = target,
        .engagement = engagement,
    });
}

/// Check if any applicable engagement satisfies the filter (for UX: card playability hint).
/// Returns true if the card would have at least one valid target.
pub fn cardHasValidTargets(
    template: *const cards.Template,
    card: *const cards.Instance,
    actor: *const Agent,
    w: *const World,
) bool {
    for (template.rules) |rule| {
        for (rule.expressions) |expr| {
            // Get potential targets
            const targets = getTargetsForQuery(expr.target, actor, w);
            for (targets) |target| {
                const engagement = getEngagementBetween(actor, target);
                if (expressionAppliesToTarget(&expr, card, actor, target, engagement)) {
                    return true;
                }
            }
        }
    }
    return false;
}

// Helper to get targets without allocation (returns slice into world data)
fn getTargetsForQuery(query: cards.TargetQuery, actor: *const Agent, w: *const World) []const *Agent {
    return switch (query) {
        .self => @as([*]const *Agent, @ptrCast(&actor))[0..1],
        .all_enemies => blk: {
            if (actor.director == .player) {
                if (w.encounter) |*enc| {
                    break :blk enc.enemies.items;
                }
            } else {
                break :blk @as([*]const *Agent, @ptrCast(&w.player))[0..1];
            }
            break :blk &.{};
        },
        else => &.{}, // single, body_part, event_source not implemented
    };
}

fn getEngagementBetween(actor: *const Agent, target: *const Agent) ?*const combat.Engagement {
    // Engagement is stored on the mob (non-player), relative to player
    if (actor.director == .player) {
        // Actor is player, target is mob — engagement stored on mob
        return if (target.engagement) |*e| e else null;
    } else {
        // Actor is mob, target is player — engagement stored on actor
        return if (actor.engagement) |*e| e else null;
    }
}

// ============================================================================
// Target Evaluation (used by tick.zig for resolution)
// ============================================================================

/// Evaluate targets for a card effect based on TargetQuery
/// Returns a slice of target agents (caller owns the memory)
pub fn evaluateTargets(
    alloc: std.mem.Allocator,
    query: cards.TargetQuery,
    actor: *Agent,
    w: *World,
) !std.ArrayList(*Agent) {
    var targets = try std.ArrayList(*Agent).initCapacity(alloc, 4);
    errdefer targets.deinit(alloc);

    switch (query) {
        .self => {
            try targets.append(alloc, actor);
        },
        .all_enemies => {
            if (actor.director == .player) {
                // Player targets all mobs
                if (w.encounter) |*enc| {
                    for (enc.enemies.items) |enemy| {
                        try targets.append(alloc, enemy);
                    }
                }
            } else {
                // AI targets player
                try targets.append(alloc, w.player);
            }
        },
        .single => |selector| {
            // Look up by entity ID
            if (w.agents.get(selector.id)) |agent| {
                try targets.append(alloc, agent);
            }
        },
        .body_part, .event_source => {
            // Not applicable for agent targeting
        },
    }

    return targets;
}

// ============================================================================
// Tick Cleanup (cost enforcement, card zone transitions, cooldowns)
// ============================================================================

const DEFAULT_COOLDOWN_TICKS: u8 = 2;

/// Apply costs and cleanup after tick resolution.
/// This is the authority for stamina deduction, card movement, and cooldowns.
pub fn applyCommittedCosts(
    committed: []const tick.CommittedAction,
    event_system: *EventSystem,
) !void {
    for (committed) |action| {
        const card = action.card orelse continue;
        const agent = action.actor;

        // Deduct actual stamina cost
        const stamina_cost = card.template.cost.stamina;
        const old_stamina = agent.stamina;
        agent.stamina = @max(0, agent.stamina - stamina_cost);

        try event_system.push(.{
            .stamina_deducted = .{
                .agent_id = agent.id,
                .amount = stamina_cost,
                .new_value = agent.stamina,
            },
        });

        // Move card to discard or exhaust (deck-based only)
        switch (agent.cards) {
            .deck => |*d| {
                const dest_zone: cards.Zone = if (card.template.cost.exhausts)
                    .exhaust
                else
                    .discard;

                try d.move(card.id, .in_play, dest_zone);
                try event_system.push(.{
                    .card_moved = .{
                        .instance = card.id,
                        .from = .in_play,
                        .to = dest_zone,
                    },
                });
            },
            .pool => |*pool| {
                // Apply cooldown to technique
                try pool.applyCooldown(card.template.id, DEFAULT_COOLDOWN_TICKS);
                try event_system.push(.{
                    .cooldown_applied = .{
                        .agent_id = agent.id,
                        .template_id = card.template.id,
                        .ticks = DEFAULT_COOLDOWN_TICKS,
                    },
                });
            },
        }

        _ = old_stamina; // suppress unused warning for now
    }
}

// ============================================================================
// Design Notes
// ============================================================================
// event -> state mutation
//
// keep the core as:
// State: all authoritative game data
// Command: a player/AI intent ("PlayCard {card_id, target}")
// Resolver: validates + applies rules
// Event log: what happened ("DamageDealt", "StatusApplied", "CardMovedZones")
// RNG stream: explicit, seeded, reproducible
//
// for:
//
// deterministic replays
// easy undo/redo (event-sourcing or snapshots)
// "what-if" simulations for AI / balance tools
// clean separation from rendering
//
// resolve a command into events, then apply events to state in a predictable way.

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const weapon_list = @import("weapon_list.zig");
const weapon = @import("weapon.zig");

fn testId(index: u32) entity.ID {
    return .{ .index = index, .generation = 0 };
}

fn makeTestAgent(armament: combat.Armament) Agent {
    return Agent{
        .id = testId(99),
        .alloc = undefined, // not used by canUseCard
        .director = .ai,
        .cards = .{ .pool = undefined }, // not used by canUseCard
        .stats = undefined, // not used by canUseCard
        .engagement = null,
        .body = undefined, // not used by canUseCard
        .armour = undefined, // not used by canUseCard
        .weapons = armament,
        .conditions = undefined, // not used by canUseCard
        .immunities = undefined, // not used by canUseCard
        .resistances = undefined, // not used by canUseCard
        .vulnerabilities = undefined, // not used by canUseCard
    };
}

test "canUseCard allows card with always predicate" {
    const thrust_template = card_list.byName("thrust");
    const sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const agent = makeTestAgent(.{ .single = sword_instance });

    try testing.expect(canUseCard(thrust_template, &agent));
}

test "canUseCard allows shield block with shield equipped" {
    const shield_block = card_list.byName("shield block");
    const buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    const agent = makeTestAgent(.{ .single = buckler_instance });

    try testing.expect(canUseCard(shield_block, &agent));
}

test "canUseCard denies shield block without shield" {
    const shield_block = card_list.byName("shield block");
    const sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const agent = makeTestAgent(.{ .single = sword_instance });

    try testing.expect(!canUseCard(shield_block, &agent));
}

test "canUseCard allows shield block with sword and shield dual wield" {
    const shield_block = card_list.byName("shield block");
    const sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const buckler_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.buckler };
    const agent = makeTestAgent(.{ .dual = .{
        .primary = sword_instance,
        .secondary = buckler_instance,
    } });

    try testing.expect(canUseCard(shield_block, &agent));
}

// ============================================================================
// Expression Filter Tests
// ============================================================================

fn makeTestCardInstance(template: *const cards.Template) cards.Instance {
    return cards.Instance{
        .id = testId(0),
        .template = template,
    };
}

test "expressionAppliesToTarget returns true when no filter" {
    const thrust = card_list.byName("thrust");
    const expr = &thrust.rules[0].expressions[0];
    const sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = sword_instance });
    const target = makeTestAgent(.{ .single = sword_instance });
    const card = makeTestCardInstance(thrust);

    try testing.expect(expressionAppliesToTarget(expr, &card, &actor, &target, null));
}

test "expressionAppliesToTarget with advantage_threshold filter passes when control high" {
    const riposte = card_list.byName("riposte");
    const expr = &riposte.rules[0].expressions[0];
    const sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = sword_instance });
    const target = makeTestAgent(.{ .single = sword_instance });
    const card = makeTestCardInstance(riposte);

    // High control engagement (0.7 >= 0.6 threshold)
    var engagement = combat.Engagement{ .control = 0.7 };

    try testing.expect(expressionAppliesToTarget(expr, &card, &actor, &target, &engagement));
}

test "expressionAppliesToTarget with advantage_threshold filter fails when control low" {
    const riposte = card_list.byName("riposte");
    const expr = &riposte.rules[0].expressions[0];
    const sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = sword_instance });
    const target = makeTestAgent(.{ .single = sword_instance });
    const card = makeTestCardInstance(riposte);

    // Low control engagement (0.4 < 0.6 threshold)
    var engagement = combat.Engagement{ .control = 0.4 };

    try testing.expect(!expressionAppliesToTarget(expr, &card, &actor, &target, &engagement));
}

test "compareF32 operators" {
    try testing.expect(compareF32(0.5, .lt, 0.6));
    try testing.expect(!compareF32(0.6, .lt, 0.5));
    try testing.expect(compareF32(0.5, .lte, 0.5));
    try testing.expect(compareF32(0.5, .eq, 0.5));
    try testing.expect(compareF32(0.6, .gte, 0.5));
    try testing.expect(compareF32(0.6, .gt, 0.5));
}

test "compareReach operators" {
    try testing.expect(compareReach(.far, .eq, .far));
    try testing.expect(compareReach(.near, .lt, .far));
    try testing.expect(!compareReach(.far, .lt, .near));
}
