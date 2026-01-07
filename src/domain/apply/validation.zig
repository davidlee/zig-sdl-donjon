//! Card playability validation.
//!
//! Pure validation functions for determining if a card can be played.
//! No world mutation - these functions only query state.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;

const cards = @import("../cards.zig");
const combat = @import("../combat.zig");
const w = @import("../world.zig");

const World = w.World;
const Agent = combat.Agent;
const Instance = cards.Instance;

// ============================================================================
// Error Types
// ============================================================================

pub const ValidationError = error{
    InsufficientStamina,
    InsufficientTime,
    InsufficientFocus,
    InvalidGameState,
    WrongPhase,
    CardNotInHand, // Legacy: kept for compatibility
    InvalidPlaySource, // Card not in any source allowed by playable_from
    NotCombatPlayable, // Card has combat_playable=false
    PredicateFailed,
    ConditionPreventsPlay, // Global condition restriction (stunned, paralysed, etc.)
    ChannelConflict, // Technique uses same channel as existing play
    OutOfRange, // Melee card but no enemy within weapon reach
    NotImplemented,
};

// ============================================================================
// Public Validation API
// ============================================================================

/// Check if player can play a card (top-level convenience function).
pub fn canPlayerPlayCard(world: *World, card_id: entity.ID) bool {
    const phase = world.turnPhase() orelse return false;
    const player = world.player;

    // Look up card via card_registry (new system)
    const card = world.card_registry.get(card_id) orelse return false;
    return validateCardSelection(player, card, phase, world.encounter) catch false;
}

/// Convenience wrapper for selection-phase validation.
pub fn isCardSelectionValid(actor: *const Agent, card: *const Instance, encounter: ?*const combat.Encounter) bool {
    return validateCardSelection(actor, card, .player_card_selection, encounter) catch false;
}

/// Core validation: can this actor play this card in this phase?
pub fn validateCardSelection(
    actor: *const Agent,
    card: *const Instance,
    phase: combat.TurnPhase,
    encounter: ?*const combat.Encounter,
) !bool {
    const cs = actor.combat_state orelse return ValidationError.InvalidGameState;
    const template = card.template;

    // Check if card is playable in combat at all
    if (!template.combat_playable) return ValidationError.NotCombatPlayable;

    // Check if card can be played in this phase
    if (!template.tags.canPlayInPhase(phase)) return ValidationError.WrongPhase;

    // Global condition restrictions - universal rules that don't need per-card predicates
    if (actor.hasCondition(.unconscious) or actor.hasCondition(.comatose)) {
        return ValidationError.ConditionPreventsPlay;
    }
    if (actor.hasCondition(.paralysed)) {
        return ValidationError.ConditionPreventsPlay;
    }
    if (actor.hasCondition(.stunned) and template.tags.offensive) {
        return ValidationError.ConditionPreventsPlay;
    }

    if (actor.stamina.available < template.cost.stamina) return ValidationError.InsufficientStamina;

    if (actor.time_available < template.cost.time) return ValidationError.InsufficientTime;

    // Check Focus cost (for commit-phase cards)
    if (template.cost.focus > 0 and actor.focus.available < template.cost.focus) {
        return ValidationError.InsufficientFocus;
    }

    // Check if card is in an allowed source based on playable_from
    if (!isInPlayableSource(actor, cs, card.id, template.playable_from)) {
        return ValidationError.InvalidPlaySource;
    }

    // check rule.valid predicates (weapon requirements, range, etc.)
    if (!rulePredicatesSatisfied(template, actor, encounter)) return ValidationError.PredicateFailed;

    // Melee cards require weapon reach to at least one enemy
    if (template.tags.melee) {
        const enc = encounter orelse return ValidationError.OutOfRange;
        if (!validateMeleeReach(template, actor, enc)) return ValidationError.OutOfRange;
    }

    return true;
}

/// Check if a play can be withdrawn (no modifiers attached).
pub fn canWithdrawPlay(play: *const combat.Play) bool {
    return play.modifier_stack_len == 0;
}

/// Check if all rule predicates on a card template are satisfied.
pub fn rulePredicatesSatisfied(
    template: *const cards.Template,
    actor: *const Agent,
    encounter: ?*const combat.Encounter,
) bool {
    for (template.rules) |rule| {
        if (!evaluateValidityPredicate(rule.valid, template, actor, encounter)) return false;
    }
    return true;
}

// ============================================================================
// Internal Validation Helpers
// ============================================================================

fn validateMeleeReach(
    template: *const cards.Template,
    actor: *const Agent,
    encounter: *const combat.Encounter,
) bool {
    const technique = template.getTechnique() orelse {
        // .melee card without technique is unexpected; warn and allow play
        std.debug.print("warning: .melee card '{s}' has no technique\n", .{template.name});
        return true;
    };
    const attack_mode = technique.attack_mode;

    // Defensive techniques (.none) have no reach requirement
    if (attack_mode == .none) return true;

    // Get weapon's offensive mode for this attack type
    const weapon_mode = actor.weapons.getOffensiveMode(attack_mode) orelse return false;

    // Check if any enemy is within reach (Option A: short-circuit true on first valid)
    for (encounter.enemies.items) |enemy| {
        const engagement = encounter.getPlayerEngagementConst(enemy.id) orelse continue;
        // weapon.reach >= engagement.range means we can hit them
        if (@intFromEnum(weapon_mode.reach) >= @intFromEnum(engagement.range)) return true;
    }
    return false;
}

fn isInPlayableSource(actor: *const Agent, cs: *const combat.CombatState, card_id: entity.ID, pf: cards.PlayableFrom) bool {
    // Check CombatState.hand
    if (pf.hand and cs.isInZone(card_id, .hand)) return true;

    // Check always_available pool
    if (pf.always_available) {
        for (actor.always_available.items) |id| {
            if (id.eql(card_id)) return true;
        }
    }

    // Check spells_known
    if (pf.spells_known) {
        for (actor.spells_known.items) |id| {
            if (id.eql(card_id)) return true;
        }
    }

    // Check inventory
    if (pf.inventory) {
        for (actor.inventory.items) |id| {
            if (id.eql(card_id)) return true;
        }
    }

    // TODO: equipped requires checking Armament/equipment (needs World access)
    // TODO: environment requires checking Encounter.environment (needs World access)

    return false;
}

fn getCardChannels(template: *const cards.Template) cards.ChannelSet {
    if (template.getTechnique()) |technique| {
        return technique.channels;
    }
    return .{};
}

// ============================================================================
// Predicate Evaluation
// ============================================================================

/// Context for predicate evaluation (used by both validation and targeting).
pub const PredicateContext = struct {
    card: *const cards.Instance,
    actor: *const Agent,
    target: *const Agent,
    engagement: ?*const combat.Engagement,
};

fn evaluateValidityPredicate(
    p: cards.Predicate,
    template: *const cards.Template,
    actor: *const Agent,
    encounter: ?*const combat.Encounter,
) bool {
    return switch (p) {
        .always => true,
        .has_tag => |tag| template.tags.hasTag(tag),
        .weapon_category => |cat| actor.weapons.hasCategory(cat),
        .weapon_reach => false, // TODO: needs weapon context
        .range => |r| blk: {
            const enc = encounter orelse break :blk false;
            // Check if ANY enemy engagement satisfies the range predicate
            for (enc.enemies.items) |enemy| {
                if (enc.getPlayerEngagementConst(enemy.id)) |eng| {
                    if (compareReach(eng.range, r.op, r.value)) break :blk true;
                }
            }
            break :blk false;
        },
        .advantage_threshold => false, // TODO: needs engagement context
        .has_condition => |cond| actor.hasCondition(cond),
        .lacks_condition => |cond| !actor.hasCondition(cond),
        .not => |inner| !evaluateValidityPredicate(inner.*, template, actor, encounter),
        .all => |preds| {
            for (preds) |pred| {
                if (!evaluateValidityPredicate(pred, template, actor, encounter)) return false;
            }
            return true;
        },
        .any => |preds| {
            for (preds) |pred| {
                if (evaluateValidityPredicate(pred, template, actor, encounter)) return true;
            }
            return false;
        },
    };
}

/// Evaluate a predicate with full context (used by targeting filters).
/// Made pub for use by apply/targeting.zig.
pub fn evaluatePredicate(p: *const cards.Predicate, ctx: PredicateContext) bool {
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
        .has_condition => |cond| ctx.actor.hasCondition(cond),
        .lacks_condition => |cond| !ctx.actor.hasCondition(cond),
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

// ============================================================================
// Comparison Helpers
// ============================================================================

pub fn compareReach(lhs: combat.Reach, op: cards.Comparator, rhs: combat.Reach) bool {
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

pub fn compareF32(lhs: f32, op: cards.Comparator, rhs: f32) bool {
    return switch (op) {
        .lt => lhs < rhs,
        .lte => lhs <= rhs,
        .eq => lhs == rhs,
        .gte => lhs >= rhs,
        .gt => lhs > rhs,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "rulePredicatesSatisfied allows card with always predicate" {
    // Cards with .always predicate should always pass validation
    // TODO: needs test fixtures
    return error.SkipZigTest;
}

test "rulePredicatesSatisfied allows shield block with shield equipped" {
    // A shield_block card should be valid when actor has shield category weapon
    // TODO: needs test fixtures
    return error.SkipZigTest;
}

test "rulePredicatesSatisfied denies shield block without shield" {
    // A shield_block card should fail when actor has no shield
    // TODO: needs test fixtures
    return error.SkipZigTest;
}

test "rulePredicatesSatisfied allows shield block with sword and shield dual wield" {
    // Dual wield (sword primary, shield secondary) should pass shield predicate
    // TODO: needs test fixtures
    return error.SkipZigTest;
}

test "compareF32 operators" {
    try testing.expect(compareF32(1.0, .lt, 2.0));
    try testing.expect(!compareF32(2.0, .lt, 1.0));
    try testing.expect(compareF32(1.0, .lte, 1.0));
    try testing.expect(compareF32(1.0, .eq, 1.0));
    try testing.expect(!compareF32(1.0, .eq, 2.0));
    try testing.expect(compareF32(2.0, .gte, 1.0));
    try testing.expect(compareF32(2.0, .gt, 1.0));
}

test "compareReach operators" {
    try testing.expect(compareReach(.dagger, .lt, .sabre));
    try testing.expect(!compareReach(.sabre, .lt, .dagger));
    try testing.expect(compareReach(.sabre, .lte, .sabre));
    try testing.expect(compareReach(.sabre, .eq, .sabre));
    try testing.expect(compareReach(.longsword, .gte, .sabre));
    try testing.expect(compareReach(.spear, .gt, .longsword));
}

test "canWithdrawPlay returns true for play with no modifiers" {
    var play = combat.Play{
        .action = entity.ID{ .index = 0, .generation = 0 },
    };
    try testing.expect(canWithdrawPlay(&play));
}

test "canWithdrawPlay returns false for play with modifiers attached" {
    var play = combat.Play{
        .action = entity.ID{ .index = 0, .generation = 0 },
        .modifier_stack_len = 1,
    };
    try testing.expect(!canWithdrawPlay(&play));
}

test "validateMeleeReach passes when weapon reach >= engagement range" {
    // TODO: needs test fixtures with Agent and Encounter setup
    return error.SkipZigTest;
}

test "validateMeleeReach fails when weapon reach < engagement range" {
    // TODO: needs test fixtures
    return error.SkipZigTest;
}

test "validateMeleeReach fails when at abstract far distance" {
    // TODO: needs test fixtures
    return error.SkipZigTest;
}
