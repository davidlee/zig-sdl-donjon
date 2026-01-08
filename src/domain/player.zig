/// Player bootstrap helpers.
///
/// Provides utilities to construct the default player agent and equipment.
/// Does not contain gameplay loop logic.
const std = @import("std");
const stats = @import("stats.zig");
const combat = @import("combat.zig");
const species = @import("species.zig");
const weapon = @import("weapon.zig");
const weapon_list = @import("weapon_list.zig");

const World = @import("world.zig").World;

pub fn newPlayer(
    alloc: std.mem.Allocator,
    world: *World,
    sp: *const species.Species,
    sb: stats.Block,
) !*combat.Agent {
    // Create agent (body, resources, natural weapons derived from species)
    const agent = try combat.Agent.init(
        alloc,
        world.entities.agents,
        .player,
        .shuffled_deck,
        sp,
        sb,
    );

    // Equip starting weapon
    var weapn = try alloc.create(weapon.Instance);
    weapn.template = weapon_list.byName("fist stone");
    weapn.id = try world.entities.weapons.insert(weapn);
    agent.weapons = agent.weapons.withEquipped(.{ .single = weapn });

    return agent;
}
