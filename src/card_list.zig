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
const Expression = cards.Expression;
const Technique = cards.Technique;
const ID = cards.ID;

var template_id: ID = 0;
var technique_id: ID = 0;

// // ID helpers
// fn nextID(comptime currID: *cards.ID) cards.ID {
//     currID.* += 1;
//     return currID;
// }

fn hashName(comptime name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

const TechniqueRepository = struct {
    entries: []Technique,

    fn byName(comptime name: []const u8) Technique {
        const target = hashName(name);
        inline for (TechniqueEntries) |tech| {
            if (tech.id == target) return tech;
        }
        @compileError("unknown technique: " ++ name);
    }
};

// const t: Technique = .{
//     .id = hashName("thrust"),
//     .name = "thrust",
//     .damage = &.{
//         .instances = &.{
//             .{ .amount = 1.0, .types = &.{.pierce} },
//         },
//         .scaling = &.{
//             .ratio = 0.5,
//             .stats = .{ .average = &.{ .speed, .power }},
//         },
//     },
//     .difficulty = 0.7,
//     .deflect_mult = 1.3,
//     .dodge_mult = 0.5,
//     .counter_mult = 1.1,
//     .parry_mult = 1.2
// };

const TechniqueEntries: [5]Technique = .{
    .{ .id = hashName("thrust"), .name = "thrust", .damage = .{
        .instances = &.{
            .{ .amount = 1.0, .types = &.{.pierce} },
        },
        .scaling = .{
            .ratio = 0.5,
            .stats = .{ .average = .{ .speed, .power } },
        },
    }, .difficulty = 0.7, .deflect_mult = 1.3, .dodge_mult = 0.5, .counter_mult = 1.1, .parry_mult = 1.2 },

    .{
        .id = hashName("swing"),
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
    // // TODO: maybe - separate defensive tactics out
    .{
        .id = hashName("deflect"),
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
        .id = hashName("parry"),
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
        .id = hashName("block"),
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

pub const Techniques: TechniqueRepository = &.{
    .entries = TechniqueEntries,
};

pub const BeginnerDeck: [3]cards.Template = .{
    .{
        .id = 0,
        .kind = .action,
        .name = "thrust",
        .description = "hit them with the pokey bit",
        .rarity = .common,
        .tags = .{
            .melee = true,
            .offensive = true,
        },
        .rules = &.{
            .{
                .trigger = .on_play,
                .valid = .always,
                .expressions = &.{Expression{
                    .effect = .{
                        .combat_technique = TechniqueRepository.byName("thrust"),
                    },
                    .filter = null,
                    .target = .all_enemies,
                }},
            },
        },
        .cost = Cost{ .stamina = 2.5, .time = 0.3 },
    },

    .{
        .id = 1,
        .kind = .action,
        .name = "slash",
        .description = "slash them like a pirate",
        .rarity = .common,
        .tags = TagSet{
            .melee = true,
            .offensive = true,
        },
        .rules = &.{
            .{
                .trigger = .on_play,
                .valid = .always, // slashing damage
                .expressions = &.{Expression{
                    .effect = .{
                        .combat_technique = TechniqueRepository.byName("swing"),
                    },
                    .filter = null,
                    .target = .all_enemies,
                }},
            },
        },
        .cost = Cost{ .stamina = 3.0, .time = 0.3 },
    },

    .{
        .id = 2,
        .kind = .action,
        .name = "shield block",
        .description = "defend",
        .rarity = .common,
        .tags = TagSet{
            .melee = true,
            .defensive = true,
        },
        .rules = &.{
            .{
                .trigger = .on_play,
                .valid = .always, // slashing damage
                .expressions = &.{Expression{
                    .effect = .{
                        .combat_technique = TechniqueRepository.byName("swing"),
                    },
                    .filter = null,
                    .target = .all_enemies,
                }},
            },
        },
        .cost = Cost{ .stamina = 2.0, .time = 0.3 },
    },
};
