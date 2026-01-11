// Avatar components for combat view
//
// Player avatar, enemy sprites, and opposition group.
// Access as: combat.avatar.Player, combat.avatar.Enemy, combat.avatar.Opposition

const std = @import("std");
const view = @import("../view.zig");
const infra = @import("infra");
const combat = @import("../../../domain/combat.zig");
const conditions_mod = @import("conditions.zig");

const entity = infra.entity;
const Renderable = view.Renderable;
const types = view.types;
const AssetId = view.AssetId;
const Point = view.Point;
const Rect = view.Rect;
const Color = view.Color;

pub const Player = struct {
    rect: Rect,
    asset_id: AssetId,

    pub fn init() Player {
        return Player{
            .rect = Rect{
                .x = 200,
                .y = 50,
                .w = 48,
                .h = 48,
            },
            .asset_id = AssetId.player_halberdier,
        };
    }

    pub fn hitTest(self: *const Player, pt: Point) bool {
        return self.rect.pointIn(pt);
    }

    pub fn renderable(self: *const Player) Renderable {
        return .{ .sprite = .{
            .asset = self.asset_id,
            .dst = self.rect,
        } };
    }
};

pub const Enemy = struct {
    index: usize,
    id: entity.ID,
    rect: Rect,
    asset_id: AssetId,

    pub fn init(id: entity.ID, index: usize) Enemy {
        return Enemy{
            .rect = Rect{
                .x = 300 + 60 * @as(f32, @floatFromInt(index)),
                .y = 50,
                .w = 48,
                .h = 48,
            },
            .asset_id = AssetId.eye_dragon,
            .id = id,
            .index = index,
        };
    }

    pub fn hitTest(self: *const Enemy, pt: Point) bool {
        return self.rect.pointIn(pt);
    }

    pub fn renderable(self: *const Enemy) Renderable {
        return .{ .sprite = .{
            .asset = self.asset_id,
            .dst = self.rect,
        } };
    }
};

pub const Opposition = struct {
    enemies: []*combat.Agent,

    pub fn init(agents: []*combat.Agent) Opposition {
        return Opposition{
            .enemies = agents,
        };
    }

    pub fn hitTest(self: *const Opposition, pt: Point) ?Enemy {
        for (self.enemies, 0..) |e, i| {
            const sprite = Enemy.init(e.id, i);
            if (sprite.hitTest(pt)) {
                return sprite;
            }
        }
        return null;
    }

    pub fn appendRenderables(
        self: *const Opposition,
        alloc: std.mem.Allocator,
        list: *std.ArrayList(Renderable),
        encounter: ?*const combat.Encounter,
        primary_target: ?entity.ID,
        focused_enemy: ?entity.ID,
    ) !void {
        for (self.enemies, 0..) |e, i| {
            const sprite = Enemy.init(e.id, i);

            // Focused enemy border (cyan) - draw before sprite
            const is_focused = if (focused_enemy) |fe| fe.eql(e.id) else false;
            if (is_focused) {
                const border: f32 = 4;
                // Outer cyan rect
                try list.append(alloc, .{
                    .filled_rect = .{
                        .rect = .{
                            .x = sprite.rect.x - border,
                            .y = sprite.rect.y - border,
                            .w = sprite.rect.w + border * 2,
                            .h = sprite.rect.h + border * 2,
                        },
                        .color = .{ .r = 50, .g = 200, .b = 220, .a = 255 }, // cyan
                    },
                });
                // Inner black rect (creates border effect)
                try list.append(alloc, .{
                    .filled_rect = .{
                        .rect = sprite.rect,
                        .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
                    },
                });
            }

            try list.append(alloc, sprite.renderable());

            // Incapacitated overlay - skull
            if (conditions_mod.isIncapacitated(e)) {
                try appendIncapacitatedOverlay(alloc, list, sprite.rect);
            }

            // Engagement bars, label, and conditions
            if (encounter) |enc| {
                const is_primary = if (primary_target) |pt| pt.eql(e.id) else false;
                const blood_ratio = e.blood.current / e.blood.max;
                const engagement = enc.getPlayerEngagementConst(e.id);
                try appendEngagementInfo(alloc, list, sprite.rect, engagement, e.balance, blood_ratio, is_primary);
                try appendConditions(alloc, list, sprite.rect, e, engagement);
            }
        }
    }

    /// Render incapacitated overlay - skull sprite centered on mob
    fn appendIncapacitatedOverlay(
        alloc: std.mem.Allocator,
        list: *std.ArrayList(Renderable),
        sprite_rect: Rect,
    ) !void {
        // Semi-transparent dark background
        try list.append(alloc, .{ .filled_rect = .{
            .rect = sprite_rect,
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 180 },
        } });
        // Skull sprite centered on mob (48x48)
        const skull_size: f32 = 48;
        const center_x = sprite_rect.x + sprite_rect.w / 2;
        const center_y = sprite_rect.y + sprite_rect.h / 2;
        try list.append(alloc, .{ .sprite = .{
            .asset = .skull,
            .dst = .{
                .x = center_x - skull_size / 2,
                .y = center_y - skull_size / 2,
                .w = skull_size,
                .h = skull_size,
            },
        } });
    }

    /// Render compact condition chips below engagement info
    fn appendConditions(
        alloc: std.mem.Allocator,
        list: *std.ArrayList(Renderable),
        sprite_rect: Rect,
        agent: *const combat.Agent,
        engagement: ?combat.Engagement,
    ) !void {
        const conds = conditions_mod.getDisplayConditions(agent, engagement);
        if (conds.len == 0) return;

        // Position below engagement info (5 bars + range label + breathing room)
        const bar_start_y = sprite_rect.y + sprite_rect.h + 2;
        const conditions_start_y = bar_start_y + 38;
        const line_height: f32 = 14; // 12px text + 2px gap

        // Show up to 3 conditions to avoid clutter
        const max_display = @min(conds.len, 3);
        for (conds.constSlice()[0..max_display], 0..) |cond, idx| {
            try list.append(alloc, .{ .text = .{
                .content = cond.label,
                .pos = .{
                    .x = sprite_rect.x,
                    .y = conditions_start_y + @as(f32, @floatFromInt(idx)) * line_height,
                },
                .font_size = .small,
                .color = cond.color,
            } });
        }
    }

    /// Render engagement bars (pressure, control, position) and range label
    fn appendEngagementInfo(
        alloc: std.mem.Allocator,
        list: *std.ArrayList(Renderable),
        sprite_rect: Rect,
        engagement: ?combat.Engagement,
        balance: f32,
        blood_ratio: f32,
        is_primary: bool,
    ) !void {
        const bar_height: f32 = 2;
        const bar_width: f32 = sprite_rect.w;
        const bar_gap: f32 = 1;
        const bar_start_y = sprite_rect.y + sprite_rect.h + 2;

        const eng = engagement orelse combat.Engagement{};

        // Bar colors: pressure=red, control=blue, position=green, balance=yellow, blood=dark red
        const bars = [_]struct { value: f32, color: Color }{
            .{ .value = eng.pressure, .color = .{ .r = 180, .g = 60, .b = 60, .a = 255 } },
            .{ .value = eng.control, .color = .{ .r = 60, .g = 60, .b = 180, .a = 255 } },
            .{ .value = eng.position, .color = .{ .r = 60, .g = 140, .b = 60, .a = 255 } },
            .{ .value = balance, .color = .{ .r = 180, .g = 160, .b = 40, .a = 255 } },
            .{ .value = blood_ratio, .color = .{ .r = 140, .g = 20, .b = 20, .a = 255 } },
        };

        for (bars, 0..) |bar, idx| {
            const y = bar_start_y + @as(f32, @floatFromInt(idx)) * (bar_height + bar_gap);
            // Background (dark)
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{ .x = sprite_rect.x, .y = y, .w = bar_width, .h = bar_height },
                .color = .{ .r = 30, .g = 30, .b = 30, .a = 255 },
            } });
            // Foreground (value)
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{ .x = sprite_rect.x, .y = y, .w = bar_width * bar.value, .h = bar_height },
                .color = bar.color,
            } });
        }

        // Range label below bars
        const label_y = bar_start_y + 5 * (bar_height + bar_gap) + 2;
        const range_str = @tagName(eng.range);
        const prefix: []const u8 = if (is_primary) "* " else "";

        // Concatenate prefix + range (using arena allocator)
        const label = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, range_str });
        try list.append(alloc, .{ .text = .{
            .content = label,
            .pos = .{ .x = sprite_rect.x, .y = label_y },
            .color = if (is_primary)
                Color{ .r = 255, .g = 220, .b = 100, .a = 255 }
            else
                Color{ .r = 160, .g = 160, .b = 160, .a = 255 },
        } });
    }
};
