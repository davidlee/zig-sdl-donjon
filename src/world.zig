const std = @import("std");
const lib = @import("infra");
const zigfsm = @import("zigfsm");
const player = @import("player.zig");
const random = @import("random.zig");
const events = @import("events.zig");
const apply = @import("apply.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const stats = @import("stats.zig");
const combat = @import("combat.zig");
const body = @import("body.zig");

const EventSystem = events.EventSystem;
const CommandHandler = apply.CommandHandler;
const EventProcessor = apply.EventProcessor;
const Event = events.Event;
const SlotMap = @import("slot_map.zig").SlotMap;
const Deck = @import("deck.zig").Deck;
const BeginnerDeck = card_list.BeginnerDeck;

pub const GameEvent = enum {
    start_game,
    end_player_card_selection,
    end_player_reaction,
    end_animation,
};

pub const GameState = enum {
    menu,
    player_card_selection,
    player_reaction,
    animating,
};

pub const World = struct {
    alloc: std.mem.Allocator,
    events: EventSystem,
    encounter: ?combat.Encounter,
    random: random.RandomStreamDict,
    agents: *SlotMap(*combat.Agent),
    player: *combat.Agent,
    fsm: zigfsm.StateMachine(GameState, GameEvent, .player_card_selection),
    // deck: Deck,
    commandHandler: CommandHandler,
    eventProcessor: EventProcessor,

    pub fn init(alloc: std.mem.Allocator) !*World {
        const FSM = zigfsm.StateMachine(GameState, GameEvent, .player_card_selection);

        var fsm = FSM.init();

        try fsm.addEventAndTransition(.start_game, .menu, .player_card_selection);
        try fsm.addEventAndTransition(.end_player_card_selection, .player_card_selection, .player_reaction);
        try fsm.addEventAndTransition(.end_player_reaction, .player_reaction, .animating);
        try fsm.addEventAndTransition(.end_animation, .animating, .player_card_selection);

        const playerDeck = try Deck.init(alloc, &BeginnerDeck);
        const playerStats = stats.Block.splat(5);
        const playerBody = try body.Body.fromPlan(alloc, &body.HumanoidPlan);

        const self = try alloc.create(World);
        const agents = try alloc.create(SlotMap(*combat.Agent));
        agents.* = try SlotMap(*combat.Agent).init(alloc);

        self.* = .{
            .alloc = alloc,
            .events = try EventSystem.init(alloc),
            .encounter = try combat.Encounter.init(alloc),
            .random = random.RandomStreamDict.init(),
            .agents = agents,
            .player = try player.newPlayer(alloc, agents, playerDeck, playerStats, playerBody),
            .fsm = fsm,
            // .deck = try Deck.init(alloc, &BeginnerDeck),
            .eventProcessor = undefined,
            .commandHandler = undefined,
        };
        return self;
    }

    pub fn attachEventHandlers(self: *World) void {
        self.eventProcessor = EventProcessor.init(self);
        self.commandHandler = CommandHandler.init(self);
    }

    pub fn deinit(self: *World) void {
        self.events.deinit();
        if (self.encounter) |*encounter| {
            encounter.deinit(self.alloc);
        }
        // Player is in agents, so no separate deinit needed
        for (self.agents.items.items) |x| x.deinit();
        self.agents.deinit();
        self.alloc.destroy(self.agents);
        self.alloc.destroy(self);
    }

    pub fn step(self: *World) !void {
        while (try self.eventProcessor.dispatchEvent(&self.events)) {
            // std.debug.print("processed events:\n", .{});
        }
    }

    pub fn drawRandom(self: *World, id: random.RandomStreamID) !f32 {
        const r = self.random.get(id).random().float(f32);
        try self.events.push(.{ .draw_random = .{ .stream = id, .result = r } });
        return r;
    }
};
