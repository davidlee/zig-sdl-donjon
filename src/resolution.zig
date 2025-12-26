const std = @import("std");
const combat = @import("combat.zig");
const cards = @import("cards.zig");
const weapon = @import("weapon.zig");
const damage = @import("damage.zig");
const armour = @import("armour.zig");
const body = @import("body.zig");
const entity = @import("entity.zig");
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
    if (getWeaponOffensive(attack.weapon_template, attack.technique.id)) |weapon_off| {
        chance += weapon_off.accuracy * 0.1;
    }

    // Stakes modifier
    chance += switch (attack.stakes) {
        .probing => -0.1,
        .guarded => 0.0,
        .committed => 0.1,
        .reckless => 0.2,
    };

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

pub const AdvantageEffect = struct {
    pressure: f32 = 0,
    control: f32 = 0,
    position: f32 = 0,
    self_balance: f32 = 0,
    target_balance: f32 = 0,

    pub fn apply(
        self: AdvantageEffect,
        engagement: *Engagement,
        attacker: *Agent,
        defender: *Agent,
    ) void {
        engagement.pressure = std.math.clamp(engagement.pressure + self.pressure, 0, 1);
        engagement.control = std.math.clamp(engagement.control + self.control, 0, 1);
        engagement.position = std.math.clamp(engagement.position + self.position, 0, 1);
        attacker.balance = std.math.clamp(attacker.balance + self.self_balance, 0, 1);
        defender.balance = std.math.clamp(defender.balance + self.target_balance, 0, 1);
    }

    pub fn scale(self: AdvantageEffect, mult: f32) AdvantageEffect {
        return .{
            .pressure = self.pressure * mult,
            .control = self.control * mult,
            .position = self.position * mult,
            .self_balance = self.self_balance * mult,
            .target_balance = self.target_balance * mult,
        };
    }

    /// Apply advantage effects and emit events for any changes
    pub fn applyWithEvents(
        self: AdvantageEffect,
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
        self.apply(engagement, attacker, defender);

        // Emit events for changed values
        // Engagement changes are relative to defender (engagement stored on mob)
        if (self.pressure != 0) {
            try w.events.push(.{ .advantage_changed = .{
                .agent_id = defender.id,
                .engagement_with = attacker.id,
                .axis = .pressure,
                .old_value = old_pressure,
                .new_value = engagement.pressure,
            } });
        }
        if (self.control != 0) {
            try w.events.push(.{ .advantage_changed = .{
                .agent_id = defender.id,
                .engagement_with = attacker.id,
                .axis = .control,
                .old_value = old_control,
                .new_value = engagement.control,
            } });
        }
        if (self.position != 0) {
            try w.events.push(.{ .advantage_changed = .{
                .agent_id = defender.id,
                .engagement_with = attacker.id,
                .axis = .position,
                .old_value = old_position,
                .new_value = engagement.position,
            } });
        }
        // Balance is intrinsic (engagement_with = null)
        if (self.self_balance != 0) {
            try w.events.push(.{ .advantage_changed = .{
                .agent_id = attacker.id,
                .engagement_with = null,
                .axis = .balance,
                .old_value = old_attacker_balance,
                .new_value = attacker.balance,
            } });
        }
        if (self.target_balance != 0) {
            try w.events.push(.{ .advantage_changed = .{
                .agent_id = defender.id,
                .engagement_with = null,
                .axis = .balance,
                .old_value = old_defender_balance,
                .new_value = defender.balance,
            } });
        }
    }
};

/// Get advantage effect for a technique outcome
pub fn getAdvantageEffect(outcome: Outcome, stakes: Stakes) AdvantageEffect {
    const base: AdvantageEffect = switch (outcome) {
        .hit => .{
            .pressure = 0.15,
            .control = 0.10,
            .target_balance = -0.15,
        },
        .miss => .{
            .control = -0.15,
            .self_balance = -0.10,
        },
        .blocked => .{
            .pressure = 0.05,
            .control = -0.05,
        },
        .parried => .{
            .control = -0.20,
            .self_balance = -0.05,
        },
        .deflected => .{
            .pressure = 0.05,
            .control = -0.10,
        },
        .dodged => .{
            .control = -0.10,
            .self_balance = -0.05,
        },
        .countered => .{
            .control = -0.25,
            .self_balance = -0.15,
        },
    };

    // Scale by stakes - higher stakes = bigger swings
    const is_success = (outcome == .hit);
    const mult: f32 = switch (stakes) {
        .probing => 0.5,
        .guarded => 1.0,
        .committed => if (is_success) 1.25 else 1.5,
        .reckless => if (is_success) 1.5 else 2.0,
    };

    return base.scale(mult);
}

// ============================================================================
// Damage Packet Creation
// ============================================================================

fn getWeaponOffensive(
    weapon_template: *const weapon.Template,
    technique_id: TechniqueID,
) ?*const weapon.Offensive {
    return switch (technique_id) {
        .thrust => if (weapon_template.thrust) |*t| t else null,
        .swing => if (weapon_template.swing) |*s| s else null,
        else => if (weapon_template.swing) |*s| s else null,
    };
}

pub fn createDamagePacket(
    technique: *const Technique,
    weapon_template: *const weapon.Template,
    attacker: *Agent,
    stakes: Stakes,
) damage.Packet {
    // Get weapon offensive profile for this technique type
    const weapon_off = getWeaponOffensive(weapon_template, technique.id);

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
    amount *= switch (stakes) {
        .probing => 0.4,
        .guarded => 1.0,
        .committed => 1.4,
        .reckless => 2.0,
    };

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
    const adv_effect = getAdvantageEffect(outcome, attack.stakes);
    try adv_effect.applyWithEvents(w, attack.engagement, attack.attacker, attack.defender);

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

        // Apply remaining damage to body (body emits its own events for wounds/severing)
        if (armour_result.?.remaining.amount > 0) {
            body_result = try attack.defender.body.applyDamageToPart(
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

/// Select a target body part based on technique and engagement state
pub fn selectHitLocation(
    w: *World,
    defender: *Agent,
    technique: *const Technique,
    engagement: *const Engagement,
) !body.PartIndex {
    _ = technique; // TODO: weight by technique (thrust -> torso/head)
    _ = engagement; // TODO: weight by position (flanking -> back)

    // For now, simple random selection weighted by base_hit_chance
    const parts = defender.body.parts.items;
    var total_weight: f32 = 0;
    for (parts) |part| {
        total_weight += part.base_hit_chance;
    }

    const roll = try w.drawRandom(.combat) * total_weight;
    var cumulative: f32 = 0;
    for (parts, 0..) |part, i| {
        cumulative += part.base_hit_chance;
        if (roll <= cumulative) {
            return @intCast(i);
        }
    }

    // Fallback to first part (torso typically)
    return 0;
}

// ============================================================================
// Tests
// ============================================================================

test "calculateHitChance base case" {
    // Would need mock agents/engagement - placeholder for now
}

test "getAdvantageEffect scales by stakes" {
    const base_hit = getAdvantageEffect(.hit, .guarded);
    const reckless_hit = getAdvantageEffect(.hit, .reckless);

    // Reckless should have higher pressure gain
    try std.testing.expect(reckless_hit.pressure > base_hit.pressure);
}

test "getAdvantageEffect miss penalty scales with stakes" {
    const guarded_miss = getAdvantageEffect(.miss, .guarded);
    const reckless_miss = getAdvantageEffect(.miss, .reckless);

    // Reckless miss should have bigger balance penalty
    try std.testing.expect(reckless_miss.self_balance < guarded_miss.self_balance);
}

// ============================================================================
// Integration Test Fixtures
// ============================================================================

const TestWeapons = struct {
    pub const sword_swing = weapon.Offensive{
        .name = "sword swing",
        .reach = .longsword,
        .damage_types = &.{.slash},
        .accuracy = 1.0,
        .speed = 1.0,
        .damage = 1.0,
        .penetration = 0.5,
        .penetration_max = 2.0,
        .fragility = 0.1,
        .defender_modifiers = .{
            .name = "",
            .reach = .longsword,
            .parry = 0.8,
            .deflect = 0.6,
            .block = 0.4,
            .fragility = 0.1,
        },
    };

    pub const sword_thrust = weapon.Offensive{
        .name = "sword thrust",
        .reach = .longsword,
        .damage_types = &.{.pierce},
        .accuracy = 0.9,
        .speed = 1.2,
        .damage = 0.8,
        .penetration = 1.0,
        .penetration_max = 4.0,
        .fragility = 0.1,
        .defender_modifiers = .{
            .name = "",
            .reach = .longsword,
            .parry = 1.0,
            .deflect = 0.8,
            .block = 0.5,
            .fragility = 0.1,
        },
    };

    pub const sword_defence = weapon.Defensive{
        .name = "sword defence",
        .reach = .longsword,
        .parry = 1.0,
        .deflect = 0.8,
        .block = 0.3,
        .fragility = 0.1,
    };

    pub const sword = weapon.Template{
        .name = "longsword",
        .categories = &.{.sword},
        .features = .{
            .hooked = false,
            .spiked = false,
            .crossguard = true,
            .pommel = true,
        },
        .grip = .{
            .one_handed = true,
            .two_handed = true,
            .versatile = false,
            .bastard = true,
            .half_sword = true,
            .murder_stroke = true,
        },
        .length = 100.0,
        .weight = 1.5,
        .balance = 0.3,
        .swing = sword_swing,
        .thrust = sword_thrust,
        .defence = sword_defence,
        .ranged = null,
        .integrity = 100.0,
    };
};

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
    const defender = try makeTestAgent(alloc, w.agents, .ai);
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
        .weapon_template = &TestWeapons.sword,
        .stakes = .guarded,
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null, // passive defense
        .weapon_template = &TestWeapons.sword,
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
    const defender = try makeTestAgent(alloc, w.agents, .ai);
    // Note: defender is cleaned up by w.deinit() since it's in w.agents

    defender.engagement = Engagement{};
    const engagement = &defender.engagement.?;

    const technique = &cards.Technique.byID(.swing);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &TestWeapons.sword,
        .stakes = .committed, // higher stakes = bigger advantage swings
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &TestWeapons.sword,
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
    const defender = try makeTestAgent(alloc, w.agents, .ai);
    // Note: defender is cleaned up by w.deinit() since it's in w.agents

    defender.engagement = Engagement{};
    const engagement = &defender.engagement.?;

    const technique = &cards.Technique.byID(.thrust);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &TestWeapons.sword,
        .stakes = .reckless, // maximum damage
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &TestWeapons.sword,
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

    const probing = createDamagePacket(technique, &TestWeapons.sword, attacker, .probing);
    const guarded = createDamagePacket(technique, &TestWeapons.sword, attacker, .guarded);
    const committed = createDamagePacket(technique, &TestWeapons.sword, attacker, .committed);
    const reckless = createDamagePacket(technique, &TestWeapons.sword, attacker, .reckless);

    // Damage should increase with stakes
    try std.testing.expect(probing.amount < guarded.amount);
    try std.testing.expect(guarded.amount < committed.amount);
    try std.testing.expect(committed.amount < reckless.amount);

    // Reckless should be 2x guarded (from stakes multiplier)
    try std.testing.expectApproxEqAbs(guarded.amount * 2.0, reckless.amount, 0.01);
}
