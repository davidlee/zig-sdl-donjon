const std = @import("std");
const lib = @import("infra");
const Cast = lib.util.Cast;
const s = @import("sdl3");
const rect = s.rect;
const view = @import("views/view.zig");
const card_renderer = @import("card_renderer.zig");
const combat_log = @import("combat_log.zig");
const AssetId = view.AssetId;
const Renderable = view.Renderable;
const CardRenderer = card_renderer.CardRenderer;

/// Cached texture for combat log rendering
const LogTextureCache = struct {
    texture: s.render.Texture,
    entry_count: usize,
    content_height: i32, // actual rendered height for scroll clamping
};

const normal_font_path = "assets/font/Caudex-Bold.ttf";
const sans_font_path = "assets/font/NotoSans.ttf";
const mono_font_path = "assets/font/AtkinsonHyperlegibleMono.ttf";
const small_font_path = mono_font_path;
const tagline_text = "When life gives you goblins, make goblinade.";

// Asset registry - indexed by AssetId
const AssetCount = @typeInfo(AssetId).@"enum".fields.len;

// const ReferenceResolution = struct {
//     w: u32,
//     h: u32,
//     name: []const u8,
// };
//
// const resolutions = [_]ReferenceResolution{
//     .{ .w = 1280, .h = 720, .name = "720p" },
//     .{ .w = 1920, .h = 1080, .name = "1080p" },
//     .{ .w = 2560, .h = 1440, .name = "1440p" },
// };
//
// const Layout = struct {
//     // Computed from logical size
//     screen: Rect,
//
//     // Major regions
//     sidebar: Rect,
//     main_area: Rect,
//     top_bar: Rect,
//
//     fn compute(logical_w: f32, logical_h: f32) Layout {
//         const sidebar_w = 250;
//         return .{
//             .screen = .{ .x = 0, .y = 0, .w = logical_w, .h = logical_h },
//             .sidebar = .{ .x = logical_w - sidebar_w, .y = 0, .w = sidebar_w, .h = logical_h },
//             .main_area = .{ .x = 0, .y = 40, .w = logical_w - sidebar_w, .h = logical_h - 40 },
//             .top_bar = .{ .x = 0, .y = 0, .w = logical_w, .h = 40 },
//         };
//     }
// };

pub const UX = struct {
    alloc: std.mem.Allocator,
    renderer: s.render.Renderer,
    window: s.video.Window,
    fps_capper: s.extras.FramerateCapper(f32),
    assets: [AssetCount]?s.render.Texture,
    cards: CardRenderer,
    font: s.ttf.Font,
    font_small: s.ttf.Font,
    log_cache: ?LogTextureCache = null,

    const SpriteEntry = struct {
        filename: [:0]const u8,
        id: AssetId,
        scale_mode: s.surface.ScaleMode = .nearest,
    };

    // Sprites loaded after splash (splash is special - needed for logical presentation size)
    const sprites = [_]SpriteEntry{
        .{ .filename = "assets/halberdier.png", .id = .player_halberdier },
        .{ .filename = "assets/fredrick-snail.png", .id = .fredrick_snail },
        .{ .filename = "assets/mob-thief.png", .id = .thief },
        .{ .filename = "assets/end-turn.png", .id = .end_turn },
        // Rune icons (48x48)
        .{ .filename = "assets/rune_eo.png", .id = .rune_eo },
        .{ .filename = "assets/rune_th.png", .id = .rune_th },
        .{ .filename = "assets/rune_u.png", .id = .rune_u },
        .{ .filename = "assets/rune_y.png", .id = .rune_y },
        .{ .filename = "assets/rune_f.png", .id = .rune_f },
        // Status overlays (48x48)
        .{ .filename = "assets/skull.png", .id = .skull },
    };

    fn loadSprites(assets: *[AssetCount]?s.render.Texture, renderer: s.render.Renderer) !void {
        for (sprites) |entry| {
            const tex = try s.image.loadTexture(renderer, entry.filename);
            try tex.setScaleMode(entry.scale_mode);
            assets[@intFromEnum(entry.id)] = tex;
        }
    }

    /// initialise the presentation layer
    pub fn init(alloc: std.mem.Allocator, config: *const lib.config.Config) !UX {
        const window = try s.video.Window.init(
            "Deck of Dwarf",
            config.width,
            config.height,
            .{ .resizable = true, .vulkan = true },
        );
        errdefer window.deinit();

        var renderer = try s.render.Renderer.init(
            window,
            null,
        );

        // Load assets
        var assets: [AssetCount]?s.render.Texture = .{null} ** AssetCount;

        const splash_bg = try s.image.loadTexture(renderer, "assets/dod_menu.png");
        assets[@intFromEnum(AssetId.splash_background)] = splash_bg;

        // Set logical presentation based on splash background size
        try renderer.setLogicalPresentation(config.logical_width, config.logical_height, .letter_box);

        try loadSprites(&assets, renderer);

        // Load fonts
        try s.ttf.init();

        const font_normal = try s.ttf.Font.init(normal_font_path, 18);
        // try font_normal.setSdf(true);
        errdefer font_normal.deinit();
        const font_small = try s.ttf.Font.init(small_font_path, 18);
        // try font_small.setSdf(true);
        errdefer font_small.deinit();

        // Pre-render tagline
        const white: s.ttf.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        assets[@intFromEnum(AssetId.splash_tagline)] = try textureFromSurface(
            renderer,
            try font_normal.renderTextBlended(tagline_text, white),
        );

        return UX{
            .alloc = alloc,
            .window = window,
            .renderer = renderer,
            .fps_capper = s.extras.FramerateCapper(f32){ .mode = .{ .limited = config.fps } },
            .assets = assets,
            .cards = try CardRenderer.init(alloc, renderer, font_normal),
            .font = font_normal,
            .font_small = font_small,
        };
    }

    pub fn deinit(self: *UX) void {
        if (self.log_cache) |cache| cache.texture.deinit();
        self.cards.deinit();
        self.font.deinit();
        self.font_small.deinit();
        s.ttf.quit();
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

    pub fn renderClear(self: *UX) !void {
        try self.renderer.setDrawColor(s.pixels.Color{ .r = 0, .g = 0, .b = 0 });
        try self.renderer.clear();
    }

    pub fn renderWithViewport(self: *UX, renderables: []const Renderable, vp: s.rect.IRect) !void {
        try self.renderer.setViewport(vp);
        // Prewarm must happen before renderList - texture creation mid-batch corrupts GPU state
        try self.prewarmCardTextures(renderables);
        try self.renderList(renderables);
        try self.renderer.setViewport(null);
    }

    /// Ensure all card textures are cached before draw calls begin.
    /// Creating textures during renderList corrupts SDL's render batch.
    fn prewarmCardTextures(self: *UX, renderables: []const Renderable) !void {
        for (renderables) |r| {
            switch (r) {
                .card => |card| _ = try self.cards.getCardTexture(card.model, self),
                else => {},
            }
        }
    }

    pub fn renderList(self: *UX, renderables: []const Renderable) !void {
        for (renderables) |r| {
            switch (r) {
                .sprite => |sprite| try self.renderSprite(sprite),
                .filled_rect => |fr| try self.renderFilledRect(fr),
                .filled_triangle => |ft| try self.renderFilledTriangle(ft),
                .card => |card| try self.renderCard(card),
                .text => |text| try self.renderText(text),
                .log_pane => |pane| try self.renderLogPane(pane),
                .stance_weights => |sw| try self.renderStanceWeights(sw),
            }
        }
    }

    pub fn renderFinalize(self: *UX) !void {
        try self.renderer.present();
    }

    /// Cleanup textures invalidated during this frame
    pub fn endFrame(self: *UX) void {
        self.cards.flushDestroyedTextures();
    }

    /// MAIN RENDER LOOP
    ///
    /// Render a list of renderables
    pub fn renderView(self: *UX, renderables: []const Renderable) !void {
        // clear
        try self.renderer.setDrawColor(s.pixels.Color{ .r = 0, .g = 0, .b = 0 });
        try self.renderer.clear();

        // layer 0: background
        //

        // layer 1: game content
        for (renderables) |r| {
            switch (r) {
                .sprite => |sprite| try self.renderSprite(sprite),
                .filled_rect => |fr| try self.renderFilledRect(fr),
                .filled_triangle => |ft| try self.renderFilledTriangle(ft),
                .card => |card| try self.renderCard(card),
                .text => |text| try self.renderText(text),
                .log_pane => |pane| try self.renderLogPane(pane),
                .stance_weights => |sw| try self.renderStanceWeights(sw),
            }
        }

        // layer 2: UI chrome
        // self.renderUI( ... )

        // layer 3: overlays (tooltips, etc)
        //

        // layer 4: debug border, etc
        try self.renderDebug();

        try self.renderer.present();
    }

    pub fn renderDebug(self: *UX) !void {
        try self.renderer.setDrawColor(s.pixels.Color{ .r = 80, .g = 70, .b = 30 });
        const w, const h, _ = try self.renderer.getLogicalPresentation();
        const border = s.rect.FRect{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
        try self.renderer.renderRect(border);
    }

    fn renderCard(self: *UX, card: view.Card) !void {
        const tex = try self.cards.getCardTexture(card.model, self);
        const tex_w, const tex_h = try tex.getSize();

        const src = rect.FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
        try self.renderer.renderTextureRotated(
            tex,
            src,
            card.dst,
            @floatCast(card.rotation),
            null, // rotate around center
            .{}, // no flip
        );
    }

    fn renderSprite(self: *UX, sprite: view.Sprite) !void {
        const tex = self.getTexture(sprite.asset) orelse return;
        const tex_w, const tex_h = try tex.getSize();

        const src = sprite.src orelse rect.FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };
        const dst = if (sprite.dst) |d|
            // Use provided dst, but substitute texture size if w/h are 0
            rect.FRect{
                .x = d.x,
                .y = d.y,
                .w = if (d.w == 0) tex_w else d.w,
                .h = if (d.h == 0) tex_h else d.h,
            }
        else
            rect.FRect{ .x = 0, .y = 0, .w = tex_w, .h = tex_h };

        try self.renderer.renderTexture(tex, src, dst);
    }

    fn renderFilledRect(self: *UX, fr: view.FilledRect) !void {
        try self.renderer.setDrawColor(fr.color);
        try self.renderer.renderFillRect(fr.rect);
    }

    fn renderFilledTriangle(self: *UX, ft: view.FilledTriangle) !void {
        const color = s.pixels.FColor{
            .r = @as(f32, @floatFromInt(ft.color.r)) / 255.0,
            .g = @as(f32, @floatFromInt(ft.color.g)) / 255.0,
            .b = @as(f32, @floatFromInt(ft.color.b)) / 255.0,
            .a = @as(f32, @floatFromInt(ft.color.a)) / 255.0,
        };
        const vertices = [3]s.render.Vertex{
            .{ .position = ft.points[0], .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
            .{ .position = ft.points[1], .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
            .{ .position = ft.points[2], .color = color, .tex_coord = .{ .x = 0, .y = 0 } },
        };
        try self.renderer.renderGeometry(null, &vertices, null);
    }

    fn renderText(self: *UX, text: view.Text) !void {
        if (text.content.len == 0) return;

        const color: s.ttf.Color = .{
            .r = text.color.r,
            .g = text.color.g,
            .b = text.color.b,
            .a = text.color.a,
        };

        const font = switch (text.font_size) {
            .small => self.font_small,
            .normal => self.font,
        };

        // Render text to surface, then texture
        // const surface = try font.renderTextLcd(text.content, color, s.ttf.Color{ .r = 0, .g = 0, .b = 0, .a = 0 });
        const surface = font.renderTextBlended(text.content, color) catch return;
        const tex = textureFromSurface(self.renderer, surface) catch return;
        defer tex.deinit();

        // Get texture dimensions and render at position
        const tex_w, const tex_h = try tex.getSize();
        const dst = rect.FRect{
            .x = text.pos.x,
            .y = text.pos.y,
            .w = tex_w,
            .h = tex_h,
        };
        try self.renderer.renderTexture(tex, null, dst);
    }

    fn renderStanceWeights(self: *UX, sw: view.StanceWeights) !void {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "ATK: {d:.0}%  DEF: {d:.0}%  MOV: {d:.0}%", .{
            sw.attack * 100,
            sw.defense * 100,
            sw.movement * 100,
        }) catch return;

        const color: s.ttf.Color = .{ .r = 220, .g = 220, .b = 220, .a = 255 };
        const surface = self.font.renderTextBlended(text, color) catch return;
        const tex = textureFromSurface(self.renderer, surface) catch return;
        defer tex.deinit();

        const tex_w, const tex_h = try tex.getSize();
        const dst = rect.FRect{
            .x = sw.pos.x,
            .y = sw.pos.y,
            .w = tex_w,
            .h = tex_h,
        };
        try self.renderer.renderTexture(tex, null, dst);
    }

    const log_padding: i32 = 10;

    fn renderLogPane(self: *UX, pane: view.LogPane) !void {
        const pane_h: i32 = @intFromFloat(pane.rect.h);

        // Check cache validity (rebuild when entry count changes)
        if (self.log_cache) |cache| {
            if (cache.entry_count != pane.entry_count) {
                cache.texture.deinit();
                self.log_cache = null;
            }
        }

        // Build cache if needed
        if (self.log_cache == null) {
            const result = try self.buildLogTexture(pane);
            self.log_cache = .{
                .texture = result.texture,
                .entry_count = pane.entry_count,
                .content_height = result.content_height,
            };
        }

        const cache = self.log_cache.?;

        // Clamp scroll to valid range
        const max_scroll = @max(0, cache.content_height - pane_h);
        const scroll_y = std.math.clamp(pane.scroll_y, 0, max_scroll);

        // Source rect: which part of the full texture to show
        // scroll_y=0 shows bottom (most recent), higher values show older
        const visible_h = @min(pane.rect.h, @as(f32, @floatFromInt(cache.content_height)));
        const src_y = cache.content_height - @as(i32, @intFromFloat(visible_h)) - scroll_y;
        const src = rect.FRect{
            .x = 0,
            .y = @floatFromInt(@max(0, src_y)),
            .w = pane.rect.w,
            .h = visible_h,
        };

        // When content < pane, anchor to bottom of pane (most recent at bottom)
        const dst_y = pane.rect.y + (pane.rect.h - visible_h);
        const dst = rect.FRect{
            .x = pane.rect.x,
            .y = dst_y,
            .w = pane.rect.w,
            .h = visible_h,
        };

        try self.renderer.renderTexture(cache.texture, src, dst);
    }

    const BuildResult = struct {
        texture: s.render.Texture,
        content_height: i32,
    };

    fn buildLogTexture(self: *UX, pane: view.LogPane) !BuildResult {
        const pane_w: usize = @intFromFloat(pane.rect.w);
        const pane_h: usize = @intFromFloat(pane.rect.h);
        const max_width: i32 = @intCast(pane_w - @as(usize, @intCast(log_padding * 2)));

        // Estimate max height (generous: 3 lines per entry avg)
        const estimated_height = @max(pane_h, pane.entries.len * 54 + 100);

        // Create target surface with alpha
        var log_surface = try s.surface.Surface.init(pane_w, estimated_height, .packed_argb_8_8_8_8);
        errdefer log_surface.deinit();

        // Clear to transparent
        try log_surface.fillRect(null, .{ .value = 0 });

        // Render all entries, track actual height
        var y: i32 = log_padding;
        for (pane.entries) |entry| {
            for (entry.spans) |span| {
                if (span.text.len == 0) continue;

                const color: s.ttf.Color = .{
                    .r = span.color.r,
                    .g = span.color.g,
                    .b = span.color.b,
                    .a = span.color.a,
                };

                const text_surface = self.font_small.renderTextSolidWrapped(span.text, color, max_width) catch continue;
                defer text_surface.deinit();

                const text_w: i32 = @intCast(text_surface.getWidth());
                const text_h: i32 = @intCast(text_surface.getHeight());

                const src_rect = s.rect.IRect{ .x = 0, .y = 0, .w = text_w, .h = text_h };
                const dst_point = s.rect.IPoint{ .x = log_padding, .y = y };
                try text_surface.blit(src_rect, log_surface, dst_point);

                y += text_h;
            }
        }

        const content_height = y + log_padding;

        return .{
            .texture = try self.renderer.createTextureFromSurface(log_surface),
            .content_height = content_height,
        };
    }
};

fn textureFromSurface(renderer: s.render.Renderer, surface: s.surface.Surface) !s.render.Texture {
    defer surface.deinit();
    return try renderer.createTextureFromSurface(surface);
}
