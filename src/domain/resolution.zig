const std = @import("std");
const lib = @import("infra");
const combat = @import("combat.zig");
const cards = @import("cards.zig");
const weapon = @import("weapon.zig");
const damage = @import("damage.zig");
const armour = @import("armour.zig");
const body = @import("body.zig");
const entity = lib.entity;
const events = @import("events.zig");
const world = @import("world.zig");
const stats = @import("stats.zig");

const Agent = combat.Agent;
const Engagement = combat.Engagement;
const Technique = cards.Technique;
const TechniqueID = cards.TechniqueID;
const Stakes = cards.Stakes;
const World = world.World;
const Event = events.Event;

// ============================================================================
// Outcome Determination
// ============================================================================

pub const Outcome = enum {
    hit,
    miss,
    blocked,
    parried,
    deflected,
    dodged,
    countered,
};

pub const AttackContext = struct {
    attacker: *Agent,
    defender: *Agent,
    technique: *const Technique,
    weapon_template: *const weapon.Template,
    stakes: Stakes,
    engagement: *Engagement,
};

pub const DefenseContext = struct {
    defender: *Agent,
    technique: ?*const Technique, // null = passive defense
    weapon_template: *const weapon.Template,
};

/// Calculate hit probability for an attack
pub fn calculateHitChance(attack: AttackContext, defense: DefenseContext) f32 {
    var chance: f32 = 0.5; // Base 50%

    // Technique difficulty (higher = harder to land)
    chance -= attack.technique.difficulty * 0.1;

    // Weapon accuracy modifier
    if (getWeaponOffensive(attack.weapon_template, attack.technique)) |weapon_off| {
        chance += weapon_off.accuracy * 0.1;
    }

    // Stakes modifier
    chance += attack.stakes.hitChanceBonus();

    // Engagement advantage (pressure, control, position)
    const engagement_bonus = (attack.engagement.playerAdvantage() - 0.5) * 0.3;
    chance += if (attack.attacker.director == .player) engagement_bonus else -engagement_bonus;

    // Attacker balance
    chance += (attack.attacker.balance - 0.5) * 0.2;

    // Defense modifiers
    if (defense.technique) |def_tech| {
        // Active defense technique modifies attacker's chance
        const def_mult = switch (def_tech.id) {
            .parry => attack.technique.parry_mult,
            .block => attack.technique.deflect_mult, // using deflect as proxy for now
            .deflect => attack.technique.deflect_mult,
            else => 1.0,
        };
        chance *= def_mult;

        // Height coverage: if guard covers the attack's target zone
        if (def_tech.guard_height) |gh| {
            if (gh == attack.technique.target_height) {
                // Guard directly covers attack zone - significant penalty
                chance -= 0.15;
            } else if (def_tech.covers_adjacent and gh.adjacent(attack.technique.target_height)) {
                // Guard partially covers adjacent zone
                chance -= 0.08;
            } else {
                // Attacking an opening (unguarded zone) - slight bonus
                chance += 0.05;
            }
        }

        // Defender weapon defensive modifiers
        chance -= defense.weapon_template.defence.parry * 0.1;
    }

    // Defender balance (low balance = easier to hit)
    chance += (1.0 - defense.defender.balance) * 0.15;

    return std.math.clamp(chance, 0.05, 0.95);
}

/// Determine outcome of attack vs defense
pub fn resolveOutcome(
    w: *World,
    attack: AttackContext,
    defense: DefenseContext,
) !Outcome {
    const hit_chance = calculateHitChance(attack, defense);
    const roll = try w.drawRandom(.combat);

    if (roll > hit_chance) {
        // Attack failed - determine how based on defense
        if (defense.technique) |def_tech| {
            return switch (def_tech.id) {
                .parry => .parried,
                .block => .blocked,
                .deflect => .deflected,
                else => .miss,
            };
        }
        return .miss;
    }

    return .hit;
}

// ============================================================================
// Advantage Effects
// ============================================================================

pub const AdvantageEffect = combat.AdvantageEffect;
pub const TechniqueAdvantage = combat.TechniqueAdvantage;

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

/// Default advantage effects per outcome (used when technique has no override)
const default_advantage_effects = struct {
    const hit: AdvantageEffect = .{
        .pressure = 0.15,
        .control = 0.10,
        .target_balance = -0.15,
    };
    const miss: AdvantageEffect = .{
        .control = -0.15,
        .self_balance = -0.10,
    };
    const blocked: AdvantageEffect = .{
        .pressure = 0.05,
        .control = -0.05,
    };
    const parried: AdvantageEffect = .{
        .control = -0.20,
        .self_balance = -0.05,
    };
    const deflected: AdvantageEffect = .{
        .pressure = 0.05,
        .control = -0.10,
    };
    const dodged: AdvantageEffect = .{
        .control = -0.10,
        .self_balance = -0.05,
    };
    const countered: AdvantageEffect = .{
        .control = -0.25,
        .self_balance = -0.15,
    };
};

/// Default advantage effect for an outcome (when technique has no override)
fn defaultForOutcome(outcome: Outcome) AdvantageEffect {
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
fn techniqueOverrideForOutcome(adv: TechniqueAdvantage, outcome: Outcome) ?AdvantageEffect {
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
// Damage Packet Creation
// ============================================================================

fn getWeaponOffensive(
    weapon_template: *const weapon.Template,
    technique: *const Technique,
) ?*const weapon.Offensive {
    return switch (technique.attack_mode) {
        .thrust => if (weapon_template.thrust) |*t| t else null,
        .swing => if (weapon_template.swing) |*s| s else null,
        .ranged => null, // TODO: add ranged profile to weapon.Template
        .none => null, // defensive techniques don't use weapon offensive
    };
}

pub fn createDamagePacket(
    technique: *const Technique,
    weapon_template: *const weapon.Template,
    attacker: *Agent,
    stakes: Stakes,
) damage.Packet {
    // Get weapon offensive profile for this technique type
    const weapon_off = getWeaponOffensive(weapon_template, technique);

    // Base damage from technique instances
    var amount: f32 = 0;
    for (technique.damage.instances) |inst| {
        amount += inst.amount;
    }

    // Scale by attacker stats
    const stat_mult: f32 = switch (technique.damage.scaling.stats) {
        .stat => |accessor| attacker.stats.get(accessor),
        .average => |arr| blk: {
            const a = attacker.stats.get(arr[0]);
            const b = attacker.stats.get(arr[1]);
            break :blk (a + b) / 2.0;
        },
    };
    amount *= stat_mult * technique.damage.scaling.ratio;

    // Weapon damage modifier
    if (weapon_off) |off| {
        amount *= off.damage;
    }

    // Stakes modifier
    amount *= stakes.damageMultiplier();

    // Primary damage type from technique
    const kind: damage.Kind = if (technique.damage.instances.len > 0 and
        technique.damage.instances[0].types.len > 0)
        technique.damage.instances[0].types[0]
    else
        .bludgeon;

    // Penetration from weapon
    const penetration: f32 = if (weapon_off) |off|
        off.penetration + off.penetration_max * 0.5
    else
        1.0;

    return damage.Packet{
        .amount = amount,
        .kind = kind,
        .penetration = penetration,
    };
}

// ============================================================================
// Full Resolution
// ============================================================================

pub const ResolutionResult = struct {
    outcome: Outcome,
    advantage_applied: AdvantageEffect,
    damage_packet: ?damage.Packet,
    armour_result: ?armour.AbsorptionResult,
    body_result: ?body.Body.DamageResult,
};

/// Resolve a single technique against a defense, applying all effects
pub fn resolveTechniqueVsDefense(
    w: *World,
    attack: AttackContext,
    defense: DefenseContext,
    target_part: body.PartIndex,
) !ResolutionResult {
    // 1. Determine outcome (hit/miss/blocked/etc)
    const outcome = try resolveOutcome(w, attack, defense);

    // 2. Calculate and apply advantage effects (with events)
    const adv_effect = getAdvantageEffect(attack.technique, outcome, attack.stakes);
    try applyAdvantageWithEvents(adv_effect, w, attack.engagement, attack.attacker, attack.defender);

    // 3. If hit, create damage packet and resolve through armor/body
    var dmg_packet: ?damage.Packet = null;
    var armour_result: ?armour.AbsorptionResult = null;
    var body_result: ?body.Body.DamageResult = null;

    if (outcome == .hit) {
        dmg_packet = createDamagePacket(
            attack.technique,
            attack.weapon_template,
            attack.attacker,
            attack.stakes,
        );

        // Resolve through armor
        armour_result = try armour.resolveThroughArmourWithEvents(
            w,
            attack.defender.id,
            &attack.defender.armour,
            target_part,
            dmg_packet.?,
        );

        // Apply remaining damage to body (emits wound_inflicted, severed, etc.)
        if (armour_result.?.remaining.amount > 0) {
            body_result = try attack.defender.body.applyDamageWithEvents(
                &w.events,
                target_part,
                armour_result.?.remaining,
            );
        }
    }

    // Emit technique_resolved event
    try w.events.push(.{ .technique_resolved = .{
        .attacker_id = attack.attacker.id,
        .defender_id = attack.defender.id,
        .technique_id = attack.technique.id,
        .outcome = outcome,
    } });

    return ResolutionResult{
        .outcome = outcome,
        .advantage_applied = adv_effect,
        .damage_packet = dmg_packet,
        .armour_result = armour_result,
        .body_result = body_result,
    };
}

// ============================================================================
// Hit Location Selection
// ============================================================================

/// Height weighting multipliers for hit location selection
const height_weight = struct {
    const primary: f32 = 2.0; // target height
    const secondary: f32 = 1.0; // secondary height (if set)
    const adjacent: f32 = 0.5; // adjacent to target
    const off_target: f32 = 0.1; // opposite height
};

/// Calculate weight multiplier for exposure based on attack height
fn getHeightMultiplier(
    exp_height: body.Height,
    target_height: body.Height,
    secondary_height: ?body.Height,
) f32 {
    // Primary target
    if (exp_height == target_height) {
        return height_weight.primary;
    }

    // Secondary target (e.g., swing high→mid)
    if (secondary_height) |sec| {
        if (exp_height == sec) {
            return height_weight.secondary;
        }
    }

    // Adjacent height
    if (exp_height.adjacent(target_height)) {
        return height_weight.adjacent;
    }

    // Off-target (opposite height)
    return height_weight.off_target;
}

/// Select hit location from exposure table with height weighting
pub fn selectHitLocationFromExposures(
    exposures: []const body.Exposure,
    target_height: body.Height,
    secondary_height: ?body.Height,
    guard_height: ?body.Height,
    covers_adjacent: bool,
    roll: f32,
) ?usize {
    // Calculate weighted probabilities
    var total_weight: f32 = 0;
    var weights: [64]f32 = undefined; // max 64 exposures

    for (exposures, 0..) |exp, i| {
        var w = exp.base_chance;

        // Apply attack height targeting
        w *= getHeightMultiplier(exp.height, target_height, secondary_height);

        // Apply defense coverage (reduces exposure of guarded zone)
        if (guard_height) |gh| {
            if (exp.height == gh) {
                w *= 0.3; // guarded zone is hard to hit
            } else if (covers_adjacent and exp.height.adjacent(gh)) {
                w *= 0.6; // adjacent zone partially covered
            }
        }

        weights[i] = w;
        total_weight += w;
    }

    if (total_weight <= 0) return null;

    // Weighted random selection
    const target = roll * total_weight;
    var cumulative: f32 = 0;
    for (weights[0..exposures.len], 0..) |w, i| {
        cumulative += w;
        if (target <= cumulative) {
            return i;
        }
    }

    return exposures.len - 1; // fallback to last
}

/// Find body part index by tag and side
fn findPartIndex(parts: []const body.Part, tag: body.PartTag, side: body.Side) ?body.PartIndex {
    for (parts, 0..) |part, i| {
        if (part.tag == tag and part.side == side) {
            return @intCast(i);
        }
    }
    return null;
}

/// Select a target body part based on technique and defense
pub fn selectHitLocation(
    w: *World,
    defender: *Agent,
    technique: *const Technique,
    defense_technique: ?*const Technique,
) !body.PartIndex {
    const exposures = &body.humanoid_exposures; // TODO: get from defender's body type

    // Get defense guard position
    const guard_height: ?body.Height = if (defense_technique) |dt| dt.guard_height else null;
    const covers_adjacent: bool = if (defense_technique) |dt| dt.covers_adjacent else false;

    const roll = try w.drawRandom(.combat);

    // Select from exposure table
    if (selectHitLocationFromExposures(
        exposures,
        technique.target_height,
        technique.secondary_height,
        guard_height,
        covers_adjacent,
        roll,
    )) |exp_idx| {
        const exp = exposures[exp_idx];

        // Find the actual body part index
        if (findPartIndex(defender.body.parts.items, exp.tag, exp.side)) |part_idx| {
            return part_idx;
        }
    }

    // Fallback to torso (should always exist)
    return findPartIndex(defender.body.parts.items, .torso, .center) orelse 0;
}

// ============================================================================
// Tests
// ============================================================================

test "calculateHitChance base case" {
    // Would need mock agents/engagement - placeholder for now
}

test "getAdvantageEffect scales by stakes" {
    const technique = &cards.Technique.byID(.swing);
    const base_hit = getAdvantageEffect(technique, .hit, .guarded);
    const reckless_hit = getAdvantageEffect(technique, .hit, .reckless);

    // Reckless should have higher pressure gain
    try std.testing.expect(reckless_hit.pressure > base_hit.pressure);
}

test "getAdvantageEffect miss penalty scales with stakes" {
    const technique = &cards.Technique.byID(.swing);
    const guarded_miss = getAdvantageEffect(technique, .miss, .guarded);
    const reckless_miss = getAdvantageEffect(technique, .miss, .reckless);

    // Reckless miss should have bigger balance penalty
    try std.testing.expect(reckless_miss.self_balance < guarded_miss.self_balance);
}

test "getAdvantageEffect uses technique override when present" {
    // Technique with custom on_hit advantage
    const custom_technique = Technique{
        .id = .feint, // use feint as test case
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
    const default_technique = &cards.Technique.byID(.swing);
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
        .id = .feint,
        .name = "partial_feint",
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
        .id = .feint,
        .name = "scaled_feint",
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

// ============================================================================
// Integration Test Fixtures
// ============================================================================

const weapon_list = @import("weapon_list.zig");

fn makeTestWorld(alloc: std.mem.Allocator) !*World {
    return World.init(alloc);
}

fn makeTestAgent(
    alloc: std.mem.Allocator,
    agents: *@import("slot_map.zig").SlotMap(*Agent),
    director: @import("combat.zig").Director,
) !*Agent {
    const deck_mod = @import("deck.zig");
    const card_list = @import("card_list.zig");

    const agent_deck = try deck_mod.Deck.init(alloc, &card_list.BeginnerDeck);
    const agent_stats = stats.Block.splat(5);
    const agent_body = try body.Body.fromPlan(alloc, &body.HumanoidPlan);

    const agent = try Agent.init(
        alloc,
        agents,
        director,
        combat.Strat{ .deck = agent_deck },
        agent_stats,
        agent_body,
        10.0,
        undefined, // armament is annoying to make
    );

    return agent;
}

test "resolveTechniqueVsDefense emits technique_resolved event" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    // Create attacker (player) and defender (mob)
    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, .ai);
    // Note: defender is cleaned up by w.deinit() since it's in w.agents

    // Set up engagement on defender
    defender.engagement = Engagement{};
    const engagement = &defender.engagement.?;

    // Get thrust technique
    const technique = &cards.Technique.byID(.thrust);

    // Create attack and defense contexts
    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null, // passive defense
        .weapon_template = &weapon_list.knights_sword,
    };

    // Get a target body part
    const target_part: body.PartIndex = 0; // torso

    // Resolve the technique
    const result = try resolveTechniqueVsDefense(w, attack, defense, target_part);

    // Swap buffers to make events readable
    w.events.swap_buffers();

    // Check that technique_resolved event was emitted
    var found_technique_resolved = false;
    while (w.events.pop()) |event| {
        switch (event) {
            .technique_resolved => |data| {
                try std.testing.expectEqual(attacker.id, data.attacker_id);
                try std.testing.expectEqual(defender.id, data.defender_id);
                try std.testing.expectEqual(cards.TechniqueID.thrust, data.technique_id);
                try std.testing.expectEqual(result.outcome, data.outcome);
                found_technique_resolved = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found_technique_resolved);
}

test "resolveTechniqueVsDefense emits advantage_changed events on hit" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, .ai);
    // Note: defender is cleaned up by w.deinit() since it's in w.agents

    defender.engagement = Engagement{};
    const engagement = &defender.engagement.?;

    const technique = &cards.Technique.byID(.swing);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .committed, // higher stakes = bigger advantage swings
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
    };

    const target_part: body.PartIndex = 0;

    // Force a hit by setting defender balance very low
    defender.balance = 0.1;

    const result = try resolveTechniqueVsDefense(w, attack, defense, target_part);

    w.events.swap_buffers();

    // Count advantage_changed events
    var advantage_events: u32 = 0;
    var found_balance_event = false;

    while (w.events.pop()) |event| {
        switch (event) {
            .advantage_changed => |data| {
                advantage_events += 1;
                if (data.axis == .balance) {
                    found_balance_event = true;
                    // Balance changes should have engagement_with = null (intrinsic)
                    try std.testing.expectEqual(@as(?entity.ID, null), data.engagement_with);
                }
            },
            else => {},
        }
    }

    // Hit or miss, we should get advantage events based on outcome
    if (result.outcome == .hit) {
        // Hit should change pressure, control, and target_balance
        try std.testing.expect(advantage_events >= 2);
    } else {
        // Miss should change control and self_balance
        try std.testing.expect(advantage_events >= 1);
    }
}

test "resolveTechniqueVsDefense applies damage on hit" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, .ai);
    // Note: defender is cleaned up by w.deinit() since it's in w.agents

    defender.engagement = Engagement{};
    const engagement = &defender.engagement.?;

    const technique = &cards.Technique.byID(.thrust);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .reckless, // maximum damage
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
    };

    const target_part: body.PartIndex = 0;

    // Stack odds for a hit
    defender.balance = 0.0;
    engagement.pressure = 0.9; // player advantage
    engagement.control = 0.9;
    engagement.position = 0.9;

    const result = try resolveTechniqueVsDefense(w, attack, defense, target_part);

    if (result.outcome == .hit) {
        // Should have created a damage packet
        try std.testing.expect(result.damage_packet != null);

        const packet = result.damage_packet.?;
        try std.testing.expect(packet.amount > 0);
        try std.testing.expectEqual(damage.Kind.pierce, packet.kind);

        // Reckless stakes should give 2x damage multiplier
        // Base damage is technique.damage * stat_mult * weapon_mult * stakes_mult
    }
}

test "AdvantageEffect.apply modifies engagement and balance" {
    var engagement = Engagement{
        .pressure = 0.5,
        .control = 0.5,
        .position = 0.5,
    };

    const alloc = std.testing.allocator;
    const agents = try alloc.create(@import("slot_map.zig").SlotMap(*Agent));
    agents.* = try @import("slot_map.zig").SlotMap(*Agent).init(alloc);
    defer {
        agents.deinit();
        alloc.destroy(agents);
    }

    var attacker = try makeTestAgent(alloc, agents, .player);
    defer attacker.deinit();

    var defender = try makeTestAgent(alloc, agents, .ai);
    defer defender.deinit();

    attacker.balance = 1.0;
    defender.balance = 1.0;

    const effect = AdvantageEffect{
        .pressure = 0.1,
        .control = -0.1,
        .position = 0.05,
        .self_balance = -0.1,
        .target_balance = -0.2,
    };

    effect.apply(&engagement, attacker, defender);

    try std.testing.expectApproxEqAbs(@as(f32, 0.6), engagement.pressure, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), engagement.control, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), engagement.position, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), attacker.balance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), defender.balance, 0.001);
}

test "createDamagePacket scales by stakes" {
    const alloc = std.testing.allocator;
    const agents = try alloc.create(@import("slot_map.zig").SlotMap(*Agent));
    agents.* = try @import("slot_map.zig").SlotMap(*Agent).init(alloc);
    defer {
        agents.deinit();
        alloc.destroy(agents);
    }

    var attacker = try makeTestAgent(alloc, agents, .player);
    defer attacker.deinit();

    const technique = &cards.Technique.byID(.swing);

    const probing = createDamagePacket(technique, &weapon_list.knights_sword, attacker, .probing);
    const guarded = createDamagePacket(technique, &weapon_list.knights_sword, attacker, .guarded);
    const committed = createDamagePacket(technique, &weapon_list.knights_sword, attacker, .committed);
    const reckless = createDamagePacket(technique, &weapon_list.knights_sword, attacker, .reckless);

    // Damage should increase with stakes
    try std.testing.expect(probing.amount < guarded.amount);
    try std.testing.expect(guarded.amount < committed.amount);
    try std.testing.expect(committed.amount < reckless.amount);

    // Reckless should be 2x guarded (from stakes multiplier)
    try std.testing.expectApproxEqAbs(guarded.amount * 2.0, reckless.amount, 0.01);
}

// ============================================================================
// Hit Location Selection Tests
// ============================================================================

test "Height.adjacent returns true for mid to any, false for low/high" {
    try std.testing.expect(body.Height.low.adjacent(.mid));
    try std.testing.expect(body.Height.high.adjacent(.mid));
    try std.testing.expect(body.Height.mid.adjacent(.low));
    try std.testing.expect(body.Height.mid.adjacent(.high));

    // Low and high are not adjacent
    try std.testing.expect(!body.Height.low.adjacent(.high));
    try std.testing.expect(!body.Height.high.adjacent(.low));
}

test "getHeightMultiplier returns correct weights" {
    // Primary target
    try std.testing.expectApproxEqAbs(
        height_weight.primary,
        getHeightMultiplier(.mid, .mid, null),
        0.001,
    );

    // Secondary target
    try std.testing.expectApproxEqAbs(
        height_weight.secondary,
        getHeightMultiplier(.mid, .high, .mid),
        0.001,
    );

    // Adjacent to primary
    try std.testing.expectApproxEqAbs(
        height_weight.adjacent,
        getHeightMultiplier(.mid, .high, null),
        0.001,
    );

    // Off-target (low when targeting high, no secondary)
    try std.testing.expectApproxEqAbs(
        height_weight.off_target,
        getHeightMultiplier(.low, .high, null),
        0.001,
    );
}

test "selectHitLocationFromExposures favors target height" {
    // Simple test exposures: one per height zone
    const test_exposures = [_]body.Exposure{
        .{ .tag = .head, .side = .center, .base_chance = 0.33, .height = .high },
        .{ .tag = .torso, .side = .center, .base_chance = 0.34, .height = .mid },
        .{ .tag = .thigh, .side = .left, .base_chance = 0.33, .height = .low },
    };

    // With roll = 0.0, should always pick first weighted option
    // Targeting mid: mid gets 2x weight, others get less
    // Weights: high=0.33*0.5=0.165, mid=0.34*2.0=0.68, low=0.33*0.1=0.033
    // Total = 0.878, cumulative at mid = 0.165 + 0.68 = 0.845

    // Roll = 0.0 * total should give first entry (high)
    const result_low_roll = selectHitLocationFromExposures(
        &test_exposures,
        .mid, // target
        null, // no secondary
        null, // no guard
        false,
        0.0,
    );
    try std.testing.expectEqual(@as(?usize, 0), result_low_roll); // head (first)

    // Roll = 0.5 should land in mid range
    const result_mid_roll = selectHitLocationFromExposures(
        &test_exposures,
        .mid,
        null,
        null,
        false,
        0.5,
    );
    try std.testing.expectEqual(@as(?usize, 1), result_mid_roll); // torso

    // Roll = 0.99 should land in low range
    const result_high_roll = selectHitLocationFromExposures(
        &test_exposures,
        .mid,
        null,
        null,
        false,
        0.99,
    );
    try std.testing.expectEqual(@as(?usize, 2), result_high_roll); // thigh
}

test "selectHitLocationFromExposures defense coverage reduces hit chance" {
    const test_exposures = [_]body.Exposure{
        .{ .tag = .head, .side = .center, .base_chance = 0.5, .height = .high },
        .{ .tag = .thigh, .side = .left, .base_chance = 0.5, .height = .low },
    };

    // Attack high, guard high - high zone heavily reduced
    // Without guard: high=0.5*2.0=1.0, low=0.5*0.1=0.05
    // With guard: high=0.5*2.0*0.3=0.3, low=0.5*0.1=0.05
    // Total without = 1.05, with = 0.35

    // Roll 0.5 without guard should hit head (high)
    const no_guard = selectHitLocationFromExposures(
        &test_exposures,
        .high,
        null,
        null, // no guard
        false,
        0.5,
    );
    try std.testing.expectEqual(@as(?usize, 0), no_guard); // head

    // Roll 0.99 with high guard should more likely hit low
    const with_guard = selectHitLocationFromExposures(
        &test_exposures,
        .high,
        null,
        .high, // guard matches attack
        false,
        0.95,
    );
    try std.testing.expectEqual(@as(?usize, 1), with_guard); // thigh
}

test "selectHitLocationFromExposures secondary height gets normal weight" {
    const test_exposures = [_]body.Exposure{
        .{ .tag = .head, .side = .center, .base_chance = 0.33, .height = .high },
        .{ .tag = .torso, .side = .center, .base_chance = 0.34, .height = .mid },
        .{ .tag = .thigh, .side = .left, .base_chance = 0.33, .height = .low },
    };

    // Attack high with secondary mid (like a swing)
    // high = 0.33 * 2.0 = 0.66 (primary)
    // mid = 0.34 * 1.0 = 0.34 (secondary)
    // low = 0.33 * 0.1 = 0.033 (off-target)
    // Total = 1.033

    // Mid zone should have significant weight (not the 0.5x of adjacent)
    const result = selectHitLocationFromExposures(
        &test_exposures,
        .high, // primary
        .mid, // secondary
        null,
        false,
        0.7, // should land in mid
    );
    try std.testing.expectEqual(@as(?usize, 1), result); // torso
}
