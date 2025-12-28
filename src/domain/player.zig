const std = @import("std");
const stats = @import("stats.zig");
const deck = @import("deck.zig");
const body = @import("body.zig");
const combat = @import("combat.zig");
const weapon = @import("weapon.zig");
const weapon_list = @import("weapon_list.zig");
const slot_map = @import("slot_map.zig");

const World = @import("world.zig").World;

pub fn newPlayer(
    alloc: std.mem.Allocator,
    world: *World,
    playerDeck: deck.Deck,
    sb: stats.Block,
    bd: body.Body,
) !*combat.Agent {
    var buckler = try alloc.create(weapon.Instance);
    buckler.template = weapon_list.byName("buckler");
    buckler.id = try world.entities.weapons.insert(buckler);

    // var arm = try alloc.create(combat.Armament);
    // arm.single = buckler;

    return combat.Agent.init(
        alloc,
        world.entities.agents,
        .player,
        combat.Strat{ .deck = playerDeck },
        sb,
        bd,
        10.0,
        combat.Armament{ .single = buckler },
    );
}
