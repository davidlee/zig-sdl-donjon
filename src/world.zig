const std = @import("std");
const lib = @import("infra");
const config = lib.config;
const rect = lib.sdl.rect;
// const zigfsm = lib.zigfsm;
const zigfsm = @import("zigfsm");

const body = @import("body.zig");
const player = @import("player.zig");
const Player = player.Player;
const EventSystem = @import("events.zig").EventSystem;
const EventLog = @import("events.zig").EventLog;

const GameEvent = enum {
    start_game,
    end_player_turn,
    begin_animation,
    end_animation,
};

const GameState = enum {
    menu,
    wait_for_player,
    wait_for_ai,
    animating,
};

pub const RandomStreamID = enum {
    combat,
    deck_builder,
    shuffler,
    effects,
};

pub const RandomStreamDict = struct {
    combat: lib.random.Stream,
    deck_builder: lib.random.Stream,
    shuffler: lib.random.Stream,
    effects: lib.random.Stream,

    fn init() @This() {
        return @This(){
            .combat = lib.random.Stream.init(),
            .deck_builder = lib.random.Stream.init(),
            .shuffler = lib.random.Stream.init(),
            .effects = lib.random.Stream.init(),
        };
    }
    pub fn get(self: *RandomStreamDict, id: RandomStreamID) !lib.random.Stream {
        return switch (id) {
            RandomStreamID.combat => self.combat,
            RandomStreamID.deck_builder => self.deck_builder,
            RandomStreamID.shuffler => self.shuffler,
            RandomStreamID.effects => self.effects,
            else => unreachable,
        };
    }
};

pub const Encounter = struct {};

pub const World = struct {
    alloc: std.mem.Allocator,
    events: EventSystem,
    encounter: ?Encounter,
    random: RandomStreamDict,
    player: Player,
    fsm: zigfsm.StateMachine(GameState, GameEvent, .wait_for_player),
    event_log: EventLog,

    pub fn init(alloc: std.mem.Allocator) !@This() {
        var fsm = zigfsm.StateMachine(GameState, GameEvent, .wait_for_player).init();

        try fsm.addEventAndTransition(.start_game, .menu, .wait_for_player);
        try fsm.addEventAndTransition(.end_player_turn, .wait_for_player, .wait_for_ai);
        try fsm.addEventAndTransition(.begin_animation, .wait_for_ai, .animating);
        try fsm.addEventAndTransition(.end_animation, .animating, .wait_for_player);

        return @This(){
            .alloc = alloc,
            .events = try EventSystem.init(alloc),
            .encounter = null,
            .random = RandomStreamDict.init(),
            .player = Player.init(),
            .fsm = fsm,
            .event_log = try EventLog.init(alloc),
        };
    }

    pub fn deinit(self: *World, alloc: std.mem.Allocator) void {
        _ = .{ self, alloc };
        self.events.deinit();
    }

    pub fn step(self: *World) void {
        _ = .{self};
        //
    }
};
