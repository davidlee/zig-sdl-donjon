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

test "calculateAttackScore base case" {
    // Needs proper test fixtures (makeTestWorld, makeTestAgent)
    // Full coverage via integration tests in Task 9
}
