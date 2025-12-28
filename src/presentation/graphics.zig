const std = @import("std");
const lib = @import("infra");
const Cast = lib.util.Cast;
const s = @import("sdl3");
const rect = s.rect;
const view = @import("views/view.zig");
const AssetId = view.AssetId;
const Renderable = view.Renderable;

pub const UIState = struct {
    zoom: f32,
    screen: rect.IRect,
    camera: rect.IRect,
    mouse: rect.FPoint,
    pub fn init() UIState {
        return UIState{
            .zoom = 1.0,
            .screen = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .camera = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .mouse = .{ .x = 0, .y = 0 },
        };
    }
};

// IMPORTANT: this shouldn't know shit about the World (logical model)
// although for now we might allow some haxx in the name of forward progress
//

const font_path = "assets/font/Caudex-Bold.ttf";
const tagline_text = "When life gives you goblins, make goblinade.";

// Asset registry - indexed by AssetId
const AssetCount = @typeInfo(AssetId).@"enum".fields.len;

pub const UX = struct {
    alloc: std.mem.Allocator,
    ui: UIState,
    renderer: s.render.Renderer,
    window: s.video.Window,
    fps_capper: s.extras.FramerateCapper(f32),
    assets: [AssetCount]?s.render.Texture,

    /// initialise the presentation layer
    pub fn init(alloc: std.mem.Allocator, config: *const lib.config.Config) !UX {
        const window = try s.video.Window.init(
            "Deck of Dwarf",
            config.width,
            config.height,
            .{ .resizable = true, .vulkan = true },
        );
        errdefer window.deinit();

        const renderer = try s.render.Renderer.init(
            window,
            null,
        );

        // Load assets
        var assets: [AssetCount]?s.render.Texture = .{null} ** AssetCount;

        const splash_bg = try s.image.loadTexture(renderer, "assets/dod_menu.png");
        assets[@intFromEnum(AssetId.splash_background)] = splash_bg;

        // Set logical presentation based on splash background size
        const img_w, const img_h = try splash_bg.getSize();
        try renderer.setLogicalPresentation(
            @intFromFloat(img_w),
            @intFromFloat(img_h),
            .letter_box,
        );

        // Load tagline as pre-rendered text
        try s.ttf.init();
        defer s.ttf.quit();

        var font = try s.ttf.Font.init(font_path, 24);
        defer font.deinit();

        const white: s.ttf.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        assets[@intFromEnum(AssetId.splash_tagline)] = try textureFromSurface(
            renderer,
            try font.renderTextBlended(tagline_text, white),
        );

        return UX{
            .alloc = alloc,
            .ui = UIState.init(),
            .window = window,
            .renderer = renderer,
            .fps_capper = s.extras.FramerateCapper(f32){ .mode = .{ .limited = config.fps } },
            .assets = assets,
        };
    }

    pub fn deinit(self: *UX) void {
        for (&self.assets) |*asset| {
            if (asset.*) |tex| tex.deinit();
        }
        self.renderer.deinit();
        self.window.deinit();
    }

    pub fn getTexture(self: *const UX, id: AssetId) ?s.render.Texture {
        return self.assets[@intFromEnum(id)];
    }

    // Convert screen coordinates to logical coordinates (accounts for scaling/letterbox)
    pub fn translateCoords(self: *UX, screen: rect.FPoint) rect.FPoint {
        return self.renderer.renderCoordinatesFromWindowCoordinates(screen) catch screen;
    }

    /// Render a list of renderables
    pub fn renderView(self: *UX, renderables: []const Renderable) !void {
        try self.renderer.clear();

        for (renderables) |r| {
            switch (r) {
                .sprite => |sprite| try self.renderSprite(sprite),
                .rect => |r_rect| try self.renderRect(r_rect),
                .text => {
                    // TODO: dynamic text rendering
                },
            }
        }

        try self.renderer.present();
    }

    fn renderSprite(self: *UX, sprite: view.Sprite) !void {
        const tex = self.getTexture(sprite.asset) orelse return;
        const tex_w, const tex_h = try tex.getSize();

        const src = rect.FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
        const dst = rect.FRect{
            .x = sprite.x,
            .y = sprite.y,
            .w = sprite.w orelse tex_w,
            .h = sprite.h orelse tex_h,
        };

        try self.renderer.renderTexture(tex, src, dst);
    }

    fn renderRect(self: *UX, r: view.Rect) !void {
        try self.renderer.setDrawColor(.{
            .r = r.fill_r,
            .g = r.fill_g,
            .b = r.fill_b,
            .a = r.fill_a,
        });
        try self.renderer.renderFillRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = r.h });
    }
};

fn textureFromSurface(renderer: s.render.Renderer, surface: s.surface.Surface) !s.render.Texture {
    defer surface.deinit();
    return try renderer.createTextureFromSurface(surface);
}
