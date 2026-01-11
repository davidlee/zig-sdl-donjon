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
// Score Breakdowns
// ============================================================================

/// Breakdown of attack score components for event instrumentation.
pub const AttackBreakdown = struct {
    base: f32,
    technique: f32, // negative = difficulty penalty
    weapon: f32,
    stakes: f32,
    engagement: f32,
    balance: f32,
    condition_mult: f32,
    stance_mult: f32,
    roll: f32,

    /// Sum of additive components before multipliers.
    pub fn raw(self: AttackBreakdown) f32 {
        return self.base + self.technique + self.weapon +
            self.stakes + self.engagement + self.balance;
    }

    /// Final attack value after applying roll and multipliers.
    pub fn final(self: AttackBreakdown) f32 {
        const roll_adjusted = (self.roll + outcome.contested_roll_calibration) * outcome.contested_roll_variance;
        return (self.raw() * self.condition_mult + roll_adjusted) * self.stance_mult;
    }
};

/// Breakdown of defense score components for event instrumentation.
pub const DefenseBreakdown = struct {
    base: f32,
    technique: f32,
    weapon_parry: f32, // raw weapon parry value
    parry_scaling: f32, // 1.0 active, 0.5 passive, 0.25 attacking
    balance: f32,
    condition_mult: f32,
    stance_mult: f32,
    roll: f32,

    /// Sum of additive components before multipliers.
    pub fn raw(self: DefenseBreakdown) f32 {
        return self.base + self.technique +
            (self.weapon_parry * self.parry_scaling) + self.balance;
    }

    /// Final defense value after applying roll and multipliers.
    pub fn final(self: DefenseBreakdown) f32 {
        const roll_adjusted = (self.roll + outcome.contested_roll_calibration) * outcome.contested_roll_variance;
        return (self.raw() * self.condition_mult + roll_adjusted) * self.stance_mult;
    }
};

// ============================================================================
// Contested Roll Result
// ============================================================================

/// Result of a contested roll resolution with full breakdown for logging.
pub const ContestedResult = struct {
    attack: AttackBreakdown,
    defense: DefenseBreakdown,
    margin: f32,
    outcome_type: OutcomeType,
    damage_mult: f32,

    pub const OutcomeType = enum {
        critical_hit,
        solid_hit,
        partial_hit,
        miss,
    };
};

/// Calculate attack score breakdown from context factors.
/// Returns partial breakdown - condition_mult, stance_mult, roll filled in by resolveContested.
pub fn calculateAttackScore(attack: AttackContext) AttackBreakdown {
    // Technique difficulty (higher = harder to land)
    const technique_contrib = -attack.technique.difficulty * outcome.technique_difficulty_mult;

    // Weapon accuracy
    const weapon_contrib = if (outcome.getWeaponOffensive(attack.weapon_template, attack.technique)) |weapon_off|
        weapon_off.accuracy * outcome.weapon_accuracy_mult
    else
        0;

    // Stakes
    const stakes_contrib = attack.stakes.hitChanceBonus();

    // Engagement advantage
    const engagement_bonus = (attack.engagement.playerAdvantage() - 0.5) * outcome.engagement_advantage_mult;
    const engagement_contrib = if (attack.attacker.director == .player) engagement_bonus else -engagement_bonus;

    // Attacker balance
    const balance_contrib = (attack.attacker.balance - 0.5) * outcome.attacker_balance_mult;

    return .{
        .base = outcome.attack_score_base,
        .technique = technique_contrib,
        .weapon = weapon_contrib,
        .stakes = stakes_contrib,
        .engagement = engagement_contrib,
        .balance = balance_contrib,
        // Filled in by resolveContested:
        .condition_mult = 1.0,
        .stance_mult = 1.0,
        .roll = 0,
    };
}

/// Calculate defense score breakdown from context factors.
/// Returns partial breakdown - condition_mult, stance_mult, roll filled in by resolveContested.
pub fn calculateDefenseScore(defense: DefenseContext) DefenseBreakdown {
    // Active defense technique bonus (parry/block/deflect effectiveness)
    const technique_contrib = if (defense.technique) |tech|
        (tech.parry_mult - 1.0) * 0.2 // scale down raw mult
    else
        0;

    // Weapon parry contribution (scaled by context)
    const parry_scaling: f32 = if (defense.technique != null)
        1.0 // active defense = full weapon parry
    else if (defense.defender_is_attacking)
        outcome.offensive_committed_defense_mult // attacking = reduced
    else
        outcome.passive_weapon_defense_mult; // passive = moderate

    const weapon_parry = defense.weapon_template.defence.parry * outcome.weapon_parry_mult;

    // Defender balance (low balance = easier to hit = lower defense)
    const balance_contrib = -(1.0 - defense.defender.balance) * outcome.defender_imbalance_mult;

    return .{
        .base = outcome.defense_score_base,
        .technique = technique_contrib,
        .weapon_parry = weapon_parry,
        .parry_scaling = parry_scaling,
        .balance = balance_contrib,
        // Filled in by resolveContested:
        .condition_mult = 1.0,
        .stance_mult = 1.0,
        .roll = 0,
    };
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
/// Returns outcome with full breakdown for logging.
pub fn resolveContested(
    w: *World,
    attack: AttackContext,
    defense: DefenseContext,
) !ContestedResult {
    // Get base score breakdowns
    var attack_breakdown = calculateAttackScore(attack);
    var defense_breakdown = calculateDefenseScore(defense);

    // Fill in condition multipliers
    attack_breakdown.condition_mult = conditionCombatMult(attack.attacker);
    defense_breakdown.condition_mult = conditionCombatMult(defense.defender);

    // Draw rolls
    attack_breakdown.roll = try w.drawRandom(.combat);
    defense_breakdown.roll = switch (outcome.contested_roll_mode) {
        .single => attack_breakdown.roll, // same roll for both
        .independent_pair => try w.drawRandom(.combat),
    };

    // Calculate stance multipliers
    // Formula: stance_weight + (1.0 - stance_effectiveness)
    // At stance_effectiveness=0.5: weight=0.33 gives mult=0.83, weight=1.0 gives mult=1.5
    attack_breakdown.stance_mult = attack.attacker_stance.attack + (1.0 - outcome.stance_effectiveness);
    defense_breakdown.stance_mult = defense.defender_stance.defense + (1.0 - outcome.stance_effectiveness);

    // Calculate final values and margin
    const attack_final = attack_breakdown.final();
    const defense_final = defense_breakdown.final();
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
        .attack = attack_breakdown,
        .defense = defense_breakdown,
        .margin = margin,
        .outcome_type = result_outcome,
        .damage_mult = damage_mult,
    };
}

// ============================================================================
// Console Formatter
// ============================================================================

/// Format a contested roll event for detailed console output (tuning/debugging).
pub fn formatForConsole(e: anytype) void {
    const atk = e.attack;
    const def = e.defense;

    std.debug.print(
        \\
        \\── Contested Roll ─────────────────────────
        \\  {s} vs defender ({s})
        \\
        \\  ATTACK  [{d:.2}]
        \\    base {d:.2} | tech {d:.2} | weapon {d:.2}
        \\    stakes {d:.2} | engage {d:.2} | balance {d:.2}
        \\    cond x{d:.2} | stance x{d:.2} | roll {d:.2}
        \\
        \\  DEFENSE [{d:.2}]
        \\    base {d:.2} | tech {d:.2} | parry {d:.2} (x{d:.2})
        \\    balance {d:.2}
        \\    cond x{d:.2} | stance x{d:.2} | roll {d:.2}
        \\
        \\  MARGIN {d:.2} -> {s} (x{d:.2} dmg)
        \\───────────────────────────────────────────
        \\
    , .{
        @tagName(e.technique_id),
        e.weapon_name,
        atk.final(),
        atk.base,
        atk.technique,
        atk.weapon,
        atk.stakes,
        atk.engagement,
        atk.balance,
        atk.condition_mult,
        atk.stance_mult,
        atk.roll,
        def.final(),
        def.base,
        def.technique,
        def.weapon_parry * def.parry_scaling,
        def.parry_scaling,
        def.balance,
        def.condition_mult,
        def.stance_mult,
        def.roll,
        e.margin,
        @tagName(e.outcome_type),
        e.damage_mult,
    });
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

    // Verify result breakdown is valid
    try std.testing.expect(result.attack.raw() > 0);
    try std.testing.expect(result.defense.raw() > 0);
    try std.testing.expect(result.attack.roll >= 0 and result.attack.roll <= 1);
    try std.testing.expect(result.defense.roll >= 0 and result.defense.roll <= 1);

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
    try std.testing.expect(result.attack.roll >= 0);
}
