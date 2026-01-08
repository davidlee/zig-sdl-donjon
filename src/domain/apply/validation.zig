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
    BlockedByDudCard, // Card in hand with on_play_attempt rule blocks this play
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

    // Check if any dud card in hand blocks this play attempt
    if (checkOnPlayAttemptBlockers(player, card.template, world) != null) {
        return false;
    }

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

    // NOTE: Melee range is NOT checked here - it's a targeting constraint evaluated at resolution.
    // This allows queuing attacks after movement cards (advance→attack).

    return true;
}

/// Check if a play can be withdrawn.
/// Requires: no modifiers attached AND card is not involuntary.
pub fn canWithdrawPlay(play: *const combat.Play, registry: *const w.CardRegistry) bool {
    // Cannot withdraw if modifiers are attached (would need to unstack them first)
    if (play.modifier_stack_len > 0) return false;

    // Check if the card is involuntary (dud cards cannot be uncommitted)
    if (registry.getConst(play.action)) |card| {
        if (card.template.tags.involuntary) return false;
    }

    return true;
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
// Play Attempt Blocking (for dud cards)
// ============================================================================

/// Check if a card's template matches a predicate (for on_play_attempt rules).
/// This evaluates predicates against the *attempted* card, not the rule owner.
pub fn cardTemplateMatchesPredicate(template: *const cards.Template, p: cards.Predicate) bool {
    return switch (p) {
        .always => true,
        .has_tag => |tag| template.tags.hasTag(tag),
        .not => |inner| !cardTemplateMatchesPredicate(template, inner.*),
        .all => |preds| {
            for (preds) |pred| {
                if (!cardTemplateMatchesPredicate(template, pred)) return false;
            }
            return true;
        },
        .any => |preds| {
            for (preds) |pred| {
                if (cardTemplateMatchesPredicate(template, pred)) return true;
            }
            return false;
        },
        // Other predicates (weapon, range, condition, etc.) not applicable
        // to card template matching - they require actor/engagement context
        else => false,
    };
}

/// Check if any card in hand blocks the attempted play via on_play_attempt rules.
/// Returns the blocking card's ID if blocked, null otherwise.
pub fn checkOnPlayAttemptBlockers(
    actor: *const Agent,
    attempted_template: *const cards.Template,
    world: *const World,
) ?entity.ID {
    const cs = actor.combat_state orelse return null;

    // Iterate all cards in hand
    for (cs.hand.items) |hand_card_id| {
        const hand_card = world.card_registry.getConst(hand_card_id) orelse continue;

        // Check each rule on the hand card
        for (hand_card.template.rules) |rule| {
            // Only interested in on_play_attempt triggers
            if (rule.trigger != .on_play_attempt) continue;

            // Check if the predicate matches the attempted card
            if (!cardTemplateMatchesPredicate(attempted_template, rule.valid)) continue;

            // Check if any effect is cancel_play
            for (rule.expressions) |expr| {
                if (expr.effect == .cancel_play) {
                    return hand_card_id;
                }
            }
        }
    }

    return null;
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
    var registry = try w.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var play = combat.Play{
        .action = entity.ID{ .index = 0, .generation = 0 },
    };
    try testing.expect(canWithdrawPlay(&play, &registry));
}

test "canWithdrawPlay returns false for play with modifiers attached" {
    var registry = try w.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var play = combat.Play{
        .action = entity.ID{ .index = 0, .generation = 0 },
        .modifier_stack_len = 1,
    };
    try testing.expect(!canWithdrawPlay(&play, &registry));
}

test "canWithdrawPlay returns false for involuntary cards" {
    var registry = try w.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    // Create an involuntary card template
    const involuntary_template = &cards.Template{
        .id = 999,
        .kind = .action,
        .name = "test involuntary",
        .description = "cannot be withdrawn",
        .rarity = .common,
        .cost = .{ .stamina = 0, .exhausts = true },
        .tags = .{ .involuntary = true, .phase_selection = true },
        .rules = &.{},
    };

    // Create card instance in registry
    const card = try registry.create(involuntary_template);

    // Create play with the involuntary card
    var play = combat.Play{
        .action = card.id,
    };

    // Should not be withdrawable due to involuntary tag
    try testing.expect(!canWithdrawPlay(&play, &registry));
}

test "canWithdrawPlay returns true for non-involuntary cards with no modifiers" {
    var registry = try w.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    // Create a normal card template
    const normal_template = &cards.Template{
        .id = 888,
        .kind = .action,
        .name = "test normal",
        .description = "can be withdrawn",
        .rarity = .common,
        .cost = .{ .stamina = 1 },
        .tags = .{ .melee = true, .phase_selection = true },
        .rules = &.{},
    };

    // Create card instance in registry
    const card = try registry.create(normal_template);

    // Create play with the normal card
    var play = combat.Play{
        .action = card.id,
    };

    // Should be withdrawable
    try testing.expect(canWithdrawPlay(&play, &registry));
}

test "cardTemplateMatchesPredicate with always predicate" {
    const template = &cards.Template{
        .id = 1,
        .kind = .action,
        .name = "test",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 0 },
        .tags = .{ .melee = true },
        .rules = &.{},
    };
    try testing.expect(cardTemplateMatchesPredicate(template, .always));
}

test "cardTemplateMatchesPredicate with has_tag matches" {
    const precision_card = &cards.Template{
        .id = 1,
        .kind = .action,
        .name = "precision strike",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 0 },
        .tags = .{ .precision = true, .melee = true },
        .rules = &.{},
    };

    // Matching tag
    try testing.expect(cardTemplateMatchesPredicate(precision_card, .{ .has_tag = .{ .precision = true } }));
    try testing.expect(cardTemplateMatchesPredicate(precision_card, .{ .has_tag = .{ .melee = true } }));

    // Non-matching tag
    try testing.expect(!cardTemplateMatchesPredicate(precision_card, .{ .has_tag = .{ .finesse = true } }));
}

test "cardTemplateMatchesPredicate with not predicate" {
    const finesse_card = &cards.Template{
        .id = 1,
        .kind = .action,
        .name = "finesse",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 0 },
        .tags = .{ .finesse = true },
        .rules = &.{},
    };

    const not_precision: cards.Predicate = .{ .has_tag = .{ .precision = true } };

    // Card has finesse but not precision, so "not precision" should pass
    try testing.expect(cardTemplateMatchesPredicate(finesse_card, .{ .not = &not_precision }));
}

test "cardTemplateMatchesPredicate with all predicate" {
    const melee_precision = &cards.Template{
        .id = 1,
        .kind = .action,
        .name = "melee precision",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 0 },
        .tags = .{ .melee = true, .precision = true },
        .rules = &.{},
    };

    const preds: [2]cards.Predicate = .{
        .{ .has_tag = .{ .melee = true } },
        .{ .has_tag = .{ .precision = true } },
    };

    // All predicates must match
    try testing.expect(cardTemplateMatchesPredicate(melee_precision, .{ .all = &preds }));

    // Add a non-matching predicate
    const preds_fail: [2]cards.Predicate = .{
        .{ .has_tag = .{ .melee = true } },
        .{ .has_tag = .{ .finesse = true } }, // card doesn't have finesse
    };
    try testing.expect(!cardTemplateMatchesPredicate(melee_precision, .{ .all = &preds_fail }));
}

test "cardTemplateMatchesPredicate with any predicate" {
    const melee_only = &cards.Template{
        .id = 1,
        .kind = .action,
        .name = "melee only",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 0 },
        .tags = .{ .melee = true },
        .rules = &.{},
    };

    const preds: [2]cards.Predicate = .{
        .{ .has_tag = .{ .precision = true } },
        .{ .has_tag = .{ .melee = true } },
    };

    // Any predicate matching is enough
    try testing.expect(cardTemplateMatchesPredicate(melee_only, .{ .any = &preds }));

    // None match
    const preds_fail: [2]cards.Predicate = .{
        .{ .has_tag = .{ .precision = true } },
        .{ .has_tag = .{ .finesse = true } },
    };
    try testing.expect(!cardTemplateMatchesPredicate(melee_only, .{ .any = &preds_fail }));
}

// ============================================================================
// rulePredicatesSatisfied tests
// ============================================================================

const card_list = @import("../card_list.zig");
const weapon_list = @import("../weapon_list.zig");
const weapon = @import("../weapon.zig");
const ai = @import("../ai.zig");
const stats = @import("../stats.zig");

fn makeTestAgent(equipped: combat.Armament.Equipped) combat.Agent {
    return combat.Agent{
        .id = entity.ID{ .index = 99, .generation = 0 },
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

test "rulePredicatesSatisfied allows card with always predicate" {
    const thrust_template = card_list.byName("thrust");
    var sword_instance = weapon.Instance{ .id = entity.ID{ .index = 0, .generation = 0 }, .template = &weapon_list.knights_sword };
    const agent = makeTestAgent(.{ .single = &sword_instance });

    try testing.expect(rulePredicatesSatisfied(thrust_template, &agent, null));
}

test "rulePredicatesSatisfied allows shield block with shield equipped" {
    const shield_block = card_list.byName("shield block");
    var buckler_instance = weapon.Instance{ .id = entity.ID{ .index = 0, .generation = 0 }, .template = &weapon_list.buckler };
    const agent = makeTestAgent(.{ .single = &buckler_instance });

    try testing.expect(rulePredicatesSatisfied(shield_block, &agent, null));
}

test "rulePredicatesSatisfied denies shield block without shield" {
    const shield_block = card_list.byName("shield block");
    var sword_instance = weapon.Instance{ .id = entity.ID{ .index = 0, .generation = 0 }, .template = &weapon_list.knights_sword };
    const agent = makeTestAgent(.{ .single = &sword_instance });

    try testing.expect(!rulePredicatesSatisfied(shield_block, &agent, null));
}

test "rulePredicatesSatisfied allows shield block with sword and shield dual wield" {
    const shield_block = card_list.byName("shield block");
    var sword_instance = weapon.Instance{ .id = entity.ID{ .index = 0, .generation = 0 }, .template = &weapon_list.knights_sword };
    var buckler_instance = weapon.Instance{ .id = entity.ID{ .index = 1, .generation = 0 }, .template = &weapon_list.buckler };
    const agent = makeTestAgent(.{ .dual = .{
        .primary = &sword_instance,
        .secondary = &buckler_instance,
    } });

    try testing.expect(rulePredicatesSatisfied(shield_block, &agent, null));
}
