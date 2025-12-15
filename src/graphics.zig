const std = @import("std");
const World= @import("model").World;
const Cast = @import("util").Cast;
const s = @import("sdl3");

pub const SpriteSheet = struct {
    path: []const u8,
    width: f32,
    height: f32,
    count: usize,
    xs: usize,
    ys: usize,
    surface: s.surface.Surface,
    texture: s.render.Texture,
    coords: std.ArrayList(s.rect.FRect),

    pub fn init(alloc: std.mem.Allocator, path: [:0]const u8, width: f32, height: f32, xs: usize, ys: usize, renderer: s.render.Renderer) !SpriteSheet{
        const count = xs * ys;
        const surface = try s.image.loadFile(path);
        const texture = try renderer.createTextureFromSurface(surface);

        var coords = try std.ArrayList(s.rect.FRect).initCapacity(alloc, count);
        var i:usize = 0;

        for(0..ys) |y| {
            for(0..xs) |x| {
                const frect = s.rect.FRect{
                    .x = 1.0 + ((1.0 + width) * Cast.itof32(x)),
                    .y = 1.0 + ((1.0 + height) * Cast.itof32(y)),
                    .w = width,
                    .h = height,
                };
                try coords.append(alloc, frect);
                i += 1;
            }
        }

        return SpriteSheet {
            .path = path,
            .width = width,
            .height = height,
            .count = xs * ys,
            .xs = xs,
            .ys = ys,
            .surface = surface,
            .texture = texture,
            .coords = coords,
        };
    }

    pub fn deinit(self: *SpriteSheet, alloc: std.mem.Allocator) void {
        self.surface.deinit();
        self.texture.deinit();
        self.coords.deinit(alloc);
    }
};


pub fn render(world: *World, renderer: *s.render.Renderer,  sprite_sheet: *SpriteSheet) !void {
    var i:usize = 0;
    for(0..Cast.itou64(world.max.y)) |y| {
        for(0..Cast.itou64(world.max.x)) |x| {
            var idx: usize = 0;
            if( x == world.player.x and y == world.player.y) { idx = 38; }

            const tw:f32 = @floatFromInt(world.config.tile_width);
            const th:f32 = @floatFromInt(world.config.tile_height);
            const xf:f32 = @floatFromInt(x);
            const xx:f32 = (tw + 1) * xf;
            const yf:f32 = @floatFromInt(y);
            const yy:f32 = (th + 1) * yf;
            const frect = s.rect.FRect {
                .x = xx,
                .y = yy,
                .w = tw,
                .h = th
            };
            try s.render.Renderer.renderTexture(
                renderer.*,
                sprite_sheet.texture,
                sprite_sheet.coords.items[idx],
                frect
            );
            i += 1;
        }
    }

    try s.render.Renderer.present(renderer.*);
}
