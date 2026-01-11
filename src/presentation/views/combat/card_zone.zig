//! CardZoneView - lightweight view over a card zone (hand, in_play, etc.)
//!
//! Created on-demand since zone contents are dynamic.
//! Uses CardViewData (decoupled from Instance pointers).

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

pub fn getLayout(zone: ViewZone) CardLayout {
    return .{
        .w = card_renderer.CARD_WIDTH,
        .h = card_renderer.CARD_HEIGHT,
        .start_x = 10,
        .spacing = card_renderer.CARD_WIDTH + 10,
        .y = switch (zone) {
            .hand => 400,
            .in_play => 200,
            .always_available => 540, // same row as hand, different x
            .spells => 400,
            .player_plays => 200,
            .enemy_plays => 50,
        },
    };
}

pub fn getLayoutOffset(zone: ViewZone, offset: Point) CardLayout {
    var layout = getLayout(zone);
    layout.start_x += offset.x;
    layout.y += offset.y;
    return layout;
}

pub const CardZoneView = struct {
    zone: ViewZone,
    layout: CardLayout,
    cards: []const CardViewData,

    pub fn init(zone: ViewZone, card_data: []const CardViewData) CardZoneView {
        return .{ .zone = zone, .layout = getLayout(zone), .cards = card_data };
    }

    pub fn initWithLayout(zone: ViewZone, card_data: []const CardViewData, layout: CardLayout) CardZoneView {
        return .{ .zone = zone, .layout = layout, .cards = card_data };
    }

    /// Hit test returns HitResult at given point
    pub fn hitTest(self: CardZoneView, vs: ViewState, pt: Point) ?HitResult {
        // Reverse order so topmost (last rendered) card is hit first
        var i = self.cards.len;
        while (i > 0) {
            i -= 1;
            const rect = self.cardRect(i, self.cards[i].id, vs);
            if (rect.pointIn(pt)) {
                return .{ .card = .{ .id = self.cards[i].id, .zone = self.zone, .rect = rect } };
            }
        }
        return null;
    }

    /// Rendering takes ViewState for drag/hover effects
    pub fn appendRenderables(
        self: CardZoneView,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        last: *?Renderable,
    ) !void {
        const ui = vs.combat orelse CombatUIState{};

        for (self.cards, 0..) |card, i| {
            // Skip cards that are being animated (they're rendered separately)
            if (ui.isAnimating(card.id)) continue;

            const rect = self.cardRect(i, card.id, vs);
            const state = self.cardInteractionState(card.id, ui);
            const card_vm = CardViewModel.fromTemplate(card.id, card.template, .{
                .target = state == .target,
                .played = (self.zone == .in_play),
                .disabled = (!card.playable and self.zone != .in_play),
                .highlighted = state == .hover,
                .warning = (card.playable and !card.has_valid_targets and self.zone != .in_play),
            });
            const item: Renderable = .{ .card = .{ .model = card_vm, .dst = rect } };
            if (state == .normal or state == .target) {
                try list.append(alloc, item);
            } else {
                last.* = item; // render last for z-order
            }
        }
    }

    /// Card rect with drag offset applied if this card is being dragged
    pub fn cardRect(self: CardZoneView, index: usize, card_id: entity.ID, vs: ViewState) Rect {
        const base_x = self.layout.start_x + @as(f32, @floatFromInt(index)) * self.layout.spacing;
        const base_y = self.layout.y;

        const pad: f32 = 3;

        const normal: Rect = .{
            .x = base_x,
            .y = base_y,
            .w = self.layout.w,
            .h = self.layout.h,
        };

        const ui = vs.combat orelse return normal;

        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) {
                return .{
                    .x = vs.mouse_vp.x - pad - (drag.original_pos.x - base_x),
                    .y = vs.mouse_vp.y - pad - (drag.original_pos.y - base_y),
                    .w = self.layout.w + pad,
                    .h = self.layout.h + pad,
                };
            }
        }

        // Check for hover state (slight expansion)
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) {
                return .{
                    .x = base_x - pad,
                    .y = base_y - pad,
                    .w = self.layout.w + pad * 2,
                    .h = self.layout.h + pad * 2,
                };
            },
            else => {},
        }

        return normal;
    }

    pub fn cardInteractionState(self: CardZoneView, card_id: entity.ID, ui: CombatUIState) CardViewState {
        _ = self;
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
};
