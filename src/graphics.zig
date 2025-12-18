const std = @import("std");
const World = @import("model").World;
const Cast = @import("util").Cast;
const s = @import("sdl3");

pub fn render(world: *World, renderer: *s.render.Renderer) !void {
    _=world;
    try renderer.clear();
    try renderer.present();
}
