const std = @import("std");
const ps = @import("polystate");
const fsm = @import("zigfsm");
const rect = @import("sdl3").rect;

const Config = struct {
    fps: usize,
    screen_width: usize,
    screen_height: usize,
    tile_width: usize,
    tile_height: usize,
    tile_padding: usize,
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

pub const Liquid = struct {
    depth: u8,
    kind: u8, // FIXME:
};

pub const Cell = struct {
    x: i32,
    y: i32,
    fill_material: ?BaseMaterial,
    floor_material: ?BaseMaterial,
    liquid: ?Liquid,
    items: ?*std.ArrayList(u8), // FIXME
};

const UIState = struct {
    scale: f32,
    zoom: f32,
    // TODO: move width and height into screen rect
    width: usize,
    height: usize,

    screen: rect.IRect,
    camera: rect.IRect,
    scale_changed: bool,
};

pub const World = struct {
    player: struct { x: usize, y: usize }, // TODO move into point
    max: struct { x: usize, y: usize },
    // map: *std.ArrayList(Cell),
    config: Config,
    ui: UIState,

    pub fn init(alloc: std.mem.Allocator) !@This() {
        const w = 1080;
        const h = 540;
        const tw = 12;
        const th = 12;
        const p = 1;
        const mx = w / (p + tw);
        const my = h / (p + th);
        // var array_list = try std.ArrayList(Cell).initCapacity(alloc, mx * my);
        _ = alloc;

        return @This(){
            .player = .{
                .x = 0,
                .y = 0,
            },
            // .map = &array_list, // TODO:
            .max = .{
                .x = mx,
                .y = my,
            },
            .config = Config{
                .fps = 60,
                .screen_width = w,
                .screen_height = h,
                .tile_width = tw,
                .tile_height = th,
                .tile_padding = p,
            },
            .ui = UIState{ .scale = 1.0, .zoom = 1.0, .width = w, .height = h, .scale_changed = true, .screen = rect.IRect{
                .x = 0,
                .y = 0,
                .w = w,
                .h = h,
            }, .camera = rect.IRect{
                .x = 0,
                .y = 0,
                .w = w,
                .h = h,
            } },
        };
    }

    pub fn deinit(self: *World, alloc: std.mem.Allocator) void {
        _ = .{ self, alloc };
    }
};
