const std = @import("std");
const lib = @import("infra");
const stats = @import("stats.zig");
const cards = @import("cards.zig");

const body = @import("body.zig");
const damage = @import("damage.zig");

pub const Archetype = .{
    .soldier = stats.Template{
        .power = 6,
        .speed = 5,
        .agility = 4,
        .dexterity = 3,
        .fortitude = 6,
        .endurance = 5,
        // mental
        .acuity = 4,
        .will = 4,
        .intuition = 3,
        .presence = 5,
    },
    .hunter = stats.Template{
        .power = 5,
        .speed = 6,
        .agility = 7,
        .dexterity = 3,
        .fortitude = 5,
        .endurance = 5,
        // mental
        .acuity = 6,
        .will = 4,
        .intuition = 4,
        .presence = 4,
    },
};

pub const Player = struct {
    alloc: std.mem.Allocator,
    stats: stats.Block,
    wounds: std.ArrayList(body.Wound),
    conditions: std.ArrayList(damage.Condition),
    equipment: std.ArrayList(*const cards.Instance),
    stamina: f32,
    stamina_available: f32,
    time_available: f32 = 1.0,

    pub fn init(alloc: std.mem.Allocator) !Player {
        //return Player{ .stats = stats.Block.splat(5), .wounds = {}, .equipment = &.{}, .conditions = {} };
        return Player.initEmptyWithStats(alloc, stats.Block.splat(5));
    }

    fn initEmptyWithStats(alloc: std.mem.Allocator, statBlock: stats.Block) !Player {
        return Player{
            .alloc = alloc,
            .stats = statBlock,
            .wounds = try std.ArrayList(body.Wound).initCapacity(alloc, 5),
            .conditions = try std.ArrayList(damage.Condition).initCapacity(alloc, 5),
            .equipment = try std.ArrayList(*const cards.Instance).initCapacity(alloc, 5),
            .stamina = 5,
            .stamina_available = 5,
        };
    }

    pub fn deinit(self: *Player) void {
        self.wounds.deinit(self.alloc);
        self.conditions.deinit(self.alloc);
        self.equipment.deinit(self.alloc);
    }
};
