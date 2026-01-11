//! Combat Tuning Constants Index
//!
//! Re-exports all gameplay-relevant tuning constants from resolution modules.
//! This serves as a central reference for balance-affecting values.
//!
//! For positioning constants (manoeuvre contests), see:
//!   src/domain/apply/effects/positioning.zig
//!
//! Note: Constants are pub in their source files for direct access where needed.
//! This module provides a consolidated view for tuning and documentation.

const outcome = @import("outcome.zig");
const context = @import("context.zig");

// ============================================================================
// Hit Chance (from outcome.zig)
// ============================================================================

/// Base hit probability before any modifiers (50%).
pub const base_hit_chance = outcome.base_hit_chance;

/// Technique difficulty multiplier (higher difficulty = harder to land).
pub const technique_difficulty_mult = outcome.technique_difficulty_mult;

/// Weapon accuracy multiplier (accurate weapons are easier to land).
pub const weapon_accuracy_mult = outcome.weapon_accuracy_mult;

/// Engagement advantage multiplier (tactical positioning importance).
pub const engagement_advantage_mult = outcome.engagement_advantage_mult;

/// Attacker balance multiplier (unbalanced = less accurate).
pub const attacker_balance_mult = outcome.attacker_balance_mult;

/// Defender imbalance multiplier (unbalanced = easier to hit).
pub const defender_imbalance_mult = outcome.defender_imbalance_mult;

/// Weapon parry rating multiplier.
pub const weapon_parry_mult = outcome.weapon_parry_mult;

/// Minimum/maximum hit chance after all modifiers.
pub const hit_chance_min = outcome.hit_chance_min;
pub const hit_chance_max = outcome.hit_chance_max;

// --- Guard Coverage ---

/// Penalty when guard directly covers attack zone.
pub const guard_direct_cover_penalty = outcome.guard_direct_cover_penalty;

/// Penalty when guard partially covers adjacent zone.
pub const guard_adjacent_cover_penalty = outcome.guard_adjacent_cover_penalty;

/// Bonus when attacking an unguarded opening.
pub const guard_opening_bonus = outcome.guard_opening_bonus;

// ============================================================================
// Condition Modifiers (from context.zig)
// ============================================================================

// --- Blinded Attacker ---

pub const blinded_thrust_penalty = context.blinded_thrust_penalty;
pub const blinded_swing_penalty = context.blinded_swing_penalty;
pub const blinded_ranged_penalty = context.blinded_ranged_penalty;
pub const blinded_other_penalty = context.blinded_other_penalty;

// --- Winded Attacker ---

pub const winded_power_attack_damage_mult = context.winded_power_attack_damage_mult;

// --- Grasp Strength (Wounded Hand) ---

pub const grasp_hit_penalty_max = context.grasp_hit_penalty_max;
pub const grasp_damage_mult_min = context.grasp_damage_mult_min;

// --- Defender Positioning ---

pub const stationary_dodge_penalty = context.stationary_dodge_penalty;
pub const partial_flanking_dodge_penalty = context.partial_flanking_dodge_penalty;
pub const surrounded_dodge_penalty = context.surrounded_dodge_penalty;
pub const surrounded_defense_mult = context.surrounded_defense_mult;

// --- Blinded Defender ---

pub const blinded_defense_mult = context.blinded_defense_mult;
pub const blinded_dodge_penalty = context.blinded_dodge_penalty;

// --- Mobility (Wounded Legs) ---

pub const mobility_dodge_penalty_max = context.mobility_dodge_penalty_max;
