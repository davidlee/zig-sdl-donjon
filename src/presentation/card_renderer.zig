// CardRenderer - pre-renders cards to textures
//
// Pure rendering - knows nothing about domain types.
// Takes CardViewModel, produces textures. Caches by instance ID.

const std = @import("std");
const s = @import("sdl3");
const card_view = @import("views/card_view.zig");

const CardViewModel = card_view.CardViewModel;
const CardKind = card_view.CardKind;
const CardRarity = card_view.CardRarity;
const CardState = card_view.CardState;

const Texture = s.render.Texture;
const Renderer = s.render.Renderer;
const Color = s.pixels.Color;
const Font = s.ttf.Font;

/// Card instance ID for cache keying (matches entity.ID layout)
pub const CardInstanceID = packed struct {
    index: u32,
    generation: u32,
};

// Standard card dimensions (in logical pixels)
pub const CARD_WIDTH: f32 = 80;
pub const CARD_HEIGHT: f32 = 110;

// Colors by card kind
const KindColors = struct {
    background: Color,
    border: Color,
};

fn kindColors(kind: CardKind) KindColors {
    return switch (kind) {
        .action => .{
            .background = .{ .r = 60, .g = 20, .b = 20, .a = 255 },
            .border = .{ .r = 180, .g = 60, .b = 60, .a = 255 },
        },
        .passive => .{
            .background = .{ .r = 20, .g = 40, .b = 60, .a = 255 },
            .border = .{ .r = 60, .g = 120, .b = 180, .a = 255 },
        },
        .reaction => .{
            .background = .{ .r = 50, .g = 40, .b = 20, .a = 255 },
            .border = .{ .r = 200, .g = 160, .b = 60, .a = 255 },
        },
        .modifier => .{
            .background = .{ .r = 50, .g = 40, .b = 20, .a = 255 },
            .border = .{ .r = 20, .g = 30, .b = 160, .a = 255 },
        },
        .other => .{
            .background = .{ .r = 40, .g = 40, .b = 40, .a = 255 },
            .border = .{ .r = 120, .g = 120, .b = 120, .a = 255 },
        },
    };
}

fn rarityBorderColor(rarity: CardRarity) Color {
    return switch (rarity) {
        .common => .{ .r = 150, .g = 150, .b = 150, .a = 255 },
        .uncommon => .{ .r = 80, .g = 180, .b = 80, .a = 255 },
        .rare => .{ .r = 80, .g = 120, .b = 220, .a = 255 },
        .epic => .{ .r = 160, .g = 80, .b = 200, .a = 255 },
        .legendary => .{ .r = 220, .g = 180, .b = 60, .a = 255 },
    };
}

fn stateOverlayColor(state: CardState) ?Color {
    if (state.disabled) return .{ .r = 33, .g = 33, .b = 33, .a = 180 };
    if (state.exhausted) return .{ .r = 40, .g = 40, .b = 50, .a = 150 };
    return null;
}

fn stateBorderColor(state: CardState) ?Color {
    if (state.selected) return .{ .r = 255, .g = 255, .b = 100, .a = 255 };
    if (state.highlighted) return .{ .r = 200, .g = 200, .b = 255, .a = 255 };
    if (state.target) return .{ .r = 0, .g = 125, .b = 255, .a = 255 };
    if (state.played) return .{ .r = 200, .g = 200, .b = 200, .a = 255 };
    return null;
}

pub const CardRenderer = struct {
    renderer: Renderer,
    cache: std.AutoHashMap(u64, CacheEntry),
    pending_destroy: std.ArrayList(Texture),
    alloc: std.mem.Allocator,
    font: Font,

    const CacheEntry = struct {
        texture: Texture,
        state_hash: u8, // to detect state changes
    };

    pub fn init(alloc: std.mem.Allocator, renderer: Renderer, font: Font) !CardRenderer {
        return .{
            .renderer = renderer,
            .cache = std.AutoHashMap(u64, CacheEntry).init(alloc),
            .pending_destroy = try std.ArrayList(Texture).initCapacity(alloc, 8),
            .alloc = alloc,
            .font = font,
        };
    }

    pub fn deinit(self: *CardRenderer) void {
        self.flushDestroyedTextures();
        self.pending_destroy.deinit(self.alloc);
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            entry.texture.deinit();
        }
        self.cache.deinit();
    }

    /// Destroy textures queued for cleanup. Call after frame render completes.
    pub fn flushDestroyedTextures(self: *CardRenderer) void {
        for (self.pending_destroy.items) |tex| {
            tex.deinit();
        }
        self.pending_destroy.clearRetainingCapacity();
    }

    /// Get or create texture for a card
    pub fn getCardTexture(self: *CardRenderer, card: CardViewModel) !Texture {
        const id_key = idToKey(card.id);
        const state_hash = stateToHash(card.state);

        if (self.cache.get(id_key)) |entry| {
            // Cache hit - return if state unchanged
            if (entry.state_hash == state_hash) {
                return entry.texture;
            }
            // State changed - defer destruction until after frame completes
            try self.pending_destroy.append(self.alloc, entry.texture);
        }

        const tex = try self.renderCard(card);
        try self.cache.put(id_key, .{
            .texture = tex,
            .state_hash = state_hash,
        });
        return tex;
    }

    /// Force re-render of a card
    pub fn invalidate(self: *CardRenderer, id: CardInstanceID) void {
        const key = @as(u64, id.index) | (@as(u64, id.generation) << 32);
        if (self.cache.fetchRemove(key)) |entry| {
            entry.value.texture.deinit();
        }
    }

    /// Clear entire cache
    pub fn invalidateAll(self: *CardRenderer) void {
        var it = self.cache.valueIterator();
        while (it.next()) |entry| {
            entry.texture.deinit();
        }
        self.cache.clearRetainingCapacity();
    }

    fn idToKey(id: anytype) u64 {
        return @as(u64, id.index) | (@as(u64, id.generation) << 32);
    }

    fn stateToHash(state: CardState) u8 {
        const bits: u6 = @bitCast(state);
        return bits;
    }

    /// Render card to a new texture
    fn renderCard(self: *CardRenderer, card: CardViewModel) !Texture {
        const tex = try Texture.init(
            self.renderer,
            .packed_rgba_8_8_8_8,
            .target,
            @intFromFloat(CARD_WIDTH),
            @intFromFloat(CARD_HEIGHT),
        );
        errdefer tex.deinit();

        try self.renderer.setTarget(tex);
        defer self.renderer.setTarget(null) catch {};

        try self.renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
        try self.renderer.clear();

        try self.drawCardBackground(card.kind);
        try self.drawCardBorder(card.rarity, card.state);
        try self.drawCostIndicator(card.stamina_cost);

        // State overlay (exhausted, disabled)
        if (stateOverlayColor(card.state)) |overlay| {
            try self.renderer.setDrawColor(overlay);
            try self.renderer.renderFillRect(.{
                .x = 4,
                .y = 4,
                .w = CARD_WIDTH - 8,
                .h = CARD_HEIGHT - 8,
            });
        }

        // Card name
        try self.drawCardName(card.name);

        return tex;
    }

    fn drawCardBackground(self: *CardRenderer, kind: CardKind) !void {
        const colors = kindColors(kind);
        const margin: f32 = 4;

        try self.renderer.setDrawColor(colors.background);
        try self.renderer.renderFillRect(.{
            .x = margin,
            .y = margin,
            .w = CARD_WIDTH - margin * 2,
            .h = CARD_HEIGHT - margin * 2,
        });
    }

    fn drawCardBorder(self: *CardRenderer, rarity: CardRarity, state: CardState) !void {
        // State border takes precedence
        const border_color = stateBorderColor(state) orelse rarityBorderColor(rarity);
        const border_width: f32 = 4;

        try self.renderer.setDrawColor(border_color);

        // Top
        try self.renderer.renderFillRect(.{ .x = 0, .y = 0, .w = CARD_WIDTH, .h = border_width });
        // Bottom
        try self.renderer.renderFillRect(.{ .x = 0, .y = CARD_HEIGHT - border_width, .w = CARD_WIDTH, .h = border_width });
        // Left
        try self.renderer.renderFillRect(.{ .x = 0, .y = 0, .w = border_width, .h = CARD_HEIGHT });
        // Right
        try self.renderer.renderFillRect(.{ .x = CARD_WIDTH - border_width, .y = 0, .w = border_width, .h = CARD_HEIGHT });
    }

    fn drawCostIndicator(self: *CardRenderer, stamina_cost: f32) !void {
        const radius: f32 = 16;
        const cx: f32 = 20;
        const cy: f32 = 20;

        // Outer circle (rect placeholder)
        try self.renderer.setDrawColor(.{ .r = 40, .g = 40, .b = 60, .a = 255 });
        try self.renderer.renderFillRect(.{
            .x = cx - radius,
            .y = cy - radius,
            .w = radius * 2,
            .h = radius * 2,
        });

        // Color by cost
        const cost_color: Color = if (stamina_cost <= 1)
            .{ .r = 100, .g = 200, .b = 100, .a = 255 }
        else if (stamina_cost <= 2)
            .{ .r = 200, .g = 200, .b = 100, .a = 255 }
        else
            .{ .r = 200, .g = 100, .b = 100, .a = 255 };

        // Inner circle
        try self.renderer.setDrawColor(cost_color);
        try self.renderer.renderFillRect(.{
            .x = cx - radius + 3,
            .y = cy - radius + 3,
            .w = (radius - 3) * 2,
            .h = (radius - 3) * 2,
        });

        // TODO: render stamina_cost as text
    }

    fn drawCardName(self: *CardRenderer, name: []const u8) !void {
        if (name.len == 0) return;

        const white: s.ttf.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        const text_surface = try self.font.renderTextBlended(name, white);
        defer text_surface.deinit();

        const text_tex = try self.renderer.createTextureFromSurface(text_surface);
        defer text_tex.deinit();

        const tex_w, const tex_h = try text_tex.getSize();

        // Center horizontally, position below cost indicator
        const x = (CARD_WIDTH - tex_w) / 2;
        const y: f32 = 45;

        try self.renderer.renderTexture(
            text_tex,
            .{ .x = 0, .y = 0, .w = tex_w, .h = tex_h },
            .{ .x = x, .y = y, .w = tex_w, .h = tex_h },
        );
    }
};
