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
        // texture.setScaleMode()
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
            .x = (1 + width) * fx,
            .y = (1 + height) * fy,
            .w = width,
            .h = height,
        };
    }

    pub fn frectOf(self: *SpriteSheet, x: usize, y: usize) s.rect.FRect {
        return FRectOf(self.width, self.height, x, y);
    }
};

// pub fn mapExtent(world: *World, sprite_sheet: *SpriteSheet) s.rect.IPoint {
//     const w = world.max.x * Cast.ftoi32(sprite_sheet.width);
// }
//
pub fn render(world: *World, renderer: *s.render.Renderer, sprite_sheet: *SpriteSheet) !void {
    try renderer.clear();

    // renderer.getCurrentOutputSize()
    //
    // renderer.setLogicalPresentation()

    // FIXME use renderCoordinates when calculating mouse collision
    // rather than the simple fromXY etc in SpriteSheet above
    // try renderer.renderCoordinatesFromWindowCoordinates()

    var i: usize = 0;
    for (0..world.max.y) |y| {
        for (0..world.max.x) |x| {
            var idx: usize = 0;
            if (x == world.player.x and y == world.player.y) {
                idx = 38;
            }
            var frect = sprite_sheet.frectOf(x, y);
            frect.x -= Cast.itof32(world.ui.camera.x);
            frect.y -= Cast.itof32(world.ui.camera.y);
            try s.render.Renderer.renderTexture(renderer.*, sprite_sheet.texture, sprite_sheet.coords.items[idx], frect);
            i += 1;
        }
    }
    // TODO when the ui is scaled, zoom in on either the character or the mouse position
    // at present it's essentially zooming in on 0,0
    if (world.ui.scale_changed) {
        try rescale(world, renderer, sprite_sheet);
    }

    try renderer.present();
}

pub fn rescale(world: *World, renderer: *s.render.Renderer, sprite_sheet: *SpriteSheet) !void {
    _ = .{ world, renderer, sprite_sheet };

    try renderer.setScale(world.ui.zoom, world.ui.zoom);
    world.ui.camera.w = Cast.ftoi32(Cast.itof32(world.ui.width) / world.ui.zoom);
    world.ui.camera.h = Cast.ftoi32(Cast.itof32(world.ui.height) / world.ui.zoom);
    world.ui.camera.x = @divFloor(Cast.itoi32(world.ui.width) - world.ui.camera.w, 2);
    world.ui.camera.y = @divFloor(Cast.itoi32(world.ui.height) - world.ui.camera.h, 2);

    // const pc = sprite_sheet.frectOf(world.player.x, world.player.y).asOtherRect(i32);
    //
    // const z = Cast.ftoi32(world.ui.zoom);
    // const cr = s.rect.IRect{
    //     .x = z * pc.x, // * Cast.ftoi32(sprite_sheet.width),
    //     .y = z * pc.y, // * Cast.ftoi32(sprite_sheet.height),
    //     .w = Cast.itoi32(world.ui.width),
    //     .h = Cast.itoi32(world.ui.height),
    // };
    //
    // try renderer.setClipRect(cr);

    // std.debug.print("properties: {any}\n",.{props});
    // try renderer.setLogicalPresentation(world.ui.width, world.ui.height, null);

    //
    // const tile_w: usize = @intFromFloat((sprite_sheet.width + 1.0) * world.ui.zoom);
    // const tile_h: usize = @intFromFloat((sprite_sheet.height + 1.0) * world.ui.zoom);
    //
    // const map_w: usize = Cast.itou64(world.max.x) * tile_w;
    // const map_h: usize = Cast.itou64(world.max.y) * tile_h;
    //
    // std.debug.print("\n tile {},{} -- map {},{}", .{ tile_w, tile_h, map_w, map_h });
    //
    // const rw, const rh = try renderer.getCurrentOutputSize();
    // std.debug.print("\n osize {},{}\n", .{ rw, rh });
    //
    // const w = @max(map_w, rw);
    // const h = @max(map_h, rh);
    //
    // std.debug.print("\n osize: {},{}\n", .{ w, h });
    // // TODO - centre on player, not just centre
    // const cx: i32 = Cast.itoi32((w -| rw) / 2);
    // const cy: i32 = Cast.itoi32((h -| rh) / 2);
    // _ = .{ cx, cy };
    //
    // renderer.renderCoordinatesToWindowCoordgccinates
    // try renderer.setViewport(s.rect.IRect{ .x = cx, .y = cy, .w = Cast.itoi32(world.ui.width), .h = Cast.itoi32(world.ui.height) });

    // try renderer.setLogicalPresentation(world.ui.width, world.ui.height, s.render.LogicalPresentation.letter_box);
    // try renderer.setLogicalPresentation(200, 200, s.render.LogicalPresentation.letter_box);
}
