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
        if (c.concentration) {
            sum += 3;
            count += 1;
        }
        return if (count > 0) sum / count else 0;
    }

    /// Height in channel lanes (1 for single, 2 for adjacent pair, 3 for all).
    pub fn channelSpan(self: *const Data) f32 {
        const c = self.channels;
        var min_idx: f32 = 4;
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
        if (c.concentration) {
            min_idx = @min(min_idx, 3);
            max_idx = @max(max_idx, 3);
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

// Shared timeline axis constants (used by both player and enemy views)
pub const timeline_axis = struct {
    pub const start_x: f32 = 60; // left margin for labels
    pub const slot_width: f32 = 80; // pixels per 0.1s slot
    pub const num_slots: usize = 10; // 0.0-1.0 in 0.1 increments
    pub const width: f32 = slot_width * num_slots;

    /// Convert time (0.0-1.0) to X position
    pub fn timeToX(t: f32) f32 {
        return start_x + t * (slot_width / 0.1);
    }

    /// Convert X position to time (0.0-1.0), clamped and snapped to 0.1 increments
    pub fn xToTime(x: f32) f32 {
        const raw_time = (x - start_x) / (slot_width / 0.1);
        const clamped = @max(0.0, @min(1.0, raw_time));
        // Snap to 0.1 increments (floor so cursor must be past slot start)
        return @floor(clamped * 10.0) / 10.0;
    }
};

/// Timeline view: renders plays positioned by channel × time.
/// Phase 0 prototype - channel lanes with time grid.
pub const TimelineView = struct {
    // Layout constants (Y-axis specific to player view)
    const lane_height: f32 = 110; // card height per channel
    const num_lanes: usize = 4; // weapon, off_hand, footwork, concentration
    const timeline_height: f32 = lane_height * num_lanes;
    pub const start_y: f32 = 340; // below header area
    const label_width: f32 = 50; // right-side channel labels

    // Re-export shared constants for internal use
    const start_x = timeline_axis.start_x;
    const slot_width = timeline_axis.slot_width;
    const num_slots = timeline_axis.num_slots;
    const timeline_width = timeline_axis.width;
    const grid_color = Color{ .r = 40, .g = 40, .b = 40, .a = 255 };
    const lane_colors = [_]Color{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 }, // black
        .{ .r = 10, .g = 10, .b = 10, .a = 255 }, // dark grey
        .{ .r = 0, .g = 0, .b = 0, .a = 255 }, // black
        .{ .r = 10, .g = 10, .b = 10, .a = 255 }, // dark grey
    };
    const lane_labels = [_][]const u8{ "weapon", "off_hand", "footwork", "conc" };

    plays: []const Data,

    pub fn init(play_data: []const Data) TimelineView {
        return .{ .plays = play_data };
    }

    /// Result of timeline position hit test
    pub const DropPosition = struct {
        time: f32, // 0.0-1.0, snapped to 0.1
        channel: domain_cards.ChannelSet,
    };

    /// Convert Y position to lane index (0-3), or null if outside timeline
    pub fn yToLane(y: f32) ?usize {
        if (y < start_y or y >= start_y + timeline_height) return null;
        const lane_f = (y - start_y) / lane_height;
        const lane = @as(usize, @intFromFloat(lane_f));
        return if (lane < num_lanes) lane else null;
    }

    /// Convert lane index to ChannelSet
    pub fn laneToChannel(lane: usize) domain_cards.ChannelSet {
        return switch (lane) {
            0 => .{ .weapon = true },
            1 => .{ .off_hand = true },
            2 => .{ .footwork = true },
            3 => .{ .concentration = true },
            else => .{}, // empty for invalid lane
        };
    }

    /// Hit test for drop position: returns (time, channel) if point is within timeline area
    pub fn hitTestDrop(pt: Point) ?DropPosition {
        // Check if within timeline bounds
        if (pt.x < start_x or pt.x > start_x + timeline_width) return null;
        const lane = yToLane(pt.y) orelse return null;

        return .{
            .time = timeline_axis.xToTime(pt.x),
            .channel = laneToChannel(lane),
        };
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
    pub fn cardRect(play: *const Data) Rect {
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
        _ = vs;
        // Use durationRect for larger drop target area
        var i = self.plays.len;
        while (i > 0) {
            i -= 1;
            const play = &self.plays[i];
            if (durationRect(play).pointIn(pt)) {
                return i;
            }
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

        // First pass: duration bars (skip animating cards)
        // For dragged play, show at target position instead of current
        for (self.plays) |play| {
            if (ui.isAnimating(play.action.id)) continue;

            const is_being_dragged = if (ui.drag) |drag|
                drag.id.eql(play.action.id) and drag.target_time != null
            else
                false;

            const rect = if (is_being_dragged) blk: {
                // Render at target position
                const target_time = ui.drag.?.target_time.?;
                const duration = play.time_end - play.time_start;
                const inset: f32 = 4;
                const time_x = start_x + target_time * (slot_width / 0.1);
                const channel_y = play.channelY();
                const span = play.channelSpan();
                const y = start_y + channel_y * lane_height;
                const h = span * lane_height;
                break :blk Rect{
                    .x = time_x + inset,
                    .y = y + inset,
                    .w = duration * (slot_width / 0.1) - inset * 2,
                    .h = h - inset * 2,
                };
            } else durationRect(&play);

            try list.append(alloc, .{ .filled_rect = .{
                .rect = rect,
                .color = duration_bar_color,
            } });
        }

        // Second pass: cards (skip animating and dragged cards)
        for (self.plays, 0..) |play, i| {
            if (ui.isAnimating(play.action.id)) continue;

            // Skip card being dragged - it's rendered following cursor
            const is_being_dragged = if (ui.drag) |drag|
                drag.id.eql(play.action.id)
            else
                false;
            if (is_being_dragged) continue;

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

        // Third pass: modifier decals (rune icons on cards)
        const decal_size: f32 = 24; // scaled down from 48x48
        const decal_spacing: f32 = 4;
        for (self.plays) |play| {
            if (ui.isAnimating(play.action.id)) continue;
            // Skip dragged card
            const is_being_dragged = if (ui.drag) |drag| drag.id.eql(play.action.id) else false;
            if (is_being_dragged) continue;
            const mods = play.modifiers();
            if (mods.len == 0) continue;

            const card_rect = cardRect(&play);
            // Position decals in bottom-right corner, stacking upward
            var decal_y = card_rect.y + card_rect.h - decal_size - 4;
            const decal_x = card_rect.x + card_rect.w - decal_size - 4;

            for (mods) |mod| {
                if (CardViewModel.mapIcon(mod.template.icon)) |asset_id| {
                    try list.append(alloc, .{ .sprite = .{
                        .asset = asset_id,
                        .dst = .{
                            .x = decal_x,
                            .y = decal_y,
                            .w = decal_size,
                            .h = decal_size,
                        },
                    } });
                    decal_y -= decal_size + decal_spacing;
                }
            }
        }
    }
};

/// Channel colors for timeline capsules
pub const channel_colors = struct {
    pub const weapon = Color{ .r = 180, .g = 80, .b = 60, .a = 255 }; // red-orange
    pub const off_hand = Color{ .r = 60, .g = 100, .b = 180, .a = 255 }; // blue
    pub const footwork = Color{ .r = 60, .g = 160, .b = 80, .a = 255 }; // green
    pub const concentration = Color{ .r = 140, .g = 80, .b = 180, .a = 255 }; // purple

    pub fn forChannels(channels: domain_cards.ChannelSet) Color {
        // Priority: weapon > off_hand > footwork > concentration
        if (channels.weapon) return weapon;
        if (channels.off_hand) return off_hand;
        if (channels.footwork) return footwork;
        if (channels.concentration) return concentration;
        return Color{ .r = 100, .g = 100, .b = 100, .a = 255 }; // grey fallback
    }
};

/// Compact enemy timeline strip: single row of capsules above player timeline.
/// Shares X-axis with TimelineView for visual alignment.
pub const EnemyTimelineStrip = struct {
    const axis = timeline_axis;

    // Layout constants
    const row_height: f32 = 35;
    const capsule_height: f32 = 28;
    const capsule_inset: f32 = 3;
    const header_height: f32 = 20;
    const arrow_width: f32 = 20;

    // Positioned above player timeline
    pub const start_y: f32 = TimelineView.start_y - row_height - header_height - 10;

    plays: []const Data,
    enemy_name: []const u8,
    enemy_index: usize,
    enemy_count: usize,

    pub fn init(
        play_data: []const Data,
        enemy_name: []const u8,
        enemy_index: usize,
        enemy_count: usize,
    ) EnemyTimelineStrip {
        return .{
            .plays = play_data,
            .enemy_name = enemy_name,
            .enemy_index = enemy_index,
            .enemy_count = enemy_count,
        };
    }

    /// Compute capsule rect for a play (horizontal bar showing time span)
    fn capsuleRect(play: *const Data) Rect {
        const x = axis.timeToX(play.time_start);
        const duration = play.time_end - play.time_start;
        const w = duration * (axis.slot_width / 0.1);
        return .{
            .x = x + capsule_inset,
            .y = start_y + header_height + capsule_inset,
            .w = @max(w - capsule_inset * 2, 30), // minimum width for visibility
            .h = capsule_height,
        };
    }

    /// Generate renderables for enemy timeline strip
    pub fn appendRenderables(
        self: EnemyTimelineStrip,
        alloc: std.mem.Allocator,
        list: *std.ArrayList(Renderable),
    ) !void {
        // Background strip
        try list.append(alloc, .{ .filled_rect = .{
            .rect = .{
                .x = axis.start_x,
                .y = start_y + header_height,
                .w = axis.width,
                .h = row_height,
            },
            .color = .{ .r = 20, .g = 20, .b = 25, .a = 255 },
        } });

        // Header: ◄ Name ►
        const header_y = start_y;
        const center_x = axis.start_x + axis.width / 2;

        // Left arrow (if multiple enemies)
        if (self.enemy_count > 1) {
            try list.append(alloc, .{ .text = .{
                .content = "<",
                .pos = .{ .x = center_x - 60, .y = header_y },
                .color = .{ .r = 180, .g = 180, .b = 180, .a = 255 },
            } });
        }

        // Enemy name (centered)
        try list.append(alloc, .{
            .text = .{
                .content = self.enemy_name,
                .pos = .{ .x = center_x - 30, .y = header_y }, // approximate centering
                .color = .{ .r = 220, .g = 220, .b = 220, .a = 255 },
            },
        });

        // Right arrow (if multiple enemies)
        if (self.enemy_count > 1) {
            try list.append(alloc, .{ .text = .{
                .content = ">",
                .pos = .{ .x = center_x + 50, .y = header_y },
                .color = .{ .r = 180, .g = 180, .b = 180, .a = 255 },
            } });
        }

        // Render capsules for each play
        for (self.plays) |play| {
            const rect = capsuleRect(&play);
            const color = channel_colors.forChannels(play.channels);

            // Capsule background
            try list.append(alloc, .{ .filled_rect = .{
                .rect = rect,
                .color = color,
            } });

            // Card name (truncated to fit)
            const name = play.action.template.name;
            try list.append(alloc, .{ .text = .{
                .content = name,
                .pos = .{ .x = rect.x + 4, .y = rect.y + 6 },
                .font_size = .small,
                .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            } });
        }

        // Vertical grid lines (aligned with player timeline)
        const grid_color = Color{ .r = 50, .g = 50, .b = 55, .a = 255 };
        for (0..axis.num_slots + 1) |slot| {
            const x = axis.start_x + @as(f32, @floatFromInt(slot)) * axis.slot_width;
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{
                    .x = x,
                    .y = start_y + header_height,
                    .w = 1,
                    .h = row_height,
                },
                .color = grid_color,
            } });
        }
    }

    /// Hit test for nav arrows. Returns -1 for left, 1 for right, null for no hit.
    pub fn hitTestNav(self: EnemyTimelineStrip, pt: Point) ?i8 {
        if (self.enemy_count <= 1) return null;

        const header_y = start_y;
        const center_x = axis.start_x + axis.width / 2;

        // Left arrow region
        const left_rect = Rect{
            .x = center_x - 70,
            .y = header_y - 5,
            .w = arrow_width,
            .h = header_height + 10,
        };
        if (left_rect.pointIn(pt)) return -1;

        // Right arrow region
        const right_rect = Rect{
            .x = center_x + 40,
            .y = header_y - 5,
            .w = arrow_width,
            .h = header_height + 10,
        };
        if (right_rect.pointIn(pt)) return 1;

        return null;
    }
};
