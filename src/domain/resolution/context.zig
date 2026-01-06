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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const ai = @import("../ai.zig");
const stats = @import("../stats.zig");
const body = @import("../body.zig");
const slot_map = @import("../slot_map.zig");
const card_list = @import("../card_list.zig");

fn makeTestWorld(alloc: std.mem.Allocator) !*World {
    return World.init(alloc);
}

fn makeTestAgent(
    alloc: std.mem.Allocator,
    agents: *slot_map.SlotMap(*Agent),
    director: combat.Director,
) !*Agent {
    const agent_stats = stats.Block.splat(5);
    const agent_body = try body.Body.fromPlan(alloc, &body.HumanoidPlan);

    return Agent.init(
        alloc,
        agents,
        director,
        .shuffled_deck,
        agent_stats,
        agent_body,
        stats.Resource.init(10.0, 10.0, 2.0),
        stats.Resource.init(3.0, 5.0, 3.0),
        undefined,
    );
}

fn findCardByName(w: *World, name: []const u8) ?entity.ID {
    for (w.player.always_available.items) |card_id| {
        const card = w.card_registry.getConst(card_id) orelse continue;
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
        &w.card_registry,
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
        &w.card_registry,
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
        &w.card_registry,
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
        &w.card_registry,
    );
    // Note: advance takes 0.3s, sidestep would start at 0.3 due to channel conflict
    // For this test, we'll check over the full timeline
    try enc_state.current.addPlay(
        .{ .action = sidestep_id, .target = null },
        &w.card_registry,
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

    // Create defense context with is_stationary = true
    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        .is_stationary = true,
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

    // Create defense context with is_stationary = false
    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &@import("../weapon_list.zig").knights_sword,
        .is_stationary = false,
    };

    const mods = CombatModifiers.forDefender(defense);

    // No stationary penalty
    try testing.expectEqual(@as(f32, 0), mods.dodge_mod);
}
