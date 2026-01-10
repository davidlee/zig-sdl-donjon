/// Helpers for translating techniques into damage packets.
///
/// Figures out weapon offensive profiles and assembles `damage.Packet`
/// instances consumed by the outcome resolver.
const std = @import("std");
const combat = @import("../combat.zig");
const cards = @import("../cards.zig");
const weapon = @import("../weapon.zig");
const damage = @import("../damage.zig");
const stats = @import("../stats.zig");

const Agent = combat.Agent;
const Technique = cards.Technique;
const Stakes = cards.Stakes;

// ============================================================================
// 3-Axis Derivation Helpers (T037)
// ============================================================================

/// Compute kinetic energy from weapon reference energy, scaled by attacker stats and stakes.
/// Formula: energy = reference_energy_j × scalingMultiplier(stat_value, ratio) × stakes.damageMultiplier()
fn deriveEnergy(
    weapon_template: *const weapon.Template,
    technique: *const Technique,
    stat_value: f32,
    stat_ratio: f32,
    stakes: Stakes,
) f32 {
    const stat_mult = stats.scalingMultiplier(stat_value, stat_ratio);
    const stakes_mult = stakes.damageMultiplier();
    return weapon_template.reference_energy_j * stat_mult * stakes_mult * technique.axis_energy_mult;
}

/// Compute geometry coefficient from weapon geometry and technique bias.
/// Formula: geometry = weapon.geometry_coeff × technique.axis_geometry_mult
fn deriveGeometry(
    weapon_template: *const weapon.Template,
    technique: *const Technique,
) f32 {
    return weapon_template.geometry_coeff * technique.axis_geometry_mult;
}

/// Compute rigidity coefficient from weapon rigidity and technique bias.
/// Formula: rigidity = weapon.rigidity_coeff × technique.axis_rigidity_mult
fn deriveRigidity(
    weapon_template: *const weapon.Template,
    technique: *const Technique,
) f32 {
    return weapon_template.rigidity_coeff * technique.axis_rigidity_mult;
}

// ============================================================================
// Damage Packet Creation
// ============================================================================

pub fn getWeaponOffensive(
    weapon_template: *const weapon.Template,
    technique: *const Technique,
) ?*const weapon.Offensive {
    return switch (technique.attack_mode) {
        .thrust => if (weapon_template.thrust) |*t| t else null,
        .swing => if (weapon_template.swing) |*s| s else null,
        .ranged => if (weapon_template.ranged) |r| switch (r) {
            .thrown => |*t| &t.throw,
            .projectile => null, // TODO: projectile weapons (bows, crossbows)
        } else null,
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

    // Scale by attacker stats (additive bonus from baseline)
    const stat_value: f32 = switch (technique.damage.scaling.stats) {
        .stat => |accessor| attacker.stats.get(accessor),
        .average => |arr| blk: {
            const a = attacker.stats.get(arr[0]);
            const b = attacker.stats.get(arr[1]);
            break :blk (a + b) / 2.0;
        },
    };
    amount *= stats.scalingMultiplier(stat_value, technique.damage.scaling.ratio);

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

    // 3-axis values: only compute for physical damage
    const is_physical = kind.isPhysical();
    const geometry = if (is_physical) deriveGeometry(weapon_template, technique) else 0;
    const energy = if (is_physical) deriveEnergy(weapon_template, technique, stat_value, technique.damage.scaling.ratio, stakes) else 0;
    const rigidity = if (is_physical) deriveRigidity(weapon_template, technique) else 0;

    return damage.Packet{
        .amount = amount,
        .kind = kind,
        .penetration = penetration,
        .geometry = geometry,
        .energy = energy,
        .rigidity = rigidity,
    };
}

// ============================================================================
// Tests
// ============================================================================

const weapon_list = @import("../weapon_list.zig");
const species = @import("../species.zig");
const slot_map = @import("../slot_map.zig");

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

test "createDamagePacket scales by stakes" {
    const alloc = std.testing.allocator;
    const agents = try alloc.create(slot_map.SlotMap(*Agent));
    agents.* = try slot_map.SlotMap(*Agent).init(alloc);
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

    // Reckless should be 1.2x guarded (compressed damage range)
    try std.testing.expectApproxEqAbs(guarded.amount * 1.2, reckless.amount, 0.01);
}

test "createDamagePacket populates 3-axis fields for physical damage" {
    const alloc = std.testing.allocator;
    const agents = try alloc.create(slot_map.SlotMap(*Agent));
    agents.* = try slot_map.SlotMap(*Agent).init(alloc);
    defer {
        agents.deinit();
        alloc.destroy(agents);
    }

    var attacker = try makeTestAgent(alloc, agents, .player);
    defer attacker.deinit();

    const technique = &cards.Technique.byID(.swing);
    const packet = createDamagePacket(technique, &weapon_list.knights_sword, attacker, .guarded);

    // Physical damage should have non-zero axes
    try std.testing.expect(packet.isPhysical());
    try std.testing.expect(packet.geometry > 0);
    try std.testing.expect(packet.energy > 0);
    try std.testing.expect(packet.rigidity > 0);

    // Geometry and rigidity come from weapon coefficients × technique multipliers
    // Knight's sword has geometry_coeff=0.6, rigidity_coeff=0.7
    // Swing technique has axis_*_mult=1.0 (default)
    try std.testing.expectApproxEqAbs(0.6, packet.geometry, 0.01);
    try std.testing.expectApproxEqAbs(0.7, packet.rigidity, 0.01);

    // Energy scales with reference_energy × stat_mult × stakes
    // Knight's sword has reference_energy_j=10.7
    try std.testing.expect(packet.energy > 0);
    try std.testing.expect(packet.energy < 100); // sanity check
}

test "createDamagePacket axis energy scales with stakes" {
    const alloc = std.testing.allocator;
    const agents = try alloc.create(slot_map.SlotMap(*Agent));
    agents.* = try slot_map.SlotMap(*Agent).init(alloc);
    defer {
        agents.deinit();
        alloc.destroy(agents);
    }

    var attacker = try makeTestAgent(alloc, agents, .player);
    defer attacker.deinit();

    const technique = &cards.Technique.byID(.thrust);

    const probing = createDamagePacket(technique, &weapon_list.knights_sword, attacker, .probing);
    const reckless = createDamagePacket(technique, &weapon_list.knights_sword, attacker, .reckless);

    // Energy should increase with stakes (same as amount)
    try std.testing.expect(probing.energy < reckless.energy);
}
