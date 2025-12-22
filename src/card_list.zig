const std = @import("std");
const Event = @import("events.zig").Event;
const EntityID = @import("entity.zig").EntityID;

const cards = @import("cards.zig");
const damage = @import("damage.zig");
const stats = @import("stats.zig");

const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Template = cards.Template;
const Expression = cards.Expression;
const Technique = cards.Technique;
const TechniqueID = cards.TechniqueID;

const ID = cards.ID;

fn hashName(comptime name: []const u8) ID {
    return std.hash.Wyhash.hash(0, name);
}

const TechniqueRepository = struct {
    entries: []Technique,
};

pub const TechniqueEntries = [_]Technique{
    .{
        .id = .thrust,
        .name = "thrust",
        .damage = .{
            .instances = &.{
                .{ .amount = 1.0, .types = &.{.pierce} },
            },
            .scaling = .{
                .ratio = 0.5,
                .stats = .{ .average = .{ .speed, .power } },
            },
        },
        .difficulty = 0.7,
        .deflect_mult = 1.3,
        .dodge_mult = 0.5,
        .counter_mult = 1.1,
        .parry_mult = 1.2,
    },

    .{
        .id = .swing,
        .name = "swing",
        .damage = .{
            .instances = &.{
                .{ .amount = 1.0, .types = &.{.slash} },
            },
            .scaling = .{
                .ratio = 1.2,
                .stats = .{ .average = .{ .speed, .power } },
            },
        },
        .difficulty = 1.0,
        .deflect_mult = 1.0,
        .dodge_mult = 1.2,
        .counter_mult = 1.3,
        .parry_mult = 1.2,
    },

    // TODO:  separate defensive tactics out
    .{
        .id = .swing,
        .name = "deflect",
        .damage = .{
            .instances = &.{.{ .amount = 0.0, .types = &.{} }},
            .scaling = .{
                .ratio = 0.0,
                .stats = .{ .stat = .power },
            },
        },
        .difficulty = 1.0,
        .deflect_mult = 1.0,
        .dodge_mult = 1.0,
        .counter_mult = 1.0,
        .parry_mult = 1.0,
    },

    .{
        .id = .parry,
        .name = "parry",
        .damage = .{
            .instances = &.{.{ .amount = 0.0, .types = &.{} }},
            .scaling = .{
                .ratio = 0.0,
                .stats = .{ .stat = .power },
            },
        },
        .difficulty = 1.0,
        .deflect_mult = 1.0,
        .dodge_mult = 1.0,
        .counter_mult = 1.0,
        .parry_mult = 1.0,
    },

    .{
        .id = .block,
        .name = "block",
        .damage = .{
            .instances = &.{.{ .amount = 0.0, .types = &.{} }},
            .scaling = .{
                .ratio = 0.0,
                .stats = .{ .stat = .power },
            },
        },
        .difficulty = 1.0,
        .deflect_mult = 1.0,
        .dodge_mult = 1.0,
        .counter_mult = 1.0,
        .parry_mult = 1.0,
    },
};

// -----------------------------------------------------------------------------
// Template helpers
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Starter deck
// -----------------------------------------------------------------------------
const templates = [_]Template{
    t_thrust,
    t_slash,
    t_shield_block,
};

pub const BeginnerDeck = blk: {
    var output: [templates.len]Template = undefined;
    for (templates, 0..) |data, idx| {
        const template: Template = .{
            .id = idx,
            .name = data.name,
            .kind = data.kind,
            .description = data.description,
            .rarity = data.rarity,
            .cost = data.cost,
            .tags = data.tags,
            .rules = data.rules,
        };
        output[idx] = template;
    }
    break :blk output;
};

const t_thrust = Template{
    .id = 0,
    .kind = .action,
    .name = "thrust",
    .description = "hit them with the pokey bit",
    .rarity = .common,
    .cost = .{ .stamina = 3.0, .time = 0.2 },
    .tags = .{ .melee = true, .offensive = true },
    .rules = &.{
        .{
            .trigger = .on_play,
            .valid = .always,
            .expressions = &.{.{
                .effect = .{
                    .combat_technique = Technique.byID(.thrust),
                },
                .filter = null,
                .target = .all_enemies,
            }},
        },
    },
};

const t_slash = Template{
    .id = 0,
    .kind = .action,
    .name = "slash",
    .description = "slash them like a pirate",
    .rarity = .common,
    .cost = .{ .stamina = 3.0, .time = 0.3 },
    .tags = .{ .melee = true, .offensive = true },
    .rules = &.{
        .{
            .trigger = .on_play,
            .valid = .always,
            .expressions = &.{.{
                .effect = .{
                    .combat_technique = Technique.byID(.swing),
                },
                .filter = null,
                .target = .all_enemies,
            }},
        },
    },
};

const t_shield_block = Template{
    .id = 0,
    .kind = .action,
    .name = "shield block",
    .description = "shields were made to be splintered",
    .rarity = .common,
    .cost = .{ .stamina = 2.0, .time = 0.3 },
    .tags = .{ .melee = true, .defensive = true },
    .rules = &.{
        .{
            .trigger = .on_play,
            .valid = .always,
            .expressions = &.{.{
                .effect = .{
                    .combat_technique = Technique.byID(.block),
                },
                .filter = null,
                .target = .self,
            }},
        },
    },
};
