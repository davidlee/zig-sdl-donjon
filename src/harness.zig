const std = @import("std");
const lib = @import("infra");
const zigfsm = @import("zigfsm");
const player = @import("domain/player.zig");
const random = @import("domain/random.zig");
const events = @import("domain/events.zig");
const apply = @import("domain/apply.zig");
const cards = @import("domain/cards.zig");
const body = @import("domain/body.zig");
const card_list = @import("domain/card_list.zig");
const stats = @import("domain/stats.zig");
const entity = lib.entity;
const weapon = @import("domain/weapon.zig");
const weapon_list = @import("domain/weapon_list.zig");
const ai = @import("domain/ai.zig");

const EventSystem = events.EventSystem;
const CommandHandler = apply.CommandHandler;
const EventProcessor = apply.EventProcessor;
const Event = events.Event;
const SlotMap = @import("domain/slot_map.zig").SlotMap;
const combat = @import("domain/combat.zig");
const Deck = @import("domain/deck.zig").Deck;
const BeginnerDeck = card_list.BeginnerDeck;
const World = @import("domain/world.zig").World;

const log = std.debug.print;

pub fn setupEncounter(world: *World) !void {
    const mobdeck = try Deck.init(world.alloc, &BeginnerDeck);
    var buckler = try world.alloc.create(weapon.Instance);
    buckler.id = try world.entities.weapons.insert(buckler);
    buckler.template = weapon_list.byName("buckler");

    const mob = try combat.Agent.init(
        world.alloc,
        world.entities.agents,
        ai.simple(),
        combat.Strat{ .deck = mobdeck },
        stats.Block.splat(6),
        try body.Body.fromPlan(world.alloc, &body.HumanoidPlan),
        stats.Resource.init(10.0, 10.0, 2.0), // stamina
        stats.Resource.init(3.0, 5.0, 3.0), // focus
        combat.Armament{ .single = buckler },
    );

    try world.encounter.?.addEnemy(mob);
}
