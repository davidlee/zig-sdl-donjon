// Play view types for combat commit phase
//
// PlayViewData: committed play with context
// Zone: renders plays as solitaire-style vertical stacks
// Access as: play.Data, play.Zone

const std = @import("std");
const entity = @import("infra").entity;
const combat = @import("../../../domain/combat.zig");
const domain_cards = @import("../../../domain/cards.zig");
const types = @import("../types.zig");
const card_mod = @import("../card/mod.zig");
const hit_mod = @import("hit.zig");

const CardViewData = card_mod.Data;
const CardLayout = card_mod.Layout;
const CardViewModel = card_mod.Model;
const ViewZone = hit_mod.Zone;
const HitResult = hit_mod.Hit;
const Renderable = types.Renderable;
const ViewState = types.ViewState;
const CombatUIState = types.CombatUIState;
const Point = types.Point;
const Rect = types.Rect;

/// Committed play with context (for commit phase and resolution).
pub const Data = struct {
    pub const max_modifiers = combat.Play.max_modifiers;

    // Ownership
    owner_id: entity.ID,
    owner_is_player: bool,

    // Cards in the play
    action: CardViewData,
    modifier_stack_buf: [max_modifiers]CardViewData = undefined,
    modifier_stack_len: u4 = 0,
    stakes: domain_cards.Stakes,

    // Targeting (if offensive)
    target_id: ?entity.ID = null,

    pub fn modifiers(self: *const Data) []const CardViewData {
        return self.modifier_stack_buf[0..self.modifier_stack_len];
    }

    /// Total cards in play (action + modifiers)
    pub fn cardCount(self: *const Data) usize {
        return 1 + self.modifier_stack_len;
    }

    /// Is this an offensive play?
    pub fn isOffensive(self: *const Data) bool {
        return self.action.template.tags.offensive;
    }
};

/// View over plays during commit phase (action + modifier stacks).
/// Renders plays as solitaire-style vertical stacks.
pub const Zone = struct {
    const modifier_y_offset: f32 = 25; // vertical offset per stacked modifier

    plays: []const Data,
    layout: CardLayout,

    pub fn init(layout: CardLayout, play_data: []const Data) Zone {
        return .{ .plays = play_data, .layout = layout };
    }

    /// Hit test returns HitResult with card-level detail
    pub fn hitTest(self: Zone, vs: ViewState, pt: Point) ?HitResult {
        _ = vs;
        // Reverse order so rightmost (last rendered) play is hit first
        var i = self.plays.len;
        while (i > 0) {
            i -= 1;
            const play = self.plays[i];

            // Check modifiers first (topmost in z-order, stacked above action)
            var m: usize = play.modifier_stack_len;
            while (m > 0) {
                m -= 1;
                const mod_rect = self.modifierRect(i, m);
                if (mod_rect.pointIn(pt)) {
                    return .{ .play = .{
                        .play_index = i,
                        .card_id = play.modifier_stack_buf[m].id,
                        .slot = .{ .modifier = @intCast(m) },
                    } };
                }
            }

            // Check action card (at base position)
            const action_rect = self.actionRect(i);
            if (action_rect.pointIn(pt)) {
                return .{ .play = .{
                    .play_index = i,
                    .card_id = play.action.id,
                    .slot = .action,
                } };
            }
        }
        return null;
    }

    /// Hit test returning only play index (for drop targeting)
    pub fn hitTestPlay(self: Zone, vs: ViewState, pt: Point) ?usize {
        if (self.hitTest(vs, pt)) |result| {
            return switch (result) {
                .play => |p| p.play_index,
                .card => null,
            };
        }
        return null;
    }

    /// Compute rect for entire play stack (action + modifiers)
    pub fn playRect(self: Zone, index: usize) Rect {
        const play = self.plays[index];
        const base_x = self.layout.start_x + @as(f32, @floatFromInt(index)) * self.layout.spacing;
        const stack_height = self.layout.h + @as(f32, @floatFromInt(play.modifier_stack_len)) * modifier_y_offset;
        const top_y = self.layout.y - @as(f32, @floatFromInt(play.modifier_stack_len)) * modifier_y_offset;
        return Rect{
            .x = base_x,
            .y = top_y,
            .w = self.layout.w,
            .h = stack_height,
        };
    }

    /// Compute rect for the action card within a play
    pub fn actionRect(self: Zone, index: usize) Rect {
        const base_x = self.layout.start_x + @as(f32, @floatFromInt(index)) * self.layout.spacing;
        return Rect{
            .x = base_x,
            .y = self.layout.y,
            .w = self.layout.w,
            .h = self.layout.h,
        };
    }

    /// Compute rect for a modifier card within a play (stacked above action)
    pub fn modifierRect(self: Zone, play_index: usize, mod_index: usize) Rect {
        const base_x = self.layout.start_x + @as(f32, @floatFromInt(play_index)) * self.layout.spacing;
        const offset_y = @as(f32, @floatFromInt(mod_index + 1)) * modifier_y_offset;
        return Rect{
            .x = base_x,
            .y = self.layout.y - offset_y,
            .w = self.layout.w,
            .h = self.layout.h,
        };
    }

    /// Generate renderables for all plays
    pub fn appendRenderables(
        self: Zone,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        last: *?Renderable,
    ) !void {
        for (self.plays, 0..) |play, i| {
            try self.appendPlayRenderables(alloc, vs, list, play, i, last);
        }
    }

    fn appendPlayRenderables(
        self: Zone,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        play: Data,
        play_index: usize,
        last: *?Renderable,
    ) !void {
        const ui = vs.combat orelse CombatUIState{};

        const is_drop_target = if (ui.drag) |drag|
            drag.target_play_index == play_index
        else
            false;

        const hover_id: ?entity.ID = switch (ui.hover) {
            .card => |id| id,
            else => null,
        };

        // Render modifiers first (behind, top to bottom)
        var j: usize = play.modifier_stack_len;
        while (j > 0) {
            j -= 1;
            const mod = play.modifier_stack_buf[j];
            const is_hovered = if (hover_id) |hid| hid.eql(mod.id) else false;
            const rect = cardRectWithHover(self.modifierRect(play_index, j), is_hovered);
            const mod_vm = CardViewModel.fromTemplate(mod.id, mod.template, .{
                .target = is_drop_target,
                .played = true,
                .highlighted = is_hovered,
            });
            const item: Renderable = .{ .card = .{ .model = mod_vm, .dst = rect } };
            if (is_hovered) {
                last.* = item;
            } else {
                try list.append(alloc, item);
            }
        }

        // Render action card (in front, at base position)
        const is_action_hovered = if (hover_id) |hid| hid.eql(play.action.id) else false;
        const action_rect = cardRectWithHover(self.actionRect(play_index), is_action_hovered);
        const action_vm = CardViewModel.fromTemplate(play.action.id, play.action.template, .{
            .target = is_drop_target,
            .played = true,
            .highlighted = is_action_hovered,
        });
        const action_item: Renderable = .{ .card = .{ .model = action_vm, .dst = action_rect } };
        if (is_action_hovered) {
            last.* = action_item;
        } else {
            try list.append(alloc, action_item);
        }
    }
};

/// Apply hover expansion to a rect
fn cardRectWithHover(base: Rect, is_hovered: bool) Rect {
    if (!is_hovered) return base;
    const pad: f32 = 3;
    return .{
        .x = base.x - pad,
        .y = base.y - pad,
        .w = base.w + pad * 2,
        .h = base.h + pad * 2,
    };
}
