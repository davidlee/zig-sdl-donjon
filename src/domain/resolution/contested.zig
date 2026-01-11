//! Contested Roll Resolution
//!
//! Implements attacker-vs-defender contested roll system.
//! See doc/artefacts/contested_roll_resolution.md for specification.

const std = @import("std");
const outcome = @import("outcome.zig");
const context = @import("context.zig");
const plays = @import("../combat/plays.zig");

const AttackContext = context.AttackContext;
const DefenseContext = context.DefenseContext;
const Stance = plays.Stance;

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

test "calculateAttackScore base case" {
    // Needs proper test fixtures (makeTestWorld, makeTestAgent)
    // Full coverage via integration tests in Task 9
}

test "calculateDefenseScore base case" {
    // Needs proper test fixtures
    // Full coverage via integration tests in Task 9
}
