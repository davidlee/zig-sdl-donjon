const std = @import("std");
const lib = @import("infra");
const config = lib.config;
const rect = lib.sdl.rect;
const fsm = lib.fsm;

const body = @import("body.zig");

const archetypes = .{
    .soldier = StatBlock{
        .power = 6,
        .speed = 5,
        .agility = 4,
        .dexterity = 3,
        .fortitude = 6,
        .endurance = 5,
        // mental
        .acuity = 4,
        .will = 4,
        .intuition = 3,
        .presence = 5,
    },
    .hunter = StatBlock{
        .power = 5,
        .speed = 6,
        .agility = 7,
        .dexterity = 3,
        .fortitude = 5,
        .endurance = 5,
        // mental
        .acuity = 6,
        .will = 4,
        .intuition = 4,
        .presence = 4,
    },
};
pub const StatBlock = packed struct {
    // physical
    power: f32,
    speed: f32,
    agility: f32,
    dexterity: f32,
    fortitude: f32,
    endurance: f32,
    // mental
    acuity: f32,
    will: f32,
    intuition: f32,
    presence: f32,

    fn splat(num: f32) StatBlock {
        return StatBlock{
            .power = num,
            .speed = num,
            .agility = num,
            .dexterity = num,
            .fortitude = num,
            .endurance = num,
            // mental
            .acuity = num,
            .will = num,
            .intuition = num,
            .presence = num,
        };
    }

    fn init(template: StatBlock) StatBlock {
        const s = StatBlock{};
        s.* = template;
        return s;
    }
};

pub const Player = struct {
    stats: StatBlock,
    wounds: struct {},
    conditions: struct {},

    fn init() Player {
        return Player{ .stats = StatBlock.splat(5), .wounds = {}, .conditions = {} };
    }
};

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
    events: lib.events.EventSystem,
    encounter: ?Encounter,
    random: RandomStreamSet,

    pub fn init(alloc: std.mem.Allocator) !@This() {
        return @This(){
            .alloc = alloc,
            .events = try lib.events.EventSystem.init(alloc),
            .encounter = null,
            .random = RandomStreamSet.init(),
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
