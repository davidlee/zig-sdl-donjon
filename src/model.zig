const std = @import("std");
const ps = @import("polystate");
const fsm = @import("zigfsm");
const rect = @import("sdl3").rect;

const Config = struct {
    fps: usize,
    width: usize,
    height: usize,
    // screen: rect.IRect,

    fn init() @This() {
        return @This(){
            .fps = 60,
            .width = 1080,
            .height = 860,
        };
    }
};

pub const BaseMaterial = enum(u8) {
    dirt,
    stone,
    mud,
    sand,
    clay,
    wood,
    metal,
    ore,
    mineral,
    glass,
    ice,
    leather,
    plant, // plant fibre
    cloth,
    bone,
    chitin,
    flesh,
};

const UIState = struct {
    zoom: f32,
    screen: rect.IRect,
    camera: rect.IRect,
    mouse: rect.FPoint,
    fn init() @This() {
        return @This(){
            .zoom = 1.0,
            .screen = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .camera = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .mouse = .{ .x = 0, .y = 0 },
        };
    }
};

pub const World = struct {
    config: Config,
    ui: UIState,

    pub fn init(alloc: std.mem.Allocator) !@This() {
        _ = alloc;

        return @This(){
            .config = Config.init(),
            .ui = UIState.init(),
        };
    }

    pub fn deinit(self: *World, alloc: std.mem.Allocator) void {
        _ = .{ self, alloc };
    }
};
