//! Target evaluation for card effects.
//!
//! Functions for evaluating and resolving targets for card expressions,
//! including agent targets and play targets (for modifiers).

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;

const cards = @import("../cards.zig");
const combat = @import("../combat.zig");
const w = @import("../world.zig");
const validation = @import("validation.zig");

const World = w.World;
const Agent = combat.Agent;

// ============================================================================
// Types
// ============================================================================

/// A target that references a specific play on an agent's timeline.
pub const PlayTarget = struct {
    agent: *Agent,
    play_index: usize,
};

// ============================================================================
// Public Targeting API
// ============================================================================

/// Check if an expression applies to a target (considering filters).
pub fn expressionAppliesToTarget(
    expr: *const cards.Expression,
    card: *const cards.Instance,
    actor: *const Agent,
    target: *const Agent,
    engagement: ?*const combat.Engagement,
) bool {
    const filter = expr.filter orelse return true;
    return validation.evaluatePredicate(&filter, .{
        .card = card,
        .actor = actor,
        .target = target,
        .engagement = engagement,
    });
}

/// Evaluate targets for an expression query, returning a list of agents.
pub fn evaluateTargets(
    alloc: std.mem.Allocator,
    query: cards.TargetQuery,
    actor: *Agent,
    world: *World,
    play_target: ?entity.ID,
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
                if (world.encounter) |enc| {
                    for (enc.enemies.items) |enemy| {
                        try targets.append(alloc, enemy);
                    }
                }
            } else {
                // AI targets player
                try targets.append(alloc, world.player);
            }
        },
        .single => {
            // Look up by entity ID from Play.target
            if (play_target) |target_id| {
                if (world.entities.agents.get(target_id)) |agent| {
                    try targets.append(alloc, agent.*);
                }
            }
        },
        .elected_n => {
            // TODO: requires Play.targets (multi-target)
        },
        .body_part, .event_source => {
            // Not applicable for agent targeting
        },
        .my_play, .opponent_play => {
            // Not applicable for agent targeting - use evaluatePlayTargets
        },
    }

    return targets;
}

/// Evaluate play targets (for modifier cards).
pub fn evaluatePlayTargets(
    alloc: std.mem.Allocator,
    query: cards.TargetQuery,
    actor: *Agent,
    world: *World,
) !std.ArrayList(PlayTarget) {
    var targets = try std.ArrayList(PlayTarget).initCapacity(alloc, 4);
    errdefer targets.deinit(alloc);

    const enc = world.encounter orelse return targets;

    switch (query) {
        .my_play => |predicate| {
            const enc_state = enc.stateFor(actor.id) orelse return targets;
            for (enc_state.current.slots(), 0..) |slot, i| {
                if (playMatchesPredicate(&slot.play, predicate, world)) {
                    try targets.append(alloc, .{ .agent = actor, .play_index = i });
                }
            }
        },
        .opponent_play => |predicate| {
            // For player, iterate mob plays; for mobs, target player
            if (actor.director == .player) {
                for (enc.enemies.items) |mob| {
                    const mob_state = enc.stateFor(mob.id) orelse continue;
                    for (mob_state.current.slots(), 0..) |slot, i| {
                        if (playMatchesPredicate(&slot.play, predicate, world)) {
                            try targets.append(alloc, .{ .agent = mob, .play_index = i });
                        }
                    }
                }
            } else {
                const player_state = enc.stateFor(world.player.id) orelse return targets;
                for (player_state.current.slots(), 0..) |slot, i| {
                    if (playMatchesPredicate(&slot.play, predicate, world)) {
                        try targets.append(alloc, .{ .agent = world.player, .play_index = i });
                    }
                }
            }
        },
        else => {}, // Other queries don't return play targets
    }

    return targets;
}

/// Resolve play targets to entity IDs (for offensive plays).
pub fn resolvePlayTargetIDs(
    alloc: std.mem.Allocator,
    play: *const combat.Play,
    actor: *const Agent,
    world: *const World,
) !?[]const entity.ID {
    const card = world.card_registry.getConst(play.action) orelse return null;
    if (!card.template.tags.offensive) return null;

    // Get target query from card's technique expression
    const target_query = blk: {
        for (card.template.rules) |rule| {
            for (rule.expressions) |expr| {
                // Find the first expression that targets agents
                switch (expr.target) {
                    .all_enemies, .self, .single => break :blk expr.target,
                    else => continue,
                }
            }
        }
        // Default for offensive cards without explicit target
        break :blk cards.TargetQuery.all_enemies;
    };

    // Resolve targets based on query (pass play.target for .single)
    const target_ids = try evaluateTargetIDsConst(alloc, target_query, actor, world, play.target) orelse return null;

    // For melee attacks, filter targets by range
    if (card.template.tags.melee) {
        return filterTargetsByMeleeRange(alloc, target_ids, card.template, actor, world);
    }

    return target_ids;
}

/// Filter target IDs to only those within melee range.
/// Returns empty slice if no targets are in range.
fn filterTargetsByMeleeRange(
    alloc: std.mem.Allocator,
    target_ids: []const entity.ID,
    template: *const cards.Template,
    actor: *const Agent,
    world: *const World,
) !?[]const entity.ID {
    const enc = world.encounter orelse {
        alloc.free(target_ids);
        return null;
    };

    // Get technique and attack mode
    const technique = template.getTechnique() orelse return target_ids; // no technique = allow all
    const attack_mode = technique.attack_mode;

    // Defensive techniques (.none) have no reach requirement
    if (attack_mode == .none) return target_ids;

    // Get weapon's reach for this attack type
    const weapon_mode = actor.weapons.getOffensiveMode(attack_mode) orelse {
        alloc.free(target_ids);
        return null;
    };
    const weapon_reach = @intFromEnum(weapon_mode.reach);

    // Filter to targets in range
    var valid_count: usize = 0;
    for (target_ids) |target_id| {
        const engagement = enc.getEngagementConst(actor.id, target_id) orelse continue;
        if (weapon_reach >= @intFromEnum(engagement.range)) {
            valid_count += 1;
        }
    }

    if (valid_count == 0) {
        alloc.free(target_ids);
        return null; // no valid targets in range
    }

    if (valid_count == target_ids.len) {
        return target_ids; // all in range, return as-is
    }

    // Build filtered list
    const filtered = try alloc.alloc(entity.ID, valid_count);
    var idx: usize = 0;
    for (target_ids) |target_id| {
        const engagement = enc.getEngagementConst(actor.id, target_id) orelse continue;
        if (weapon_reach >= @intFromEnum(engagement.range)) {
            filtered[idx] = target_id;
            idx += 1;
        }
    }
    alloc.free(target_ids);
    return filtered;
}

// ============================================================================
// Target Validity (Single Path)
// ============================================================================
//
// ARCHITECTURE NOTE: This is the ONE function for determining if a card has
// valid targets. All target validity checks flow through here. This ensures:
//
// 1. Consistent behavior - incapacitation, range, and filters checked uniformly
// 2. Single point of maintenance - no duplicate validation logic
// 3. General-case by default - checks ALL expressions, not just techniques
//
// The function is intentionally general. If future requirements need narrower
// checks (e.g., "only technique expressions"), pass a filter parameter rather
// than creating a parallel function.
//
// See: Serena memory "target_validation_architecture" for design rationale.
// ============================================================================

/// Check if a card has any valid targets based on its expressions.
/// For each expression, checks if at least one potential target is valid.
/// A valid target must be:
/// - Not incapacitated
/// - Within weapon reach (for technique effects)
/// - Passing any expression filter (e.g., advantage threshold)
pub fn hasAnyValidTarget(
    card: *const cards.Instance,
    actor: *const Agent,
    world: *const World,
) bool {
    const encounter = world.encounter orelse return true; // No encounter = no targeting requirement

    for (card.template.rules) |rule| {
        for (rule.expressions) |*expr| {
            // Self-targeting expressions always have a valid target (the actor).
            // Also avoids getTargetsForQuery(.self) which has a stack pointer bug.
            if (expr.target == .self) return true;

            // Get potential targets for this expression
            const targets = getTargetsForQuery(expr.target, actor, world);
            for (targets) |target| {
                if (isValidTargetForExpression(expr, card, actor, target, encounter)) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// Check if a specific target is valid for an expression.
/// This is the SINGLE LOCATION for all target validity checks:
/// - Incapacitation (universal)
/// - Weapon reach (technique effects only)
/// - Expression filters (advantage thresholds, etc.)
fn isValidTargetForExpression(
    expr: *const cards.Expression,
    card: *const cards.Instance,
    actor: *const Agent,
    target: *const Agent,
    encounter: *const combat.Encounter,
) bool {
    // Skip incapacitated targets
    if (target.isIncapacitated()) return false;

    const engagement_opt = encounter.getEngagementConst(actor.id, target.id);

    // For technique effects, check weapon reach/range
    if (expr.effect == .combat_technique) {
        const technique = expr.effect.combat_technique;
        const attack_mode = technique.attack_mode;
        // Defensive techniques have no reach requirement
        if (attack_mode != .none) {
            const engagement = engagement_opt orelse return false; // No engagement = can't target
            if (attack_mode == .ranged) {
                // Ranged attacks: check if target is within throw/projectile range
                const ranged_mode = actor.weapons.getRangedMode() orelse return false;
                const max_range = switch (ranged_mode) {
                    .thrown => |t| t.range,
                    .projectile => |p| p.range,
                };
                if (@intFromEnum(engagement.range) > @intFromEnum(max_range)) return false;
            } else {
                // Melee attacks: weapon reach must be >= engagement range
                const weapon_mode = actor.weapons.getOffensiveMode(attack_mode) orelse return false;
                if (@intFromEnum(weapon_mode.reach) < @intFromEnum(engagement.range)) return false;
            }
        }
    }

    // Check expression filter - need a pointer for PredicateContext
    if (engagement_opt) |engagement| {
        var eng = engagement; // Copy to local var so we can take address
        return expressionAppliesToTarget(expr, card, actor, target, &eng);
    } else {
        return expressionAppliesToTarget(expr, card, actor, target, null);
    }
}

/// Get the target predicate from a modifier card template.
pub fn getModifierTargetPredicate(template: *const cards.Template) !?cards.Predicate {
    if (template.kind != .modifier) return null;

    var found: ?cards.Predicate = null;
    for (template.rules) |rule| {
        for (rule.expressions) |expr| {
            switch (expr.target) {
                .my_play => |pred| {
                    if (found != null) {
                        // Multiple my_play targets found - ambiguous
                        return error.MultipleModifierTargets;
                    }
                    found = pred;
                },
                else => continue,
            }
        }
    }
    return found;
}

/// Check if a modifier can attach to a play.
pub fn canModifierAttachToPlay(
    modifier: *const cards.Template,
    play: *const combat.Play,
    world: *const World,
) !bool {
    const predicate = try getModifierTargetPredicate(modifier) orelse return false;
    return playMatchesPredicate(play, predicate, world);
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn getTargetsForQuery(query: cards.TargetQuery, actor: *const Agent, world: *const World) []const *Agent {
    return switch (query) {
        .self => @as([*]const *Agent, @ptrCast(&actor))[0..1],
        // For validation, .single checks if any enemy is targetable (selection at play time)
        .single, .all_enemies => blk: {
            if (actor.director == .player) {
                if (world.encounter) |enc| {
                    break :blk enc.enemies.items;
                }
            } else {
                break :blk @as([*]const *Agent, @ptrCast(&world.player))[0..1];
            }
            break :blk &.{};
        },
        .elected_n => blk: {
            // Same as single/all_enemies for validation purposes
            if (actor.director == .player) {
                if (world.encounter) |enc| {
                    break :blk enc.enemies.items;
                }
            } else {
                break :blk @as([*]const *Agent, @ptrCast(&world.player))[0..1];
            }
            break :blk &.{};
        },
        else => &.{}, // body_part, event_source, my_play, opponent_play not applicable
    };
}

fn getEngagementBetween(encounter: ?*combat.Encounter, actor: *const Agent, target: *const Agent) ?*const combat.Engagement {
    const enc = encounter orelse return null;
    return enc.getEngagement(actor.id, target.id);
}

fn playMatchesPredicate(
    play: *const combat.Play,
    predicate: cards.Predicate,
    world: *const World,
) bool {
    // Look up card via card_registry (new system)
    const card = world.card_registry.getConst(play.action) orelse return false;

    // For play predicates, we only support tag checking for now
    return switch (predicate) {
        .always => true,
        .has_tag => |tag| card.template.tags.hasTag(tag),
        .not => |inner| !playMatchesPredicate(play, inner.*, world),
        .all => |preds| {
            for (preds) |pred| {
                if (!playMatchesPredicate(play, pred, world)) return false;
            }
            return true;
        },
        .any => |preds| {
            for (preds) |pred| {
                if (playMatchesPredicate(play, pred, world)) return true;
            }
            return false;
        },
        else => false, // Other predicates not applicable to plays
    };
}

fn evaluateTargetIDsConst(
    alloc: std.mem.Allocator,
    query: cards.TargetQuery,
    actor: *const Agent,
    world: *const World,
    play_target: ?entity.ID,
) !?[]const entity.ID {
    switch (query) {
        .self => {
            const ids = try alloc.alloc(entity.ID, 1);
            ids[0] = actor.id;
            return ids;
        },
        .all_enemies => {
            if (actor.director == .player) {
                const enc = world.encounter orelse return null;
                const ids = try alloc.alloc(entity.ID, enc.enemies.items.len);
                for (enc.enemies.items, 0..) |enemy, i| {
                    ids[i] = enemy.id;
                }
                return ids;
            } else {
                const ids = try alloc.alloc(entity.ID, 1);
                ids[0] = world.player.id;
                return ids;
            }
        },
        .single => {
            const target_id = play_target orelse return null;
            const ids = try alloc.alloc(entity.ID, 1);
            ids[0] = target_id;
            return ids;
        },
        .elected_n => return null, // TODO: requires Play.targets (multi-target)
        else => return null,
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const card_list = @import("../card_list.zig");
const weapon_list = @import("../weapon_list.zig");
const weapon = @import("../weapon.zig");
const ai = @import("../ai.zig");
const stats = @import("../stats.zig");

fn testId(index: u32, kind: entity.EntityKind) entity.ID {
    return .{ .index = index, .generation = 0, .kind = kind };
}

fn makeTestAgent(equipped: combat.Armament.Equipped) combat.Agent {
    return combat.Agent{
        .id = testId(99, .agent),
        .alloc = undefined,
        .director = ai.noop(),
        .draw_style = .shuffled_deck,
        .stats = undefined,
        .body = undefined,
        .armour = undefined,
        .weapons = .{ .equipped = equipped, .natural = &.{} },
        .stamina = stats.Resource.init(10.0, 10.0, 2.0),
        .focus = stats.Resource.init(3.0, 5.0, 3.0),
        .blood = stats.Resource.init(5.0, 5.0, 0.0),
        .pain = stats.Resource.init(0.0, 10.0, 0.0),
        .trauma = stats.Resource.init(0.0, 10.0, 0.0),
        .morale = stats.Resource.init(10.0, 10.0, 0.0),
        .conditions = undefined,
        .immunities = undefined,
        .resistances = undefined,
        .vulnerabilities = undefined,
    };
}

fn makeTestCardInstance(template: *const cards.Template) cards.Instance {
    return cards.Instance{
        .id = testId(0, .agent),
        .template = template,
    };
}

test "expressionAppliesToTarget returns true when no filter" {
    const thrust = card_list.byName("thrust");
    const expr = &thrust.rules[0].expressions[0];
    var sword_instance = weapon.Instance{ .id = testId(0, .weapon), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = &sword_instance });
    const target = makeTestAgent(.{ .single = &sword_instance });
    const card = makeTestCardInstance(thrust);

    try testing.expect(expressionAppliesToTarget(expr, &card, &actor, &target, null));
}

test "expressionAppliesToTarget with advantage_threshold filter passes when control high" {
    const riposte = card_list.byName("riposte");
    const expr = &riposte.rules[0].expressions[0];
    var sword_instance = weapon.Instance{ .id = testId(0, .weapon), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = &sword_instance });
    const target = makeTestAgent(.{ .single = &sword_instance });
    const card = makeTestCardInstance(riposte);

    // High control engagement (0.7 >= 0.6 threshold)
    var engagement = combat.Engagement{ .control = 0.7 };

    try testing.expect(expressionAppliesToTarget(expr, &card, &actor, &target, &engagement));
}

test "expressionAppliesToTarget with advantage_threshold filter fails when control low" {
    const riposte = card_list.byName("riposte");
    const expr = &riposte.rules[0].expressions[0];
    var sword_instance = weapon.Instance{ .id = testId(0, .weapon), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = &sword_instance });
    const target = makeTestAgent(.{ .single = &sword_instance });
    const card = makeTestCardInstance(riposte);

    // Low control engagement (0.4 < 0.6 threshold)
    var engagement = combat.Engagement{ .control = 0.4 };

    try testing.expect(!expressionAppliesToTarget(expr, &card, &actor, &target, &engagement));
}

test "getModifierTargetPredicate extracts predicate from modifier template" {
    const high = card_list.byName("high");
    const predicate = try getModifierTargetPredicate(high);

    try testing.expect(predicate != null);
    // Modifier targets offensive plays
    try testing.expectEqual(cards.Predicate{ .has_tag = .{ .offensive = true } }, predicate.?);
}

test "getModifierTargetPredicate returns null for non-modifier" {
    const thrust = card_list.byName("thrust");
    const predicate = try getModifierTargetPredicate(thrust);

    try testing.expect(predicate == null);
}

test "canModifierAttachToPlay validates offensive tag match" {
    // Setup: need a World with card_registry containing an offensive play
    var wrld = try w.World.init(testing.allocator);
    defer wrld.deinit();

    // Create a play with an offensive action card (thrust)
    const thrust_template = card_list.byName("thrust");
    const thrust_card = try wrld.card_registry.create(thrust_template);
    var play = combat.Play{ .action = thrust_card.id };

    // High modifier targets offensive plays
    const high = card_list.byName("high");
    const can_attach = try canModifierAttachToPlay(high, &play, wrld);

    try testing.expect(can_attach);
}

test "canModifierAttachToPlay rejects non-offensive play" {
    var wrld = try w.World.init(testing.allocator);
    defer wrld.deinit();

    // Create a play with a non-offensive action card (parry is defensive)
    const parry_template = card_list.byName("parry");
    const parry_card = try wrld.card_registry.create(parry_template);
    var play = combat.Play{ .action = parry_card.id };

    // High modifier targets offensive plays - should reject defensive
    const high = card_list.byName("high");
    const can_attach = try canModifierAttachToPlay(high, &play, wrld);

    try testing.expect(!can_attach);
}

test "evaluateTargetIDsConst with .single returns null when no play_target" {
    const result = evaluateTargetIDsConst(
        testing.allocator,
        .single,
        undefined, // actor not used for .single
        undefined, // world not used for .single when no target
        null,
    ) catch null;
    try testing.expect(result == null);
}
