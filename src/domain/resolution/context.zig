/// Context structs shared across resolution calculations.
///
/// Defines attack/defense context payloads and aggregate modifier helpers.
/// Contains no orchestration logic or event dispatch.
const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const combat = @import("../combat.zig");
const actions = @import("../actions.zig");
const damage = @import("../damage.zig");
const weapon = @import("../weapon.zig");
const world = @import("../world.zig");

const plays = @import("../combat/plays.zig");

const Agent = combat.Agent;
const Engagement = combat.Engagement;
const FlankingStatus = combat.FlankingStatus;
const Technique = actions.Technique;
const Stakes = actions.Stakes;
const Stance = plays.Stance;
const World = world.World;

// ============================================================================
// Computed Combat State
// ============================================================================

/// Transient combat state computed per-agent in the resolver pipeline.
/// Captures encounter-level derived conditions that require full context.
pub const ComputedCombatState = struct {
    flanking: FlankingStatus = .none,
    is_stationary: bool = false, // no footwork in timeline this tick
    // Future: momentum, facing, stance_broken, etc.
};

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
    // Attention penalty when attacking non-primary target (derived from AttentionState)
    attention_penalty: f32 = 0,
    /// Attacker's stance weights for this turn.
    attacker_stance: Stance = Stance.balanced,
};

pub const DefenseContext = struct {
    defender: *Agent,
    technique: ?*const Technique, // null = passive defense
    weapon_template: *const weapon.Template,
    engagement: ?*const Engagement = null, // for computed conditions
    computed: ComputedCombatState = .{}, // encounter-level derived state
    // Timing for overlay bonus calculation
    time_start: f32 = 0,
    time_end: f32 = 1.0,
    /// Defender's stance weights for this turn.
    defender_stance: Stance = Stance.balanced,
    /// Whether defender is attacking in the same time slice (affects weapon defense).
    defender_is_attacking: bool = false,
};

// ============================================================================
// Condition-based Combat Modifier Constants
// ============================================================================

// --- Blinded attacker penalties (by attack mode) ---

/// Hit penalty when blinded and using a thrust attack.
/// Precision strikes suffer most without sight.
pub const blinded_thrust_penalty: f32 = -0.30;

/// Hit penalty when blinded and using a swing attack.
/// Wide arcs partially compensate for lack of sight.
pub const blinded_swing_penalty: f32 = -0.20;

/// Hit penalty when blinded and using a ranged attack.
/// Ranged attacks rely heavily on visual targeting.
pub const blinded_ranged_penalty: f32 = -0.45;

/// Hit penalty when blinded using other attack modes.
/// Baseline penalty for defensive or unconventional attacks.
pub const blinded_other_penalty: f32 = -0.15;

// --- Winded attacker penalty ---

/// Damage multiplier when winded and using committed/reckless stakes.
/// Power attacks drain more from exhausted combatants.
pub const winded_power_attack_damage_mult: f32 = 0.85;

// --- Grasp strength penalties (wounded weapon hand) ---

/// Maximum hit penalty at zero grasp strength.
/// Inability to grip weapon reduces accuracy.
pub const grasp_hit_penalty_max: f32 = -0.25;

/// Minimum damage multiplier at zero grasp strength.
/// Weak grip reduces striking power.
pub const grasp_damage_mult_min: f32 = 0.5;

// --- Defender stationary/flanking penalties ---

/// Dodge penalty when defender is stationary (no footwork).
/// Standing still makes you predictable and easier to hit.
pub const stationary_dodge_penalty: f32 = -0.10;

/// Dodge penalty when partially flanked.
/// One enemy has angle advantage on you.
pub const partial_flanking_dodge_penalty: f32 = -0.10;

/// Dodge penalty when surrounded.
/// Multiple enemies or severe angle disadvantage.
pub const surrounded_dodge_penalty: f32 = -0.20;

/// Defense multiplier when surrounded.
/// Can't defend effectively against multiple angles.
pub const surrounded_defense_mult: f32 = 0.85;

// --- Blinded defender penalties ---

/// Defense multiplier when blinded.
/// Can't see attacks to properly defend.
pub const blinded_defense_mult: f32 = 0.6;

/// Dodge penalty when blinded.
/// Can't see attacks to evade them.
pub const blinded_dodge_penalty: f32 = -0.20;

// --- Mobility penalty (wounded legs) ---

/// Maximum dodge penalty at zero mobility.
/// Wounded legs severely impair evasion.
pub const mobility_dodge_penalty_max: f32 = -0.30;

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
        var penalties = damage.CombatPenalties{};

        var iter = attack.attacker.activeConditions(attack.engagement);
        while (iter.next()) |cond| {
            // Context-dependent conditions handled specially
            switch (cond.condition) {
                .blinded => {
                    // Precision matters more when you can't see
                    mods.hit_chance += switch (attack.technique.attack_mode) {
                        .thrust => blinded_thrust_penalty,
                        .swing => blinded_swing_penalty,
                        .ranged => blinded_ranged_penalty,
                        .none => blinded_other_penalty,
                    };
                },
                .winded => {
                    // Power attacks suffer more
                    if (attack.stakes == .committed or attack.stakes == .reckless) {
                        mods.damage_mult *= winded_power_attack_damage_mult;
                    }
                },
                else => {
                    // Table lookup for simple conditions
                    penalties = penalties.combine(damage.penaltiesFor(cond.condition));
                },
            }
        }

        // Apply table-derived penalties
        mods.hit_chance += penalties.hit_chance;
        mods.damage_mult *= penalties.damage_mult;

        // Apply attention penalty for attacking non-primary target
        mods.hit_chance -= attack.attention_penalty;

        // Grasp strength penalty: wounded weapon hand reduces accuracy/damage
        if (attack.attacker.body.graspingPartBySide(attack.attacker.dominant_side)) |hand_idx| {
            const grasp = attack.attacker.body.graspStrength(hand_idx);
            if (grasp < 1.0) {
                mods.hit_chance += (1.0 - grasp) * grasp_hit_penalty_max;
                mods.damage_mult *= grasp_damage_mult_min + (grasp * grasp_damage_mult_min);
            }
        }

        return mods;
    }

    /// Compute modifiers for a defender based on their conditions and defense context
    pub fn forDefender(defense: DefenseContext) CombatModifiers {
        var mods = CombatModifiers{};
        var penalties = damage.CombatPenalties{};

        // Combat state modifiers (computed from positioning, not conditions)
        if (defense.computed.is_stationary) {
            mods.dodge_mod += stationary_dodge_penalty;
        }

        switch (defense.computed.flanking) {
            .partial => {
                mods.dodge_mod += partial_flanking_dodge_penalty;
            },
            .surrounded => {
                mods.dodge_mod += surrounded_dodge_penalty;
                mods.defense_mult *= surrounded_defense_mult;
            },
            .none => {},
        }

        var iter = defense.defender.activeConditions(defense.engagement);
        while (iter.next()) |cond| {
            // Context-dependent conditions handled specially
            switch (cond.condition) {
                .blinded => {
                    // Can't see attacks coming
                    mods.defense_mult *= blinded_defense_mult;
                    mods.dodge_mod += blinded_dodge_penalty;
                },
                else => {
                    // Table lookup for simple conditions
                    penalties = penalties.combine(damage.penaltiesFor(cond.condition));
                },
            }
        }

        // Apply table-derived penalties
        mods.defense_mult *= penalties.defense_mult;
        mods.dodge_mod += penalties.dodge_mod;

        // Mobility penalty: wounded legs reduce dodge capability
        const mobility = defense.defender.body.mobilityScore();
        if (mobility < 1.0) {
            mods.dodge_mod += (1.0 - mobility) * mobility_dodge_penalty_max;
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
        if (!slot.overlapsWith(time_start, time_end, &w.action_registry)) continue;

        // Get the card and check if it's a manoeuvre with overlay bonus
        const card = w.action_registry.getConst(slot.play.action) orelse continue;
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const ai = @import("../ai.zig");
const stats = @import("../stats.zig");
const species = @import("../species.zig");
const slot_map = @import("../slot_map.zig");
const card_list = @import("../action_list.zig");

fn makeTestWorld(alloc: std.mem.Allocator) !*World {
    return World.init(alloc);
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

fn findCardByName(w: *World, name: []const u8) ?entity.ID {
    for (w.player.always_available.items) |card_id| {
        const card = w.action_registry.getConst(card_id) orelse continue;
        if (std.mem.eql(u8, card.template.name, name)) {
            return card_id;
        }
    }
    return null;
}

test "getOverlayBonuses returns empty for agent with no timeline plays" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    // Player has no plays in timeline
    const result = getOverlayBonuses(w, w.player.id, 0.0, 1.0, true);

    try testing.expectEqual(@as(f32, 0), result.to_hit_bonus);
    try testing.expectEqual(@as(f32, 1.0), result.damage_mult);
    try testing.expectEqual(@as(f32, 0), result.defense_bonus);
}

test "getOverlayBonuses aggregates advance damage bonus" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    // Find advance card in player's always_available pool
    const advance_id = findCardByName(w, "advance") orelse return error.TestSkipped;

    // Get player's encounter state and add play to timeline
    const enc = w.encounter orelse return error.TestSkipped;
    const enc_state = enc.stateFor(w.player.id) orelse return error.TestSkipped;

    // Add advance play (footwork channel, 0.3s duration)
    try enc_state.current.addPlay(
        .{ .action = advance_id, .target = null },
        &w.action_registry,
    );

    // Query overlay bonuses for offensive technique overlapping with advance
    const result = getOverlayBonuses(w, w.player.id, 0.0, 0.5, true);

    // Advance gives +10% damage (damage_mult = 1.10)
    try testing.expectApproxEqAbs(@as(f32, 1.10), result.damage_mult, 0.001);
    try testing.expectEqual(@as(f32, 0), result.to_hit_bonus);
}

test "getOverlayBonuses aggregates sidestep to_hit bonus" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const sidestep_id = findCardByName(w, "sidestep") orelse return error.TestSkipped;

    const enc = w.encounter orelse return error.TestSkipped;
    const enc_state = enc.stateFor(w.player.id) orelse return error.TestSkipped;

    try enc_state.current.addPlay(
        .{ .action = sidestep_id, .target = null },
        &w.action_registry,
    );

    const result = getOverlayBonuses(w, w.player.id, 0.0, 0.5, true);

    // Sidestep gives +5% to_hit (to_hit_bonus = 0.05)
    try testing.expectApproxEqAbs(@as(f32, 0.05), result.to_hit_bonus, 0.001);
}

test "getOverlayBonuses aggregates retreat defense bonus" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const retreat_id = findCardByName(w, "retreat") orelse return error.TestSkipped;

    const enc = w.encounter orelse return error.TestSkipped;
    const enc_state = enc.stateFor(w.player.id) orelse return error.TestSkipped;

    try enc_state.current.addPlay(
        .{ .action = retreat_id, .target = null },
        &w.action_registry,
    );

    // Query for defensive overlay
    const result = getOverlayBonuses(w, w.player.id, 0.0, 0.5, false);

    // Retreat gives +0.10 defense bonus
    try testing.expectApproxEqAbs(@as(f32, 0.10), result.defense_bonus, 0.001);
}

test "getOverlayBonuses aggregates multiple overlapping manoeuvres" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const advance_id = findCardByName(w, "advance") orelse return error.TestSkipped;
    const sidestep_id = findCardByName(w, "sidestep") orelse return error.TestSkipped;

    const enc = w.encounter orelse return error.TestSkipped;
    const enc_state = enc.stateFor(w.player.id) orelse return error.TestSkipped;

    // Add both manoeuvres (they use same footwork channel, so second goes after first)
    try enc_state.current.addPlay(
        .{ .action = advance_id, .target = null },
        &w.action_registry,
    );
    // Note: advance takes 0.3s, sidestep would start at 0.3 due to channel conflict
    // For this test, we'll check over the full timeline
    try enc_state.current.addPlay(
        .{ .action = sidestep_id, .target = null },
        &w.action_registry,
    );

    // Query over time window that covers both manoeuvres (0.0 to 1.0)
    const result = getOverlayBonuses(w, w.player.id, 0.0, 1.0, true);

    // Both advance (+10% damage) and sidestep (+5% to_hit) should apply
    try testing.expectApproxEqAbs(@as(f32, 1.10), result.damage_mult, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.05), result.to_hit_bonus, 0.001);
}

test "CombatModifiers.forDefender applies stationary penalty" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    // Add to encounter so cleanup happens
    try w.encounter.?.addEnemy(defender);

    // Create defense context with is_stationary = true via computed state
    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        .computed = .{ .is_stationary = true },
    };

    const mods = CombatModifiers.forDefender(defense);

    // Stationary penalty: -10% dodge (easier to hit)
    try testing.expectApproxEqAbs(@as(f32, -0.10), mods.dodge_mod, 0.001);
}

test "CombatModifiers.forDefender no penalty when not stationary" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    // Add to encounter so cleanup happens
    try w.encounter.?.addEnemy(defender);

    // Create defense context with is_stationary = false (default)
    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        // computed defaults to .{ .is_stationary = false, .flanking = .none }
    };

    const mods = CombatModifiers.forDefender(defense);

    // No stationary penalty
    try testing.expectEqual(@as(f32, 0), mods.dodge_mod);
}

test "CombatModifiers.forAttacker applies attention penalty for non-primary target" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;
    const technique = &actions.Technique.byID(.thrust);

    // Set attention penalty to 0.15 (simulating non-primary target)
    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
        .attention_penalty = 0.15,
    };

    const mods = CombatModifiers.forAttacker(attack);

    // Attention penalty should reduce hit_chance by 0.15
    try testing.expectApproxEqAbs(@as(f32, -0.15), mods.hit_chance, 0.001);
}

test "CombatModifiers.forAttacker no penalty when attention_penalty is zero" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;
    const technique = &actions.Technique.byID(.thrust);

    // No attention penalty (primary target)
    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
        .attention_penalty = 0,
    };

    const mods = CombatModifiers.forAttacker(attack);

    // No penalty = 0 hit_chance modifier (assuming no conditions)
    try testing.expectEqual(@as(f32, 0), mods.hit_chance);
}

test "CombatModifiers.forDefender applies partial flanking penalty" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        .computed = .{ .flanking = .partial },
    };

    const mods = CombatModifiers.forDefender(defense);

    // Partial flanking: -10% dodge
    try testing.expectApproxEqAbs(@as(f32, -0.10), mods.dodge_mod, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), mods.defense_mult, 0.001);
}

test "CombatModifiers.forDefender applies surrounded penalty" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        .computed = .{ .flanking = .surrounded },
    };

    const mods = CombatModifiers.forDefender(defense);

    // Surrounded: -20% dodge and 0.85x defense_mult
    try testing.expectApproxEqAbs(@as(f32, -0.20), mods.dodge_mod, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.85), mods.defense_mult, 0.001);
}

test "CombatModifiers.forAttacker applies grasp strength penalty" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;
    const technique = &actions.Technique.byID(.thrust);

    // Damage the dominant hand (right by default)
    const right_hand = attacker.body.graspingPartBySide(.right).?;
    attacker.body.parts.items[right_hand].severity = .disabled; // 0.3 integrity

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
        .attention_penalty = 0,
    };

    const mods = CombatModifiers.forAttacker(attack);

    // Grasp strength with disabled hand (~0.3 integrity) reduces attack
    // (1-grasp)*-0.25 for hit_chance, damage_mult = 0.5 + grasp*0.5
    try testing.expect(mods.hit_chance < 0); // negative penalty applied
    try testing.expect(mods.damage_mult < 1.0); // damage reduced from base
    try testing.expect(mods.damage_mult > 0.5); // but not below 50%
}

test "CombatModifiers.forDefender applies mobility penalty" {
    const alloc = testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    // Damage legs (can_stand parts) to reduce mobility
    for (defender.body.parts.items) |*part| {
        if (part.flags.can_stand) {
            part.severity = .disabled; // 0.3 integrity
        }
    }

    // Verify mobility is reduced
    try testing.expect(defender.body.mobilityScore() < 0.5);

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
    };

    const mods = CombatModifiers.forDefender(defense);

    // Mobility ~0.3 → (1-0.3)*-0.30 = -0.21 dodge_mod
    try testing.expect(mods.dodge_mod < -0.15);
}
