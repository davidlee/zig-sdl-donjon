const std = @import("std");
const lib = @import("infra");
const player = @import("domain/player.zig");
const events = @import("domain/events.zig");
const apply = @import("domain/apply.zig");
const body = @import("domain/body.zig");
const card_list = @import("domain/card_list.zig");
const stats = @import("domain/stats.zig");
const weapon = @import("domain/weapon.zig");
const weapon_list = @import("domain/weapon_list.zig");
const ai = @import("domain/ai.zig");

const combat = @import("domain/combat.zig");
const BeginnerDeck = card_list.BeginnerDeck;
const Templates = card_list.BaseAlwaysAvailableTemplates;
const World = @import("domain/world.zig").World;

pub fn setupEncounter(world: *World) !void {
    var wpn = try world.alloc.create(weapon.Instance);
    wpn.id = try world.entities.weapons.insert(wpn);
    wpn.template = weapon_list.byName("falchion");

    const mob = try combat.Agent.init(
        world.alloc,
        world.entities.agents,
        ai.pool(),
        .shuffled_deck,
        stats.Block.splat(6),
        try body.Body.fromPlan(world.alloc, &body.HumanoidPlan),
        stats.Resource.init(10.0, 10.0, 2.0), // stamina
        stats.Resource.init(3.0, 5.0, 3.0), // focus
        combat.Armament{ .single = wpn },
    );

    // Populate mob's always_available pool from card registry
    var card_ids = try world.card_registry.createFromTemplatePtrs(&Templates, 5);
    defer card_ids.deinit(world.alloc);
    for (card_ids.items) |id| {
        try mob.always_available.append(world.alloc, id);
    }

    try world.encounter.?.addEnemy(mob);
}
