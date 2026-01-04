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
    var buckler = try alloc.create(weapon.Instance);
    buckler.template = weapon_list.byName("buckler");
    buckler.id = try world.entities.weapons.insert(buckler);

    return combat.Agent.init(
        alloc,
        world.entities.agents,
        .player,
        .shuffled_deck,
        sb,
        bd,
        stats.Resource.init(10.0, 10.0, 2.0), // stamina
        stats.Resource.init(3.0, 5.0, 3.0), // focus
        combat.Armament{ .single = buckler },
    );
}
