/// Context structs shared across resolution calculations.
///
/// Defines attack/defense context payloads and aggregate modifier helpers.
/// Contains no orchestration logic or event dispatch.
const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const combat = @import("../combat.zig");
const cards = @import("../cards.zig");
const weapon = @import("../weapon.zig");
const world = @import("../world.zig");

const Agent = combat.Agent;
const Engagement = combat.Engagement;
const Technique = cards.Technique;
const Stakes = cards.Stakes;
const World = world.World;

// ============================================================================
// Attack and Defense Contexts
// ============================================================================

pub const AttackContext = struct {
    attacker: *Agent,
    defender: *Agent,
    technique: *const Technique,
    weapon_template: *const weapon.Template,
    stakes: Stakes,
    engagement: *Engagement,
    // Timing for overlay bonus calculation
    time_start: f32 = 0,
    time_end: f32 = 1.0,
};

pub const DefenseContext = struct {
    defender: *Agent,
    technique: ?*const Technique, // null = passive defense
    weapon_template: *const weapon.Template,
    engagement: ?*const Engagement = null, // for computed conditions
    is_stationary: bool = false, // no footwork in timeline
    // Timing for overlay bonus calculation
    time_start: f32 = 0,
    time_end: f32 = 1.0,
};

// ============================================================================
// Condition-based Combat Modifiers
// ============================================================================

/// Aggregate combat modifiers derived from active conditions
pub const CombatModifiers = struct {
    hit_chance: f32 = 0, // additive modifier to hit chance
    damage_mult: f32 = 1.0, // multiplicative damage modifier
    defense_mult: f32 = 1.0, // affects block/parry/deflect effectiveness
    dodge_mod: f32 = 0, // additive modifier to dodge chance

    /// Compute modifiers for an attacker based on their conditions and attack context
    pub fn forAttacker(attack: AttackContext) CombatModifiers {
        var mods = CombatModifiers{};

        var iter = attack.attacker.activeConditions(attack.engagement);
        while (iter.next()) |cond| {
            switch (cond.condition) {
                .blinded => {
                    // Precision matters more when you can't see
                    mods.hit_chance += switch (attack.technique.attack_mode) {
                        .thrust => -0.30, // precision strike
                        .swing => -0.20, // arc compensates somewhat
                        .ranged => -0.45, // ranged attacks rely heavily on sight
                        .none => -0.15, // defensive/other
                    };
                },
                .stunned => {
                    mods.hit_chance -= 0.20;
                    mods.damage_mult *= 0.7;
                },
                .prone => {
                    mods.hit_chance -= 0.15;
                    mods.damage_mult *= 0.8;
                },
                .winded => {
                    // Power attacks suffer more
                    if (attack.stakes == .committed or attack.stakes == .reckless) {
                        mods.damage_mult *= 0.85;
                    }
                },
                .confused => {
                    mods.hit_chance -= 0.15;
                },
                .shaken, .fearful => {
                    mods.hit_chance -= 0.10;
                    mods.damage_mult *= 0.9;
                },
                .unbalanced => {
                    // Poor balance affects accuracy
                    mods.hit_chance -= 0.10;
                },
                else => {},
            }
        }

        return mods;
    }

    /// Compute modifiers for a defender based on their conditions and defense context
    pub fn forDefender(defense: DefenseContext) CombatModifiers {
        var mods = CombatModifiers{};

        // Check stationary flag (computed from timeline at resolver level)
        if (defense.is_stationary) {
            // Stationary defender is easier to hit (+10% for attacker)
            mods.dodge_mod -= 0.10;
        }

        var iter = defense.defender.activeConditions(defense.engagement);
        while (iter.next()) |cond| {
            switch (cond.condition) {
                .blinded => {
                    // Can't see attacks coming
                    mods.defense_mult *= 0.6;
                    mods.dodge_mod -= 0.20;
                },
                .stunned => {
                    mods.defense_mult *= 0.3;
                    mods.dodge_mod -= 0.30;
                },
                .prone => {
                    mods.dodge_mod -= 0.25;
                    // But might be harder to hit high
                },
                .paralysed => {
                    mods.defense_mult *= 0.0; // can't actively defend
                    mods.dodge_mod -= 0.40;
                },
                .surprised => {
                    mods.defense_mult *= 0.5;
                    mods.dodge_mod -= 0.20;
                },
                .unconscious, .comatose => {
                    mods.defense_mult *= 0.0;
                    mods.dodge_mod -= 0.50;
                },
                .pressured => {
                    // Under pressure, harder to defend effectively
                    mods.defense_mult *= 0.85;
                },
                .weapon_bound => {
                    // Weapon tied up, active defense compromised
                    mods.defense_mult *= 0.7;
                },
                .unbalanced => {
                    // Poor balance makes dodging harder
                    mods.dodge_mod -= 0.15;
                },
                else => {},
            }
        }

        return mods;
    }
};

// ============================================================================
// Manoeuvre Overlay Bonuses
// ============================================================================

/// Aggregated overlay bonuses from overlapping manoeuvres
pub const AggregatedOverlay = struct {
    to_hit_bonus: f32 = 0,
    damage_mult: f32 = 1.0,
    defense_bonus: f32 = 0,
};

/// Scan an agent's timeline for overlapping manoeuvres and aggregate their bonuses.
/// Returns bonuses applicable to offensive or defensive techniques.
pub fn getOverlayBonuses(
    w: *const World,
    agent_id: entity.ID,
    time_start: f32,
    time_end: f32,
    for_offensive: bool,
) AggregatedOverlay {
    var result = AggregatedOverlay{};

    const enc = w.encounter orelse return result;
    const enc_state = enc.stateForConst(agent_id) orelse return result;

    for (enc_state.current.slots()) |slot| {
        // Check time overlap
        if (!slot.overlapsWith(time_start, time_end, &w.card_registry)) continue;

        // Get the card and check if it's a manoeuvre with overlay bonus
        const card = w.card_registry.getConst(slot.play.action) orelse continue;
        if (!card.template.tags.manoeuvre) continue;

        // Get technique info for overlay bonus
        const tech_expr = card.template.getTechniqueWithExpression() orelse continue;
        const overlay = tech_expr.technique.overlay_bonus orelse continue;

        // Aggregate bonuses based on what we're applying to
        if (for_offensive) {
            result.to_hit_bonus += overlay.offensive.to_hit_bonus;
            result.damage_mult *= overlay.offensive.damage_mult;
        } else {
            result.defense_bonus += overlay.defensive.defense_bonus;
        }
    }

    return result;
}
