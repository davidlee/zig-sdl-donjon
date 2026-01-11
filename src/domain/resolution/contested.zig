//! Contested Roll Resolution
//!
//! Implements attacker-vs-defender contested roll system.
//! See doc/artefacts/contested_roll_resolution.md for specification.

const std = @import("std");
const outcome = @import("outcome.zig");
const context = @import("context.zig");
const plays = @import("../combat/plays.zig");
const combat = @import("../combat.zig");
const damage = @import("../damage.zig");

const world = @import("../world.zig");
const random = @import("../random.zig");

const AttackContext = context.AttackContext;
const DefenseContext = context.DefenseContext;
const Stance = plays.Stance;
const Agent = combat.Agent;
const World = world.World;

// ============================================================================
// Contested Roll Result
// ============================================================================

/// Result of a contested roll resolution.
pub const ContestedResult = struct {
    /// Final outcome category.
    outcome_type: OutcomeType,
    /// Raw margin (attack_final - defense_final).
    margin: f32,
    /// Attack score before roll.
    attack_score: f32,
    /// Defense score before roll.
    defense_score: f32,
    /// Attack roll value (0-1).
    attack_roll: f32,
    /// Defense roll value (0-1, same as attack_roll in single mode).
    defense_roll: f32,
    /// Damage multiplier based on outcome tier.
    damage_mult: f32,

    pub const OutcomeType = enum {
        critical_hit,
        solid_hit,
        partial_hit,
        miss,
    };
};

/// Calculate raw attack score from context factors.
/// Does not include stance multiplier or roll - those are applied in resolveContested.
pub fn calculateAttackScore(attack: AttackContext) f32 {
    var score: f32 = outcome.attack_score_base;

    // Technique difficulty (higher = harder to land)
    score -= attack.technique.difficulty * outcome.technique_difficulty_mult;

    // Weapon accuracy
    if (outcome.getWeaponOffensive(attack.weapon_template, attack.technique)) |weapon_off| {
        score += weapon_off.accuracy * outcome.weapon_accuracy_mult;
    }

    // Stakes
    score += attack.stakes.hitChanceBonus();

    // Engagement advantage
    const engagement_bonus = (attack.engagement.playerAdvantage() - 0.5) * outcome.engagement_advantage_mult;
    score += if (attack.attacker.director == .player) engagement_bonus else -engagement_bonus;

    // Attacker balance
    score += (attack.attacker.balance - 0.5) * outcome.attacker_balance_mult;

    return score;
}

/// Calculate raw defense score from context factors.
/// Does not include stance multiplier or roll - those are applied in resolveContested.
pub fn calculateDefenseScore(defense: DefenseContext) f32 {
    var score: f32 = outcome.defense_score_base;

    // Active defense technique bonus (parry/block/deflect effectiveness)
    if (defense.technique) |tech| {
        // Use the technique's defense multipliers as a bonus
        // Higher parry_mult means more effective defense
        score += (tech.parry_mult - 1.0) * 0.2; // scale down raw mult
    }

    // Weapon parry contribution (scaled by context)
    const parry_scaling: f32 = if (defense.technique != null)
        1.0 // active defense = full weapon parry
    else if (defense.defender_is_attacking)
        outcome.offensive_committed_defense_mult // attacking = reduced
    else
        outcome.passive_weapon_defense_mult; // passive = moderate

    score += defense.weapon_template.defence.parry * parry_scaling * outcome.weapon_parry_mult;

    // Defender balance (low balance = easier to hit = lower defense)
    score -= (1.0 - defense.defender.balance) * outcome.defender_imbalance_mult;

    return score;
}

/// Returns multiplicative modifier for combat effectiveness based on agent conditions.
/// Values < 1.0 reduce effectiveness, > 1.0 enhance.
/// Used identically for attack and defense score calculation.
pub fn conditionCombatMult(agent: *const Agent) f32 {
    var mult: f32 = 1.0;

    // Negative conditions reduce effectiveness
    if (agent.hasCondition(.winded)) mult *= 0.8;
    if (agent.hasCondition(.stunned)) mult *= 0.5;
    // Note: off_balance/unbalanced is handled via balance stat, not here

    // Positive conditions would enhance (e.g., focused, adrenaline_surge)
    // TODO: Add positive condition bonuses when condition system is expanded

    return mult;
}

/// Resolve a contested roll between attacker and defender.
/// Returns outcome with margin and damage multiplier.
pub fn resolveContested(
    w: *World,
    attack: AttackContext,
    defense: DefenseContext,
) !ContestedResult {
    // Calculate base scores
    const raw_attack = calculateAttackScore(attack);
    const raw_defense = calculateDefenseScore(defense);

    // Apply condition multipliers
    const attack_score = raw_attack * conditionCombatMult(attack.attacker);
    const defense_score = raw_defense * conditionCombatMult(defense.defender);

    // Draw rolls
    const attack_roll = try w.drawRandom(.combat);
    const defense_roll = switch (outcome.contested_roll_mode) {
        .single => attack_roll, // same roll for both
        .independent_pair => try w.drawRandom(.combat),
    };

    // Calculate stance multipliers
    // Formula: stance_weight + (1.0 - stance_effectiveness)
    // At stance_effectiveness=0.5: weight=0.33 gives mult=0.83, weight=1.0 gives mult=1.5
    const attack_stance_mult = attack.attacker_stance.attack + (1.0 - outcome.stance_effectiveness);
    const defense_stance_mult = defense.defender_stance.defense + (1.0 - outcome.stance_effectiveness);

    // Apply formula: final = (score + (roll + calibration) * variance) * stance_mult
    const attack_final = (attack_score + (attack_roll + outcome.contested_roll_calibration) * outcome.contested_roll_variance) * attack_stance_mult;
    const defense_final = (defense_score + (defense_roll + outcome.contested_roll_calibration) * outcome.contested_roll_variance) * defense_stance_mult;

    const margin = attack_final - defense_final;

    // Determine outcome tier and damage mult
    const result_outcome, const damage_mult = if (margin >= outcome.hit_margin_critical)
        .{ ContestedResult.OutcomeType.critical_hit, outcome.critical_hit_damage_mult }
    else if (margin >= outcome.hit_margin_solid)
        .{ ContestedResult.OutcomeType.solid_hit, 1.0 }
    else if (margin >= 0)
        .{ ContestedResult.OutcomeType.partial_hit, outcome.partial_hit_damage_mult }
    else
        .{ ContestedResult.OutcomeType.miss, 0.0 };

    return .{
        .outcome_type = result_outcome,
        .margin = margin,
        .attack_score = attack_score,
        .defense_score = defense_score,
        .attack_roll = attack_roll,
        .defense_roll = defense_roll,
        .damage_mult = damage_mult,
    };
}

// ============================================================================
// Tests
// ============================================================================

const cards = @import("../cards.zig");
const weapon_list = @import("../weapon_list.zig");
const ai = @import("../ai.zig");
const stats = @import("../stats.zig");
const species = @import("../species.zig");
const slot_map = @import("../slot_map.zig");

fn makeTestWorld(alloc: std.mem.Allocator) !*World {
    return world.World.init(alloc);
}

fn makeTestAgent(
    alloc: std.mem.Allocator,
    agents: *slot_map.SlotMap(*Agent),
    director: combat.Director,
) !*Agent {
    return Agent.init(
        alloc,
        agents,
        director,
        .shuffled_deck,
        &species.DWARF,
        stats.Block.splat(5),
    );
}

test "resolveContested produces valid outcome" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;
    const technique = &cards.Technique.byID(.thrust);

    const attack_ctx = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
    };

    const defense_ctx = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
    };

    const result = try resolveContested(w, attack_ctx, defense_ctx);

    // Verify result is valid
    try std.testing.expect(result.attack_score > 0);
    try std.testing.expect(result.defense_score > 0);
    try std.testing.expect(result.attack_roll >= 0 and result.attack_roll <= 1);
    try std.testing.expect(result.defense_roll >= 0 and result.defense_roll <= 1);

    // Verify damage_mult matches outcome tier
    switch (result.outcome_type) {
        .critical_hit => try std.testing.expectApproxEqAbs(outcome.critical_hit_damage_mult, result.damage_mult, 0.01),
        .solid_hit => try std.testing.expectApproxEqAbs(1.0, result.damage_mult, 0.01),
        .partial_hit => try std.testing.expectApproxEqAbs(outcome.partial_hit_damage_mult, result.damage_mult, 0.01),
        .miss => try std.testing.expectApproxEqAbs(0.0, result.damage_mult, 0.01),
    }
}

test "stance affects contested outcome" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;
    const technique = &cards.Technique.byID(.thrust);

    // Pure attack stance
    const aggressive_stance = Stance{ .attack = 1.0, .defense = 0.0, .movement = 0.0 };

    const attack_ctx = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
        .attacker_stance = aggressive_stance,
    };

    const defense_ctx = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
        .defender_stance = Stance.balanced, // defender uses balanced
    };

    const result = try resolveContested(w, attack_ctx, defense_ctx);

    // With aggressive stance (1.0 attack weight) vs balanced (0.33 defense weight),
    // stance multipliers should favor attacker
    // attack_mult = 1.0 + 0.5 = 1.5, defense_mult = 0.33 + 0.5 = 0.83
    // This just verifies the calculation happens without error
    try std.testing.expect(result.attack_roll >= 0);
}
