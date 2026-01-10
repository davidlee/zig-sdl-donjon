const std = @import("std");
const lib = @import("infra");
const player = @import("domain/player.zig");
const events = @import("domain/events.zig");
const apply = @import("domain/apply.zig");
const card_list = @import("domain/card_list.zig");
const species = @import("domain/species.zig");
const stats = @import("domain/stats.zig");
const weapon = @import("domain/weapon.zig");
const weapon_list = @import("domain/weapon_list.zig");
const ai = @import("domain/ai.zig");

const combat = @import("domain/combat.zig");
const BeginnerDeck = card_list.BeginnerDeck;
const Templates = card_list.BaseAlwaysAvailableTemplates;
const World = @import("domain/world.zig").World;

pub fn setupEncounter(world: *World) !void {
    // First mob: falchion wielder (goblin)
    const mob1 = try combat.Agent.init(
        world.alloc,
        world.entities.agents,
        ai.pool(),
        .shuffled_deck,
        &species.GOBLIN,
        stats.Block.splat(6),
    );
    var wpn1 = try world.alloc.create(weapon.Instance);
    wpn1.id = try world.entities.weapons.insert(wpn1);
    wpn1.template = weapon_list.byName("falchion");
    mob1.weapons = mob1.weapons.withEquipped(.{ .single = wpn1 });

    var card_ids1 = try world.action_registry.createFromTemplatePtrs(&Templates, 5);
    defer card_ids1.deinit(world.alloc);
    for (card_ids1.items) |id| {
        try mob1.always_available.append(world.alloc, id);
    }

    try world.encounter.?.addEnemy(mob1);

    // Second mob: spear wielder (goblin, different reach)
    const mob2 = try combat.Agent.init(
        world.alloc,
        world.entities.agents,
        ai.pool(),
        .shuffled_deck,
        &species.GOBLIN,
        stats.Block.splat(5),
    );
    var wpn2 = try world.alloc.create(weapon.Instance);
    wpn2.id = try world.entities.weapons.insert(wpn2);
    wpn2.template = weapon_list.byName("spear");
    mob2.weapons = mob2.weapons.withEquipped(.{ .single = wpn2 });

    var card_ids2 = try world.action_registry.createFromTemplatePtrs(&Templates, 5);
    defer card_ids2.deinit(world.alloc);
    for (card_ids2.items) |id| {
        try mob2.always_available.append(world.alloc, id);
    }

    try world.encounter.?.addEnemy(mob2);
}
