const std = @import("std");
const World = @import("model.zig").World;
const lib = @import("infra");
const Cast = lib.util.Cast;
const s = lib.sdl;
const rect = lib.sdl.rect;

pub const UIState = struct {
    zoom: f32,
    screen: rect.IRect,
    camera: rect.IRect,
    mouse: rect.FPoint,
    pub fn init() @This() {
        return @This(){
            .zoom = 1.0,
            .screen = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .camera = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .mouse = .{ .x = 0, .y = 0 },
        };
    }
};

pub fn render(world: *World, renderer: *s.render.Renderer) !void {
    _ = world;
    try renderer.clear();
    try renderer.present();
}
