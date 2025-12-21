const std = @import("std");
const lib = @import("infra");
const zigfsm = @import("zigfsm");

const player = @import("player.zig");
const random = @import("random.zig");
const Player = player.Player;
const events = @import("events.zig");
const EventSystem = events.EventSystem;
const Event = events.Event;
const SlotMap = @import("slot_map.zig").SlotMap;
const cards = @import("cards.zig");

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

pub const Encounter = struct {};

pub const World = struct {
    alloc: std.mem.Allocator,
    events: EventSystem,
    encounter: ?Encounter,
    random: random.RandomStreamDict,
    player: Player,
    fsm: zigfsm.StateMachine(GameState, GameEvent, .wait_for_player),
    cards: SlotMap(cards.Instance), 

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
            .random = random.RandomStreamDict.init(),
            .player = Player.init(),
            .fsm = fsm,
            .cards = try SlotMap(cards.Instance).init(alloc),
        };
    }

    pub fn deinit(self: *World) void {
        self.events.deinit();
    }

    pub fn step(self: *World) void {
        _ = .{self};
        //
    }

    // this could have been (and was) on RandomStreamDict but that would
    // require it to have knowledge of World and gets dangerously close to
    // introducing a cycle between events.zig and random.zig
    //
    pub fn drawRandom(self: *World, id: random.RandomStreamID) !f32 {
        const r = self.random.get(id).random().float(f32);
        try self.events.push(.{ .draw_random = .{ .stream = id, .result = r } });
        return r;
    }
};
