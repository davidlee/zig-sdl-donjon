/// Advantage effect calculations for combat resolution.
///
/// Scales advantage modifiers based on outcomes, stakes, and technique
/// overrides. No rendering or event formatting lives here.
const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const combat = @import("../combat.zig");
const actions = @import("../actions.zig");
const events = @import("../events.zig");
const world = @import("../world.zig");

const Agent = combat.Agent;
const Engagement = combat.Engagement;
const Technique = actions.Technique;
const Stakes = actions.Stakes;
const World = world.World;

// Re-export from combat module
pub const AdvantageEffect = combat.AdvantageEffect;
pub const TechniqueAdvantage = combat.TechniqueAdvantage;

// Import Outcome from outcome.zig
const outcome_mod = @import("outcome.zig");
const Outcome = outcome_mod.Outcome;

// ============================================================================
// Default Advantage Effects
// ============================================================================

/// Default advantage effects per outcome (used when technique has no override)
pub const default_advantage_effects = struct {
    pub const hit: AdvantageEffect = .{
        .pressure = 0.15,
        .control = 0.10,
        .target_balance = -0.15,
    };
    pub const miss: AdvantageEffect = .{
        .control = -0.15,
        .self_balance = -0.10,
    };
    pub const blocked: AdvantageEffect = .{
        .pressure = 0.05,
        .control = -0.05,
    };
    pub const parried: AdvantageEffect = .{
        .control = -0.20,
        .self_balance = -0.05,
    };
    pub const deflected: AdvantageEffect = .{
        .pressure = 0.05,
        .control = -0.10,
    };
    pub const dodged: AdvantageEffect = .{
        .control = -0.10,
        .self_balance = -0.05,
    };
    pub const countered: AdvantageEffect = .{
        .control = -0.25,
        .self_balance = -0.15,
    };
};

/// Default advantage effect for an outcome (when technique has no override)
pub fn defaultForOutcome(outcome: Outcome) AdvantageEffect {
    return switch (outcome) {
        .hit => default_advantage_effects.hit,
        .miss => default_advantage_effects.miss,
        .blocked => default_advantage_effects.blocked,
        .parried => default_advantage_effects.parried,
        .deflected => default_advantage_effects.deflected,
        .dodged => default_advantage_effects.dodged,
        .countered => default_advantage_effects.countered,
    };
}

/// Get technique-specific override for outcome, or null if not specified
pub fn techniqueOverrideForOutcome(adv: TechniqueAdvantage, outcome: Outcome) ?AdvantageEffect {
    return switch (outcome) {
        .hit => adv.on_hit,
        .miss => adv.on_miss,
        .blocked => adv.on_blocked,
        .parried => adv.on_parried,
        .deflected => adv.on_deflected,
        .dodged => adv.on_dodged,
        .countered => adv.on_countered,
    };
}

/// Get advantage effect for an outcome, checking technique-specific overrides first
pub fn getAdvantageEffect(
    technique: *const Technique,
    outcome: Outcome,
    stakes: Stakes,
) AdvantageEffect {
    const base = if (technique.advantage) |adv|
        techniqueOverrideForOutcome(adv, outcome) orelse defaultForOutcome(outcome)
    else
        defaultForOutcome(outcome);

    return base.scale(stakes.advantageMultiplier(outcome == .hit));
}

// ============================================================================
// Advantage Application with Events
// ============================================================================

/// Emit advantage_changed event if value actually changed
fn emitIfChanged(
    w: *World,
    agent_id: entity.ID,
    engagement_with: ?entity.ID,
    axis: combat.AdvantageAxis,
    old: f32,
    new: f32,
) !void {
    if (old != new) {
        try w.events.push(.{ .advantage_changed = .{
            .agent_id = agent_id,
            .engagement_with = engagement_with,
            .axis = axis,
            .old_value = old,
            .new_value = new,
        } });
    }
}

/// Apply advantage effects and emit events for any changes
pub fn applyAdvantageWithEvents(
    effect: AdvantageEffect,
    w: *World,
    engagement: *Engagement,
    attacker: *Agent,
    defender: *Agent,
) !void {
    // Capture old values
    const old_pressure = engagement.pressure;
    const old_control = engagement.control;
    const old_position = engagement.position;
    const old_attacker_balance = attacker.balance;
    const old_defender_balance = defender.balance;

    // Apply changes
    effect.apply(engagement, attacker, defender);

    // Emit events for changed values
    // Engagement changes are relative to defender (engagement stored on mob)
    try emitIfChanged(w, defender.id, attacker.id, .pressure, old_pressure, engagement.pressure);
    try emitIfChanged(w, defender.id, attacker.id, .control, old_control, engagement.control);
    try emitIfChanged(w, defender.id, attacker.id, .position, old_position, engagement.position);

    // Balance is intrinsic (engagement_with = null)
    try emitIfChanged(w, attacker.id, null, .balance, old_attacker_balance, attacker.balance);
    try emitIfChanged(w, defender.id, null, .balance, old_defender_balance, defender.balance);
}

// ============================================================================
// Tests
// ============================================================================

test "getAdvantageEffect scales by stakes" {
    const technique = &actions.Technique.byID(.swing);
    const base_hit = getAdvantageEffect(technique, .hit, .guarded);
    const reckless_hit = getAdvantageEffect(technique, .hit, .reckless);

    // Reckless should have higher pressure gain
    try std.testing.expect(reckless_hit.pressure > base_hit.pressure);
}

test "getAdvantageEffect miss penalty scales with stakes" {
    const technique = &actions.Technique.byID(.swing);
    const guarded_miss = getAdvantageEffect(technique, .miss, .guarded);
    const reckless_miss = getAdvantageEffect(technique, .miss, .reckless);

    // Reckless miss should have bigger balance penalty
    try std.testing.expect(reckless_miss.self_balance < guarded_miss.self_balance);
}

test "getAdvantageEffect uses technique override when present" {
    // Technique with custom on_hit advantage
    const custom_technique = Technique{
        .id = .swing, // arbitrary ID for test
        .name = "test_feint",
        .damage = .{
            .instances = &.{.{ .amount = 0.5, .types = &.{.slash} }},
            .scaling = .{ .ratio = 0.5, .stats = .{ .stat = .speed } },
        },
        .difficulty = 0.5,
        .advantage = .{
            .on_hit = .{
                .pressure = 0.30, // higher than default 0.15
                .control = 0.25, // higher than default 0.10
                .position = 0.10, // default has 0
            },
            // other outcomes use defaults
        },
    };

    const custom_effect = getAdvantageEffect(&custom_technique, .hit, .guarded);
    const default_technique = &actions.Technique.byID(.swing);
    const default_effect = getAdvantageEffect(default_technique, .hit, .guarded);

    // Custom technique should have higher pressure/control on hit
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), custom_effect.pressure, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), custom_effect.control, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), custom_effect.position, 0.001);

    // Default technique should have standard values
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), default_effect.pressure, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), default_effect.control, 0.001);
}

test "getAdvantageEffect falls back to default for unspecified outcomes" {
    // Technique with only on_hit override
    const partial_technique = Technique{
        .id = .swing,
        .name = "partial_override",
        .damage = .{
            .instances = &.{.{ .amount = 0.5, .types = &.{.slash} }},
            .scaling = .{ .ratio = 0.5, .stats = .{ .stat = .speed } },
        },
        .difficulty = 0.5,
        .advantage = .{
            .on_hit = .{ .pressure = 0.50 }, // only on_hit specified
            // on_miss, on_blocked, etc use defaults
        },
    };

    // on_miss should use default even though technique has advantage struct
    const miss_effect = getAdvantageEffect(&partial_technique, .miss, .guarded);
    try std.testing.expectApproxEqAbs(@as(f32, -0.15), miss_effect.control, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -0.10), miss_effect.self_balance, 0.001);
}

test "getAdvantageEffect scales technique override by stakes" {
    const custom_technique = Technique{
        .id = .swing,
        .name = "scaled_override",
        .damage = .{
            .instances = &.{.{ .amount = 0.5, .types = &.{.slash} }},
            .scaling = .{ .ratio = 0.5, .stats = .{ .stat = .speed } },
        },
        .difficulty = 0.5,
        .advantage = .{
            .on_hit = .{ .pressure = 0.20 },
        },
    };

    const guarded = getAdvantageEffect(&custom_technique, .hit, .guarded);
    const reckless = getAdvantageEffect(&custom_technique, .hit, .reckless);

    // Guarded = 1.0x, reckless hit = 1.5x
    try std.testing.expectApproxEqAbs(@as(f32, 0.20), guarded.pressure, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), reckless.pressure, 0.001);
}
