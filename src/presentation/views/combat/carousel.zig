//! CarouselView - dock-style card carousel for hand + known cards.
//!
//! Uses dock-style positioning: cards near mouse spread apart and raise.
//! Renders at bottom edge of viewport.

const std = @import("std");
const views = @import("../view.zig");
const infra = @import("infra");
const entity = infra.entity;
const card_mod = @import("../card/mod.zig");
const combat_mod = @import("mod.zig");
const hit_mod = combat_mod.hit;
const card_renderer = @import("../../card_renderer.zig");

const Renderable = views.Renderable;
const Point = views.Point;
const Rect = views.Rect;
const CardViewModel = card_mod.Model;
const ViewState = views.ViewState;
const CombatUIState = views.CombatUIState;

// Type aliases from card module
const CardViewData = card_mod.Data;
const CardLayout = card_mod.Layout;

// Type aliases from combat module
const ViewZone = hit_mod.Zone;
const HitResult = hit_mod.Hit;
const CardViewState = hit_mod.Interaction;

pub const CarouselView = struct {
    hand_cards: []const CardViewData,
    known_cards: []const CardViewData,

    // Layout constants
    const viewport_h: f32 = 992; // logical_h - header - footer
    const viewport_w: f32 = 1420; // logical_w - sidebar_w
    const card_w: f32 = card_renderer.CARD_WIDTH;
    const card_h: f32 = card_renderer.CARD_HEIGHT;
    const base_y: f32 = viewport_h - card_h; // cards sit at bottom
    const base_spacing: f32 = 50; // 30px overlap with 80px cards
    const group_gap: f32 = 30; // extra gap between hand and known

    // Dock effect parameters
    const max_raise: f32 = 20; // max pixels to raise when mouse directly over
    const influence_radius_x: f32 = 100; // horizontal influence for spreading
    const influence_radius_y: f32 = 150; // vertical influence for raising
    const expand_ratio: f32 = 2.5; // how much the hovered gap expands relative to base
    const max_rotation: f32 = 15; // max degrees to tilt at edges

    /// Internal: card position + rotation for layout calculations
    const CardPlacement = struct {
        rect: Rect,
        rotation: f32,
    };

    pub fn init(hand: []const CardViewData, known: []const CardViewData) CarouselView {
        return .{ .hand_cards = hand, .known_cards = known };
    }

    pub fn totalCards(self: CarouselView) usize {
        return self.hand_cards.len + self.known_cards.len;
    }

    /// Get card data and zone for a carousel index
    pub fn cardAt(self: CarouselView, index: usize) struct { card: CardViewData, zone: ViewZone } {
        if (index < self.hand_cards.len) {
            return .{ .card = self.hand_cards[index], .zone = .hand };
        }
        return .{ .card = self.known_cards[index - self.hand_cards.len], .zone = .always_available };
    }

    /// Calculate X influence (0-1) for spreading - sharper falloff
    fn influenceX(dist: f32) f32 {
        if (dist >= influence_radius_x) return 0;
        const t = 1 - dist / influence_radius_x;
        return t * t * t; // cubic falloff for tighter focus
    }

    /// Calculate Y influence (0-1) for raising - based on distance from carousel
    fn influenceY(mouse_y: f32) f32 {
        const carousel_top = base_y;
        const dist = carousel_top - mouse_y; // positive when mouse is above carousel
        if (dist < 0) return 1.0; // mouse is in/below carousel = full influence
        if (dist >= influence_radius_y) return 0;
        const t = 1 - dist / influence_radius_y;
        return t * t;
    }

    /// Calculate base width (uniform spacing) for the carousel
    pub fn baseWidth(self: CarouselView) f32 {
        const n = self.totalCards();
        if (n == 0) return 0;
        const has_gap = self.hand_cards.len > 0 and self.known_cards.len > 0;
        const gap: f32 = if (has_gap) group_gap else 0;
        return @as(f32, @floatFromInt(n - 1)) * base_spacing + card_w + gap;
    }

    fn cardCentreFromRect(rect: Rect) Point {
        return Point{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 };
    }

    fn cardRectFromCentre(centre: Point) Rect {
        return Rect{ .x = centre.x - card_w / 2, .y = centre.y - card_h / 2, .w = card_w, .h = card_h };
    }

    /// Calculate all card placements with anchored spread algorithm.
    /// Outer cards stay fixed, spacing redistributes based on mouse proximity.
    /// Returns rect + rotation for each card.
    pub fn cardPlacements(self: CarouselView, mouse_x: f32, mouse_y: f32, alloc: std.mem.Allocator) []CardPlacement {
        const n = self.totalCards();
        if (n == 0) return &.{};

        const placements = alloc.alloc(CardPlacement, n) catch return &.{};
        const points = alloc.alloc(Point, n) catch return &.{};
        defer alloc.free(points);
        const weights = alloc.alloc(f32, n) catch return &.{};
        defer alloc.free(weights);

        // Fixed total width - outer cards anchored
        const total_width = self.baseWidth();
        const start_x = (viewport_w - total_width) / 2;

        const first_x = start_x + card_w / 2;
        const last_x = start_x + total_width - card_w / 2;
        const span = last_x - first_x;

        // Gap between hand and known groups
        const has_gap = self.hand_cards.len > 0 and self.known_cards.len > 0;
        const gap: f32 = if (has_gap) group_gap else 0;

        // Normalize mouse position to [0, 1] range, clamped to carousel bounds
        const m = std.math.clamp((mouse_x - first_x) / span, 0.0, 1.0);

        // How much displacement to apply (pixels)
        const max_displacement: f32 = 120;

        // Virtual margin - cards occupy [margin, 1-margin] so edges still move a bit
        const margin: f32 = 0.15;

        for (0..n) |i| {
            // Calculate base x position with gap between groups
            const base_x = blk: {
                if (n == 1) {
                    break :blk first_x + span / 2;
                }
                const spacing_count = n - 1;
                const spacing_per_card = (span - gap) / @as(f32, @floatFromInt(spacing_count));
                var x = first_x + @as(f32, @floatFromInt(i)) * spacing_per_card;
                // Add gap after hand cards
                if (i >= self.hand_cards.len) {
                    x += gap;
                }
                break :blk x;
            };

            // Normalized position for weight calc: t ∈ [margin, 1-margin]
            const t_raw: f32 = if (n == 1) 0.5 else (base_x - first_x) / span;
            const t: f32 = margin + t_raw * (1.0 - 2.0 * margin);

            // Calculate weight using sine formula
            // Left of mouse: negative (push toward left edge)
            // Right of mouse: positive (push toward right edge)
            const weight: f32 = if (t < m and m > 0.001)
                -@sin(std.math.pi * t / m)
            else if (t > m and m < 0.999)
                @sin(std.math.pi * (t - m) / (1.0 - m))
            else
                0;

            // Apply displacement
            const card_x = base_x + weight * max_displacement;

            // Y position with raise based on proximity to mouse
            const y_inf = influenceY(mouse_y);
            const x_dist = @abs(mouse_x - base_x);
            const x_inf = influenceX(x_dist);
            const raise = max_raise * x_inf * y_inf;

            points[i] = Point{ .x = card_x, .y = base_y - raise };
            weights[i] = weight;
        }

        for (0..n) |i| {
            placements[i] = .{
                .rect = cardRectFromCentre(points[i]),
                .rotation = weights[i] * max_rotation,
            };
        }

        return placements;
    }

    /// Hit test returns HitResult at given point
    pub fn hitTest(self: CarouselView, vs: ViewState, pt: Point, alloc: std.mem.Allocator) ?HitResult {
        const n = self.totalCards();
        if (n == 0) return null;

        const placements = self.cardPlacements(vs.mouse_vp.x, vs.mouse_vp.y, alloc);
        if (placements.len == 0) return null;

        // Reverse order so topmost (rightmost, last rendered) card is hit first
        var i = n;
        while (i > 0) {
            i -= 1;
            const card_info = self.cardAt(i);
            const ui = vs.combat orelse CombatUIState{};

            // Get rect with drag/hover adjustments
            const rect = self.adjustedRect(placements[i].rect, card_info.card.id, vs, ui);

            if (rect.pointIn(pt)) {
                return .{ .card = .{ .id = card_info.card.id, .zone = card_info.zone, .rect = rect } };
            }
        }
        return null;
    }

    /// Adjust rect for drag/hover state
    pub fn adjustedRect(self: CarouselView, base_rect: Rect, card_id: entity.ID, vs: ViewState, ui: CombatUIState) Rect {
        _ = self;
        const pad: f32 = 3;

        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) {
                return .{
                    .x = vs.mouse_vp.x - pad - (drag.original_pos.x - base_rect.x),
                    .y = vs.mouse_vp.y - pad - (drag.original_pos.y - base_rect.y),
                    .w = base_rect.w + pad,
                    .h = base_rect.h + pad,
                };
            }
        }

        // Hover expansion
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) {
                return .{
                    .x = base_rect.x - pad,
                    .y = base_rect.y - pad,
                    .w = base_rect.w + pad * 2,
                    .h = base_rect.h + pad * 2,
                };
            },
            else => {},
        }

        return base_rect;
    }

    fn cardInteractionState(card_id: entity.ID, ui: CombatUIState) CardViewState {
        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) return .drag;
            if (drag.target) |id| if (id.eql(card_id)) return .target;
        }
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) return .hover,
            else => {},
        }
        return .normal;
    }

    /// Render carousel cards
    pub fn appendRenderables(
        self: CarouselView,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        last: *?Renderable,
    ) !void {
        const n = self.totalCards();
        if (n == 0) return;

        const ui = vs.combat orelse CombatUIState{};
        const placements = self.cardPlacements(vs.mouse_vp.x, vs.mouse_vp.y, alloc);
        if (placements.len == 0) return;

        // Track dragged card to render separately
        var dragged_card: ?CardViewData = null;

        for (0..n) |i| {
            const card_info = self.cardAt(i);
            const card = card_info.card;

            // Skip cards that are being animated
            if (ui.isAnimating(card.id)) continue;

            const state = cardInteractionState(card.id, ui);

            // Dragged cards render separately (centered on cursor, no rotation)
            if (state == .drag) {
                dragged_card = card;
                continue;
            }

            const placement = placements[i];
            const rect = self.adjustedRect(placement.rect, card.id, vs, ui);
            const card_vm = CardViewModel.fromTemplate(card.id, card.template, .{
                .target = state == .target,
                .played = false,
                .disabled = !card.playable,
                .highlighted = state == .hover,
                .warning = (card.playable and !card.has_valid_targets),
            });
            const item: Renderable = .{ .card = .{
                .model = card_vm,
                .dst = rect,
                .rotation = placement.rotation,
            } };

            if (state == .normal or state == .target) {
                try list.append(alloc, item);
            } else {
                last.* = item; // render last for z-order
            }
        }

        // Render dragged card last, centered on cursor, no rotation
        if (dragged_card) |card| {
            const dims = CardLayout.defaultDimensions();
            const rect = Rect{
                .x = vs.mouse_vp.x - dims.w / 2,
                .y = vs.mouse_vp.y - dims.h / 2,
                .w = dims.w,
                .h = dims.h,
            };
            const card_vm = CardViewModel.fromTemplate(card.id, card.template, .{
                .played = false,
                .disabled = !card.playable,
                .highlighted = true,
                .warning = (card.playable and !card.has_valid_targets),
            });
            last.* = .{ .card = .{
                .model = card_vm,
                .dst = rect,
                .rotation = 0,
            } };
        }
    }
};
