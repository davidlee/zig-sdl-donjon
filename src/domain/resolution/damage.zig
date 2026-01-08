/// Helpers for translating techniques into damage packets.
///
/// Figures out weapon offensive profiles and assembles `damage.Packet`
/// instances consumed by the outcome resolver.
const std = @import("std");
const combat = @import("../combat.zig");
const cards = @import("../cards.zig");
const weapon = @import("../weapon.zig");
const damage = @import("../damage.zig");

const Agent = combat.Agent;
const Technique = cards.Technique;
const Stakes = cards.Stakes;

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
// Tests
// ============================================================================

const weapon_list = @import("../weapon_list.zig");
const stats = @import("../stats.zig");
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

    // Reckless should be 2x guarded (from stakes multiplier)
    try std.testing.expectApproxEqAbs(guarded.amount * 2.0, reckless.amount, 0.01);
}
