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

    pub fn appendRenderables(self: *const Opposition, alloc: std.mem.Allocator, list: *std.ArrayList(Renderable)) !void {
        for (self.enemies, 0..) |e, i| {
            const sprite = Enemy.init(e.id, i);
            try list.append(alloc, sprite.renderable());
        }
    }
};
