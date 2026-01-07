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
    // First mob: falchion wielder
    var wpn1 = try world.alloc.create(weapon.Instance);
    wpn1.id = try world.entities.weapons.insert(wpn1);
    wpn1.template = weapon_list.byName("falchion");

    const mob1 = try combat.Agent.init(
        world.alloc,
        world.entities.agents,
        ai.pool(),
        .shuffled_deck,
        stats.Block.splat(6),
        try body.Body.fromPlan(world.alloc, &body.HumanoidPlan),
        stats.Resource.init(10.0, 10.0, 2.0), // stamina
        stats.Resource.init(3.0, 5.0, 3.0), // focus
        stats.Resource.init(5.0, 5.0, 0.0), // blood
        combat.Armament{ .single = wpn1 },
    );

    var card_ids1 = try world.card_registry.createFromTemplatePtrs(&Templates, 5);
    defer card_ids1.deinit(world.alloc);
    for (card_ids1.items) |id| {
        try mob1.always_available.append(world.alloc, id);
    }

    try world.encounter.?.addEnemy(mob1);

    // Second mob: spear wielder (different reach)
    var wpn2 = try world.alloc.create(weapon.Instance);
    wpn2.id = try world.entities.weapons.insert(wpn2);
    wpn2.template = weapon_list.byName("spear");

    const mob2 = try combat.Agent.init(
        world.alloc,
        world.entities.agents,
        ai.pool(),
        .shuffled_deck,
        stats.Block.splat(5),
        try body.Body.fromPlan(world.alloc, &body.HumanoidPlan),
        stats.Resource.init(8.0, 8.0, 1.5), // stamina (less)
        stats.Resource.init(2.0, 4.0, 2.0), // focus (less)
        stats.Resource.init(5.0, 5.0, 0.0), // blood
        combat.Armament{ .single = wpn2 },
    );

    var card_ids2 = try world.card_registry.createFromTemplatePtrs(&Templates, 5);
    defer card_ids2.deinit(world.alloc);
    for (card_ids2.items) |id| {
        try mob2.always_available.append(world.alloc, id);
    }

    try world.encounter.?.addEnemy(mob2);
}
