const std = @import("std");
const World = @import("../domain/world.zig").World;
const lib = @import("infra");
const Cast = lib.util.Cast;
const s = @import("sdl3");
const rect = s.rect;

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

pub const UX = struct {
    alloc: std.mem.Allocator,
    ui: UIState,
    renderer: s.render.Renderer,
    window: s.video.Window,
    fps_capper: s.extras.FramerateCapper(f32),
    menu_img: s.render.Texture,

    /// initialise the presentation layer
    ///
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

        const img = try s.image.loadTexture(renderer, "assets/dod_menu.png");
        errdefer img.deinit();

        // Set logical presentation: fixed resolution, scaled to fit with letterboxing
        const img_w, const img_h = try img.getSize();
        try renderer.setLogicalPresentation(
            @intFromFloat(img_w),
            @intFromFloat(img_h),
            .letter_box,
        );

        return UX{
            .alloc = alloc,
            .ui = UIState.init(),
            .window = window,
            .renderer = renderer,
            .fps_capper = s.extras.FramerateCapper(f32){ .mode = .{ .limited = config.fps } },
            .menu_img = img,
        };
    }

    pub fn deinit(self: *UX) void {
        self.window.deinit();
        self.renderer.deinit();
    }

    // Convert screen coordinates to logical coordinates (accounts for scaling/letterbox)
    pub fn translateCoords(self: *UX, screen: rect.FPoint) rect.FPoint {
        return self.renderer.renderCoordinatesFromWindowCoordinates(screen) catch screen;
    }

    // TODO: remove world
    // replace with higher level logical x presentational mapper, or event/command driven integration
    //
    pub fn render(self: *UX, world: *World) !void {
        _ = world;

        try self.renderer.clear();

        const w, const h = try self.menu_img.getSize();
        const src = s.rect.FRect{ .x = 0, .y = 0, .w = w, .h = h };
        const dst = s.rect.FRect{ .x = 0, .y = 0, .w = w, .h = h };
        try self.renderer.renderTexture(self.menu_img, src, dst);

        try self.renderer.present();
    }
};
