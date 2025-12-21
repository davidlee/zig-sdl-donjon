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

fn hashName(comptime name: []const u8) ID {
    return std.hash.Wyhash.hash(0, name);
}

const TechniqueData = struct { name: []const u8, damage: damage.Base, difficulty: f32, deflect_mult: f32, dodge_mult: f32, counter_mult: f32, parry_mult: f32 };

fn defineTechnique(data: TechniqueData) Technique {
    return Technique{
        .id = hashName(data.name),
        .name = data.name,
        .damage = data.damage,
        .difficulty = data.difficulty,
        .deflect_mult = data.deflect_mult,
        .dodge_mult = data.dodge_mult,
        .counter_mult = data.counter_mult,
        .parry_mult = data.parry_mult,
    };
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

const TechniqueEntries = [_]Technique{
    defineTechnique(.{ .name = "thrust", .damage = .{
        .instances = &.{
            .{ .amount = 1.0, .types = &.{.pierce} },
        },
        .scaling = .{
            .ratio = 0.5,
            .stats = .{ .average = .{ .speed, .power } },
        },
    }, .difficulty = 0.7, .deflect_mult = 1.3, .dodge_mult = 0.5, .counter_mult = 1.1, .parry_mult = 1.2 }),

    defineTechnique(.{
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
    }),

    // TODO: maybe - separate defensive tactics out
    defineTechnique(.{
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
    }),
    defineTechnique(.{
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
    }),
    defineTechnique(.{
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
    }),
};

pub const Techniques: TechniqueRepository = &.{
    .entries = TechniqueEntries,
};

// -----------------------------------------------------------------------------
// Template helpers
// -----------------------------------------------------------------------------

const ActionData = struct {
    name: []const u8,
    description: []const u8,
    technique: []const u8,
    tags: TagSet = .{},
    cost: Cost,
    rarity: cards.Rarity,
    target: cards.TargetQuery,
};

fn defineTemplate(comptime data: ActionData) cards.Template {
    return .{
        .id = hashName(data.name),
        .kind = .action,
        .name = data.name,
        .description = data.description,
        .rarity = data.rarity,
        .tags = data.tags,
        .rules = &.{
            .{
                .trigger = .on_play,
                .valid = .always,
                .expressions = &.{.{
                    .effect = .{ .combat_technique = TechniqueRepository.byName(data.technique) },
                    .filter = null,
                    .target = data.target,
                }},
            },
        },
        .cost = data.cost,
    };
}

// -----------------------------------------------------------------------------
// Starter deck
// -----------------------------------------------------------------------------

pub const BeginnerDeck = [_]cards.Template{
    defineTemplate(.{
        .name = "thrust",
        .description = "hit them with the pokey bit",
        .technique = "thrust",
        .tags = .{ .melee = true, .offensive = true },
        .cost = .{ .stamina = 2.5, .time = 0.3 },
        .rarity = .common,
        .target = .all_enemies,
    }),
    defineTemplate(.{
        .name = "slash",
        .description = "slash them like a pirate",
        .technique = "swing",
        .tags = .{ .melee = true, .offensive = true },
        .cost = .{ .stamina = 3.0, .time = 0.3 },
        .rarity = .common,
        .target = .all_enemies,
    }),
    defineTemplate(.{
        .name = "shield block",
        .description = "defend with your shield",
        .technique = "block",
        .tags = .{ .melee = true, .defensive = true },
        .cost = .{ .stamina = 2.0, .time = 0.3 },
        .rarity = .common,
        .target = .self,
    }),
};
