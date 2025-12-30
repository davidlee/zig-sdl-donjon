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
        .ai,
        combat.Strat{ .deck = mobdeck },
        stats.Block.splat(6),
        try body.Body.fromPlan(world.alloc, &body.HumanoidPlan),
        10.0,
        combat.Armament{ .single = buckler },
    );

    try world.encounter.?.enemies.append(world.alloc, mob);
}

pub fn runTestCase(world: *World) !void {
    const mobdeck = try Deck.init(world.alloc, &BeginnerDeck);
    var buckler = try world.alloc.create(weapon.Instance);
    buckler.id = try world.entities.weapons.insert(buckler);
    buckler.template = weapon_list.byName("buckler");

    const mob = try combat.Agent.init(
        world.alloc,
        world.entities.agents,
        .ai,
        combat.Strat{ .deck = mobdeck },
        stats.Block.splat(6),
        try body.Body.fromPlan(world.alloc, &body.HumanoidPlan),
        10.0,
        combat.Armament{ .single = buckler },
    );

    try world.encounter.?.enemies.append(world.alloc, mob);

    // draw some cards - only player has a "real" deck
    // we should prolly move this into an event listener in apply which runs whenever we ender the .draw_cards state ..
    for (0..8) |_| {
        try world.player.cards.deck.move(world.player.cards.deck.draw.items[0].id, .draw, .hand);
    }

    try world.commandHandler.gameStateTransition(.player_card_selection);
    log("player card selection: \n", .{});
    try nextFrame(world);

    // play a single action card
    //
    const pd = world.player.cards.deck;
    for (0..3) |_| {
        const card = pd.hand.items[0];
        try world.commandHandler.playActionCard(card);
        log("player stamina: {d}/{d}\n", .{ world.player.stamina, world.player.stamina_available });
    }

    for (world.player.cards.deck.in_play.items) |inst| log("player card: {s}\n", .{inst.template.name});

    try world.commandHandler.gameStateTransition(.tick_resolution);
    log("ENTERED TICK RESOLUTION \n\n", .{});
    try nextFrame(world);

    // for(0..10) |n| {
    const result = try world.processTick();
    log(" == tick resolved: {any}\n", .{result.resolutions});
    try nextFrame(world); // process resolution events
    log("NEXT_FRAME \n", .{});
    // }

    // try nextFrame(world);

    std.process.exit(0);
}

fn nextFrame(world: *World) !void {
    std.debug.print(" >>> NEXT_FRAME ... current_state: {}\n", .{world.fsm.currentState()});
    world.events.swap_buffers();
    try world.step(); // let's see that event;

    std.debug.print(" <<< END WORLD.STEP ... current_state: {}\n", .{world.fsm.currentState()});
}
