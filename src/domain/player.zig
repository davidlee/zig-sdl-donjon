/// Player bootstrap helpers.
///
/// Provides utilities to construct the default player agent and equipment.
/// Does not contain gameplay loop logic.
const std = @import("std");
const stats = @import("stats.zig");
const body = @import("body.zig");
const combat = @import("combat.zig");
const weapon = @import("weapon.zig");
const weapon_list = @import("weapon_list.zig");

const World = @import("world.zig").World;

pub fn newPlayer(
    alloc: std.mem.Allocator,
    world: *World,
    sb: stats.Block,
    bd: body.Body,
) !*combat.Agent {
    var weapn = try alloc.create(weapon.Instance);
    weapn.template = weapon_list.byName("falchion");
    weapn.id = try world.entities.weapons.insert(weapn);

    return combat.Agent.init(
        alloc,
        world.entities.agents,
        .player,
        .shuffled_deck,
        sb,
        bd,
        stats.Resource.init(12.0, 12.0, 4.0), // stamina
        stats.Resource.init(3.0, 5.0, 3.0), // focus
        stats.Resource.init(5.0, 5.0, 0.0), // blood
        combat.Armament{ .equipped = .{ .single = weapn }, .natural = &.{} },
    );
}
