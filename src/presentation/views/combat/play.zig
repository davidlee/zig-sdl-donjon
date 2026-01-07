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
const Color = types.Color;

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

    // Timeline position (Phase 0: direct from domain)
    time_start: f32 = 0,
    time_end: f32 = 0,
    channels: domain_cards.ChannelSet = .{},

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

    /// Channel index for timeline positioning (0=weapon, 1=off_hand, 2=footwork).
    /// Returns primary channel, or midpoint for multi-channel plays.
    pub fn channelY(self: *const Data) f32 {
        const c = self.channels;
        var sum: f32 = 0;
        var count: f32 = 0;
        if (c.weapon) {
            sum += 0;
            count += 1;
        }
        if (c.off_hand) {
            sum += 1;
            count += 1;
        }
        if (c.footwork) {
            sum += 2;
            count += 1;
        }
        // concentration ignored for now (no cards use it)
        return if (count > 0) sum / count else 0;
    }

    /// Height in channel lanes (1 for single, 2 for adjacent pair, 3 for all).
    pub fn channelSpan(self: *const Data) f32 {
        const c = self.channels;
        var min_idx: f32 = 3;
        var max_idx: f32 = 0;
        if (c.weapon) {
            min_idx = @min(min_idx, 0);
            max_idx = @max(max_idx, 0);
        }
        if (c.off_hand) {
            min_idx = @min(min_idx, 1);
            max_idx = @max(max_idx, 1);
        }
        if (c.footwork) {
            min_idx = @min(min_idx, 2);
            max_idx = @max(max_idx, 2);
        }
        return if (min_idx <= max_idx) max_idx - min_idx + 1 else 1;
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

/// Timeline view: renders plays positioned by channel × time.
/// Phase 0 prototype - channel lanes with time grid.
pub const TimelineView = struct {
    // Layout constants
    const slot_width: f32 = 100; // 100px per 0.1s slot
    const lane_height: f32 = 110; // card height per channel
    const num_slots: usize = 10; // 0.0-1.0 in 0.1 increments
    const num_lanes: usize = 3; // weapon, off_hand, footwork
    const timeline_width: f32 = slot_width * num_slots;
    const timeline_height: f32 = lane_height * num_lanes;
    const start_x: f32 = 60; // left margin for labels
    const start_y: f32 = 120; // below header area
    const label_width: f32 = 70; // right-side channel labels
    const grid_color = Color{ .r = 40, .g = 40, .b = 40, .a = 255 };
    const lane_colors = [_]Color{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 }, // black
        .{ .r = 10, .g = 10, .b = 10, .a = 255 }, // dark grey
        .{ .r = 0, .g = 0, .b = 0, .a = 255 }, // black
    };
    const lane_labels = [_][]const u8{ "weapon", "off_hand", "footwork" };

    plays: []const Data,

    pub fn init(play_data: []const Data) TimelineView {
        return .{ .plays = play_data };
    }

    /// Compute duration bar rect (shows occupied time slots)
    fn durationRect(play: *const Data) Rect {
        const inset: f32 = 4;
        const time_x = start_x + play.time_start * (slot_width / 0.1);
        const duration = play.time_end - play.time_start;
        const width = duration * (slot_width / 0.1);

        // Vertical position based on channel(s)
        const channel_y = play.channelY();
        const span = play.channelSpan();
        const y = start_y + channel_y * lane_height;
        const h = span * lane_height;

        return .{
            .x = time_x + inset,
            .y = y + inset,
            .w = width - inset * 2,
            .h = h - inset * 2,
        };
    }

    /// Compute card rect (normal size, positioned at start of duration)
    fn cardRect(play: *const Data) Rect {
        const dims = CardLayout.defaultDimensions();
        const time_x = start_x + play.time_start * (slot_width / 0.1);

        // Vertical position based on channel(s)
        const channel_y = play.channelY();
        const span = play.channelSpan();
        const y = start_y + channel_y * lane_height;
        const h = span * lane_height;

        // Card centered vertically within the span
        const card_y = y + (h - dims.h) / 2;

        return .{
            .x = time_x,
            .y = card_y,
            .w = dims.w,
            .h = dims.h,
        };
    }

    /// Hit test for timeline plays (hit test against card rect)
    pub fn hitTest(self: TimelineView, vs: ViewState, pt: Point) ?HitResult {
        _ = vs;
        // Reverse order for z-order (later plays rendered on top)
        var i = self.plays.len;
        while (i > 0) {
            i -= 1;
            const play = &self.plays[i];
            const rect = cardRect(play);
            if (rect.pointIn(pt)) {
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
    pub fn hitTestPlay(self: TimelineView, vs: ViewState, pt: Point) ?usize {
        if (self.hitTest(vs, pt)) |result| {
            return switch (result) {
                .play => |p| p.play_index,
                .card => null,
            };
        }
        return null;
    }

    /// Generate renderables for timeline grid and plays
    pub fn appendRenderables(
        self: TimelineView,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        last: *?Renderable,
    ) !void {
        // Lane backgrounds
        for (0..num_lanes) |lane| {
            const y = start_y + @as(f32, @floatFromInt(lane)) * lane_height;
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{ .x = start_x, .y = y, .w = timeline_width, .h = lane_height },
                .color = lane_colors[lane],
            } });
        }

        // Vertical grid lines (time markers)
        for (0..num_slots + 1) |slot| {
            const x = start_x + @as(f32, @floatFromInt(slot)) * slot_width;
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{ .x = x, .y = start_y, .w = 1, .h = timeline_height },
                .color = grid_color,
            } });
        }

        // Horizontal grid lines (lane separators)
        for (0..num_lanes + 1) |lane| {
            const y = start_y + @as(f32, @floatFromInt(lane)) * lane_height;
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{ .x = start_x, .y = y, .w = timeline_width, .h = 1 },
                .color = grid_color,
            } });
        }

        // Channel labels (right side)
        for (lane_labels, 0..) |label, lane| {
            const y = start_y + @as(f32, @floatFromInt(lane)) * lane_height + lane_height / 2 - 8;
            try list.append(alloc, .{ .text = .{
                .content = label,
                .pos = .{ .x = start_x + timeline_width + 5, .y = y },
                .color = .{ .r = 180, .g = 180, .b = 180, .a = 255 },
            } });
        }

        // Time labels (top) - skip for now, needs arena-allocated strings
        // TODO: add time markers once we have a way to format strings

        // Render plays: duration bars first (behind), then cards (in front)
        const ui = vs.combat orelse CombatUIState{};
        const hover_id: ?entity.ID = switch (ui.hover) {
            .card => |id| id,
            else => null,
        };

        const duration_bar_color = Color{ .r = 30, .g = 50, .b = 80, .a = 255 }; // dark blue

        // First pass: duration bars
        for (self.plays) |play| {
            try list.append(alloc, .{ .filled_rect = .{
                .rect = durationRect(&play),
                .color = duration_bar_color,
            } });
        }

        // Second pass: cards
        for (self.plays, 0..) |play, i| {
            const is_drop_target = if (ui.drag) |drag|
                drag.target_play_index == i
            else
                false;

            const is_hovered = if (hover_id) |hid| hid.eql(play.action.id) else false;
            const rect = cardRectWithHover(cardRect(&play), is_hovered);

            const card_vm = CardViewModel.fromTemplate(play.action.id, play.action.template, .{
                .target = is_drop_target,
                .played = true,
                .highlighted = is_hovered,
            });

            const item: Renderable = .{ .card = .{ .model = card_vm, .dst = rect } };
            if (is_hovered) {
                last.* = item;
            } else {
                try list.append(alloc, item);
            }
        }
    }
};
