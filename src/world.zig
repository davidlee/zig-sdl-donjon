const std = @import("std");
const lib = @import("infra");
const config = lib.config;
const rect = lib.sdl.rect;
const fsm = lib.fsm;

const body = @import("body.zig");
const player = @import("player.zig");
const Player = player.Player;
const EventSystem = @import("events.zig").EventSystem;

pub const RandomStreamSet = struct {
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
};

pub const Encounter = struct {};

pub const World = struct {
    alloc: std.mem.Allocator,
    events: EventSystem,
    encounter: ?Encounter,
    random: RandomStreamSet,
    player: Player,

    pub fn init(alloc: std.mem.Allocator) !@This() {
        return @This(){
            .alloc = alloc,
            .events = try EventSystem.init(alloc),
            .encounter = null,
            .random = RandomStreamSet.init(),
            .player = Player.init(),
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
