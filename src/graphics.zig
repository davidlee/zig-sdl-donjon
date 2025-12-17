const std = @import("std");
const World = @import("model").World;
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

    pub fn init(alloc: std.mem.Allocator, path: [:0]const u8, width: f32, height: f32, xs: usize, ys: usize, renderer: s.render.Renderer) !SpriteSheet {
        const count = xs * ys;
        const surface = try s.image.loadFile(path);
        const texture = try renderer.createTextureFromSurface(surface);

        var coords = try std.ArrayList(s.rect.FRect).initCapacity(alloc, count);

        for (0..ys) |y|
            for (0..xs) |x|
                try coords.append(alloc, SpriteSheet.FRectOf(width, height, x, y));

        return SpriteSheet{
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

    pub fn FRectOf(width: f32, height: f32, x: usize, y: usize) s.rect.FRect {
        const fx: f32 = Cast.itof32(x);
        const fy: f32 = Cast.itof32(y);

        return s.rect.FRect{
            .x = 1 + (1 + width) * fx,
            .y = 1 + (1 + height) * fy,
            .w = width,
            .h = height,
        };
    }

    pub fn frectOf(self: *SpriteSheet, x: usize, y: usize) s.rect.FRect {
        return FRectOf(self.width, self.height, x, y);
    }

    pub fn renderSize(self: *SpriteSheet, xs: usize, ys: usize, scale: f32) s.rect.FPoint {
        // _ = scale;
        const fx: f32 = @floatFromInt(xs);
        const fy: f32 = @floatFromInt(ys);
        return .{
            .x = (1 + (self.width + 1) * fx) * scale,
            .y = (1 + (self.height + 1) * fy) * scale,
        };
    }
};

pub fn render(world: *World, renderer: *s.render.Renderer, sprite_sheet: *SpriteSheet) !void {
    try renderer.clear();

    // FIXME use renderCoordinates when calculating mouse collision
    // rather than the simple fromXY etc in SpriteSheet above
    // try renderer.renderCoordinatesFromWindowCoordinates()
    // TODO when the ui is scaled, zoom in on either the character or the mouse position
    // at present it's essentially zooming in on 0,0
    try rescale(world, renderer, sprite_sheet);

    // var co = try renderer.renderCoordinatesFromWindowCoordinates(world.ui.mouse);
    // var mid = s.rect.FPoint{
    //     .x = Cast.itof32(world.ui.screen.w) / 2,
    //     .y = Cast.itof32(world.ui.screen.h) / 2,
    // };

    var i: usize = 0;
    for (0..world.max.y) |y| {
        for (0..world.max.x) |x| {
            var cell_idx: usize = world.cell(x, y);
            if (x == world.player.x and y == world.player.y) {
                cell_idx = 38;
            }

            var frect = sprite_sheet.frectOf(x, y);
            frect.x += Cast.itof32(world.ui.camera.x);
            frect.y += Cast.itof32(world.ui.camera.y);

            if (frect.pointIn(world.ui.mouse)) {
                cell_idx = 79;
            }

            try s.render.Renderer.renderTexture(renderer.*, sprite_sheet.texture, sprite_sheet.coords.items[cell_idx], frect);
            i += 1;
        }
    }

    try renderer.present();
}

pub fn rescale(world: *World, renderer: *s.render.Renderer, sprite_sheet: *SpriteSheet) !void {
    try renderer.setScale(world.ui.zoom, world.ui.zoom);
    const p = sprite_sheet.frectOf(world.player.x, world.player.y);

    world.ui.camera.x = @intFromFloat(Cast.itof32(world.ui.screen.w) / 2.0 / world.ui.zoom - p.x - (p.w / 2));
    world.ui.camera.y = @intFromFloat(Cast.itof32(world.ui.screen.h) / 2.0 / world.ui.zoom - p.y - (p.h / 2));
}
