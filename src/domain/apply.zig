//! Apply module - card validation, targeting, effect execution, and command handling.
//!
//! This is a thin re-export module. See apply/ subdirectory for implementations.
//! Import as: const apply = @import("apply.zig");

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;

// Re-export everything from the apply module
const apply_mod = @import("apply/mod.zig");

// Submodule namespaces
pub const validation = apply_mod.validation;
pub const targeting = apply_mod.targeting;
pub const command_handler = apply_mod.command_handler;
pub const event_processor = apply_mod.event_processor;
pub const costs = apply_mod.costs;
pub const effects = apply_mod.effects;

// Types
pub const ValidationError = apply_mod.ValidationError;
pub const PredicateContext = apply_mod.PredicateContext;
pub const PlayTarget = apply_mod.PlayTarget;
pub const CommandHandler = apply_mod.CommandHandler;
pub const CommandError = apply_mod.CommandError;
pub const EventProcessor = apply_mod.EventProcessor;

// Validation functions
pub const canPlayerPlayCard = apply_mod.canPlayerPlayCard;
pub const isCardSelectionValid = apply_mod.isCardSelectionValid;
pub const validateCardSelection = apply_mod.validateCardSelection;
pub const rulePredicatesSatisfied = apply_mod.rulePredicatesSatisfied;
pub const canWithdrawPlay = apply_mod.canWithdrawPlay;
pub const evaluatePredicate = apply_mod.evaluatePredicate;
pub const compareReach = apply_mod.compareReach;
pub const compareF32 = apply_mod.compareF32;
pub const checkOnPlayAttemptBlockers = apply_mod.checkOnPlayAttemptBlockers;
pub const cardTemplateMatchesPredicate = apply_mod.cardTemplateMatchesPredicate;

// Targeting functions
pub const expressionAppliesToTarget = apply_mod.expressionAppliesToTarget;
pub const cardHasValidTargets = apply_mod.cardHasValidTargets;
pub const evaluateTargets = apply_mod.evaluateTargets;
pub const evaluatePlayTargets = apply_mod.evaluatePlayTargets;
pub const resolvePlayTargetIDs = apply_mod.resolvePlayTargetIDs;
pub const getModifierTargetPredicate = apply_mod.getModifierTargetPredicate;
pub const canModifierAttachToPlay = apply_mod.canModifierAttachToPlay;

// Command handler helpers
pub const PlayResult = apply_mod.PlayResult;
pub const playValidCardReservingCosts = apply_mod.playValidCardReservingCosts;

// Effect functions
pub const applyCommitPhaseEffect = apply_mod.applyCommitPhaseEffect;
pub const executeCommitPhaseRules = apply_mod.executeCommitPhaseRules;
pub const executeResolvePhaseRules = apply_mod.executeResolvePhaseRules;
pub const tickConditions = apply_mod.tickConditions;
pub const executeManoeuvreEffects = apply_mod.executeManoeuvreEffects;
pub const adjustRange = apply_mod.adjustRange;

// Positioning types and functions
pub const ManoeuvreType = apply_mod.ManoeuvreType;
pub const ManoeuvreOutcome = apply_mod.ManoeuvreOutcome;
pub const calculateManoeuvreScore = apply_mod.calculateManoeuvreScore;
pub const resolveManoeuvreConflict = apply_mod.resolveManoeuvreConflict;
pub const getAgentFootwork = apply_mod.getAgentFootwork;
pub const resolvePositioningContests = apply_mod.resolvePositioningContests;

// Cost functions
pub const applyCommittedCosts = apply_mod.applyCommittedCosts;

// ============================================================================
// Tests (using re-exported functions for backward compatibility)
// ============================================================================

const testing = std.testing;
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const combat = @import("combat.zig");
const stats = @import("stats.zig");
const weapon_list = @import("weapon_list.zig");
const weapon = @import("weapon.zig");
const ai = @import("ai.zig");
const w = @import("world.zig");

fn testId(index: u32) entity.ID {
    return .{ .index = index, .generation = 0 };
}

fn makeTestAgent(armament: combat.Armament) combat.Agent {
    return combat.Agent{
        .id = testId(99),
        .alloc = undefined,
        .director = ai.noop(),
        .draw_style = .shuffled_deck,
        .stats = undefined,
        .body = undefined,
        .armour = undefined,
        .weapons = armament,
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
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const agent = makeTestAgent(.{ .single = &sword_instance });

    try testing.expect(rulePredicatesSatisfied(thrust_template, &agent, null));
}

test "rulePredicatesSatisfied allows shield block with shield equipped" {
    const shield_block = card_list.byName("shield block");
    var buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    const agent = makeTestAgent(.{ .single = &buckler_instance });

    try testing.expect(rulePredicatesSatisfied(shield_block, &agent, null));
}

test "rulePredicatesSatisfied denies shield block without shield" {
    const shield_block = card_list.byName("shield block");
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const agent = makeTestAgent(.{ .single = &sword_instance });

    try testing.expect(!rulePredicatesSatisfied(shield_block, &agent, null));
}

test "rulePredicatesSatisfied allows shield block with sword and shield dual wield" {
    const shield_block = card_list.byName("shield block");
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    var buckler_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.buckler };
    const agent = makeTestAgent(.{ .dual = .{
        .primary = &sword_instance,
        .secondary = &buckler_instance,
    } });

    try testing.expect(rulePredicatesSatisfied(shield_block, &agent, null));
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
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = &sword_instance });
    const target = makeTestAgent(.{ .single = &sword_instance });
    const card = makeTestCardInstance(thrust);

    try testing.expect(expressionAppliesToTarget(expr, &card, &actor, &target, null));
}

test "expressionAppliesToTarget with advantage_threshold filter passes when control high" {
    const riposte = card_list.byName("riposte");
    const expr = &riposte.rules[0].expressions[0];
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
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
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = &sword_instance });
    const target = makeTestAgent(.{ .single = &sword_instance });
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

// ============================================================================
// Modifier Attachment Tests
// ============================================================================

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
    const alloc = testing.allocator;

    var wrld = try w.World.init(alloc);
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
    const alloc = testing.allocator;

    var wrld = try w.World.init(alloc);
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

// ============================================================================
// Commit Phase Withdraw Tests
// ============================================================================

test "canWithdrawPlay returns true for play with no modifiers" {
    var play = combat.Play{ .action = testId(0) };
    try testing.expect(canWithdrawPlay(&play));
}

test "canWithdrawPlay returns false for play with modifiers attached" {
    var play = combat.Play{ .action = testId(0) };
    try play.addModifier(testId(1), null);

    try testing.expect(!canWithdrawPlay(&play));
}
