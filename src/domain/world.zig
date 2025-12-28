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
const tick = @import("tick.zig");
const weapon = @import("weapon.zig");

const EventSystem = events.EventSystem;
const CommandHandler = apply.CommandHandler;
const EventProcessor = apply.EventProcessor;
const Event = events.Event;
const SlotMap = @import("slot_map.zig").SlotMap;
const Deck = @import("deck.zig").Deck;
const BeginnerDeck = card_list.BeginnerDeck;
const TickResolver = tick.TickResolver;

pub const EntityMap = struct {
    agents: *SlotMap(*combat.Agent),
    weapons: *SlotMap(*weapon.Instance),
    // ... etc

    pub fn init(alloc: std.mem.Allocator) !EntityMap {
        const agents = try alloc.create(SlotMap(*combat.Agent));
        agents.* = try SlotMap(*combat.Agent).init(alloc);

        const weapons = try alloc.create(SlotMap(*weapon.Instance));
        weapons.* = try SlotMap(*weapon.Instance).init(alloc);

        return .{ .agents = agents, .weapons = weapons };
    }

    pub fn deinit(self: *EntityMap, alloc: std.mem.Allocator) void {
        for (self.agents.items.items) |x| x.deinit();
        self.agents.deinit();
        alloc.destroy(self.agents);

        for (self.weapons.items.items) |x| alloc.destroy(x);
        self.weapons.deinit();
        alloc.destroy(self.weapons);
    }
};

pub const GameEvent = enum {
    start_encounter,
    begin_player_card_selection,
    begin_tick_resolution,
    player_reaction_opportunity,
    continue_tick_resolution,
    animate_resolution,
    redraw,
    show_loot,
    player_died,
};

pub const GameState = enum {
    menu,
    draw_hand,
    player_card_selection,
    tick_resolution, // NEW: resolve committed actions
    player_reaction,
    encounter_summary,
    animating,
};

pub const World = struct {
    alloc: std.mem.Allocator,
    events: EventSystem,
    encounter: ?combat.Encounter,
    random: random.RandomStreamDict,
    entities: EntityMap,
    // agents: *SlotMap(*combat.Agent),
    player: *combat.Agent,
    fsm: zigfsm.StateMachine(GameState, GameEvent, .draw_hand),
    tickResolver: TickResolver,
    // deck: Deck,
    commandHandler: CommandHandler,
    eventProcessor: EventProcessor,

    pub fn init(alloc: std.mem.Allocator) !*World {
        const FSM = zigfsm.StateMachine(GameState, GameEvent, .draw_hand);

        var fsm = FSM.init();

        try fsm.addEventAndTransition(.start_encounter, .menu, .draw_hand);

        try fsm.addEventAndTransition(.begin_player_card_selection, .draw_hand, .player_card_selection);
        try fsm.addEventAndTransition(.begin_tick_resolution, .player_card_selection, .tick_resolution);
        try fsm.addEventAndTransition(.player_reaction_opportunity, .tick_resolution, .player_reaction);
        try fsm.addEventAndTransition(.continue_tick_resolution, .player_reaction, .tick_resolution);
        try fsm.addEventAndTransition(.animate_resolution, .tick_resolution, .animating);
        try fsm.addEventAndTransition(.continue_tick_resolution, .animating, .tick_resolution);

        try fsm.addEventAndTransition(.player_died, .animating, .menu);
        try fsm.addEventAndTransition(.show_loot, .animating, .encounter_summary);
        try fsm.addEventAndTransition(.redraw, .animating, .draw_hand);

        const playerDeck = try Deck.init(alloc, &BeginnerDeck);
        const playerStats = stats.Block.splat(5);
        const playerBody = try body.Body.fromPlan(alloc, &body.HumanoidPlan);

        const self = try alloc.create(World);

        self.* = .{
            .alloc = alloc,
            .events = try EventSystem.init(alloc),
            .encounter = try combat.Encounter.init(alloc),
            .random = random.RandomStreamDict.init(),
            .entities = try EntityMap.init(alloc),
            .player = undefined, // set after entities exist
            .fsm = fsm,
            .tickResolver = try TickResolver.init(alloc),
            .eventProcessor = undefined,
            .commandHandler = undefined,
        };
        self.player = try player.newPlayer(alloc, self, playerDeck, playerStats, playerBody);
        return self;
    }

    pub fn attachEventHandlers(self: *World) void {
        self.eventProcessor = EventProcessor.init(self);
        self.commandHandler = CommandHandler.init(self);
    }

    pub fn deinit(self: *World) void {
        self.events.deinit();
        self.tickResolver.deinit();
        if (self.encounter) |*encounter| {
            encounter.deinit(self.alloc);
        }
        self.entities.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn step(self: *World) !void {
        while (try self.eventProcessor.dispatchEvent(&self.events)) {
            // std.debug.print("processed events:\n", .{});
        }
    }

    /// Process a complete tick: commit actions, resolve, cleanup
    pub fn processTick(self: *World) !tick.TickResult {
        // Reset resolver for new tick
        self.tickResolver.reset();

        // Commit player cards
        try self.tickResolver.commitPlayerCards(self.player);

        // Commit mob actions
        if (self.encounter) |*enc| {
            try self.tickResolver.commitMobActions(enc.enemies.items);
        }

        // Resolve all actions
        const result = try self.tickResolver.resolve(self);

        // Cleanup: apply costs, move cards
        try apply.applyCommittedCosts(self.tickResolver.committed.items, &self.events);

        // Emit tick ended event
        try self.events.push(.{ .tick_ended = {} });

        return result;
    }

    pub fn drawRandom(self: *World, id: random.RandomStreamID) !f32 {
        const r = self.random.get(id).random().float(f32);
        try self.events.push(.{ .draw_random = .{ .stream = id, .result = r } });
        return r;
    }
};
