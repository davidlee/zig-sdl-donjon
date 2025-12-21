const std = @import("std");
const Event = @import("events.zig").Event;
const EntityID = @import("entity.zig").EntityID;
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");
const actions = @import("actions.zig");
const cards = @import("cards.zig");

const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Expression= cards.Expression;

var id: cards.ID = 0;
pub const BeginnerDeck: []cards.Template = .{
    cards.Template{
        .id = cards.nextCardID(&id),
        .kind = .action,
        .name = "strike",
        .description = "hit them",
        .rarity = .common,
        .tags = TagSet{
            .melee = true,
            .offensive = true,
        },
        .rules = Rule{
            .trigger = .on_play,
            .valid = .always,
            .expressions = .{
              Expression{
                  .effect = Effect{
                      
                  },
              }  
            },
            
        },
        .cost = Cost{ .stamina = 3.0, .time = 0.3 },
    },
    cards.Template{
        .id = cards.nextCardID(&id),
        .kind = .action,
        .name = "block",
        .description = "defend",
        .rarity = .common,
        .tags = TagSet{
            .melee = true,
            .defensive = true,
        },
        .rules = Rule{},
        .cost = Cost{ .stamina = 2.0, .time = 0.3 },
    },
};
