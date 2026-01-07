// Avatar components for combat view
//
// Player avatar, enemy sprites, and opposition group.
// Access as: combat.avatar.Player, combat.avatar.Enemy, combat.avatar.Opposition

const std = @import("std");
const view = @import("../view.zig");
const infra = @import("infra");
const combat = @import("../../../domain/combat.zig");

const entity = infra.entity;
const Renderable = view.Renderable;
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
            .asset_id = AssetId.thief,
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
    ) !void {
        for (self.enemies, 0..) |e, i| {
            const sprite = Enemy.init(e.id, i);
            try list.append(alloc, sprite.renderable());

            // Engagement bars and label
            if (encounter) |enc| {
                const is_primary = if (primary_target) |pt| pt.eql(e.id) else false;
                try appendEngagementInfo(alloc, list, sprite.rect, enc.getPlayerEngagementConst(e.id), e.balance, is_primary);
            }
        }
    }

    /// Render engagement bars (pressure, control, position) and range label
    fn appendEngagementInfo(
        alloc: std.mem.Allocator,
        list: *std.ArrayList(Renderable),
        sprite_rect: Rect,
        engagement: ?combat.Engagement,
        balance: f32,
        is_primary: bool,
    ) !void {
        const bar_height: f32 = 2;
        const bar_width: f32 = sprite_rect.w;
        const bar_gap: f32 = 1;
        const bar_start_y = sprite_rect.y + sprite_rect.h + 2;

        const eng = engagement orelse combat.Engagement{};

        // Bar colors: pressure=red, control=blue, position=green, balance=yellow
        const bars = [_]struct { value: f32, color: Color }{
            .{ .value = eng.pressure, .color = .{ .r = 180, .g = 60, .b = 60, .a = 255 } },
            .{ .value = eng.control, .color = .{ .r = 60, .g = 60, .b = 180, .a = 255 } },
            .{ .value = eng.position, .color = .{ .r = 60, .g = 140, .b = 60, .a = 255 } },
            .{ .value = balance, .color = .{ .r = 180, .g = 160, .b = 40, .a = 255 } },
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
        const label_y = bar_start_y + 4 * (bar_height + bar_gap) + 2;
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
