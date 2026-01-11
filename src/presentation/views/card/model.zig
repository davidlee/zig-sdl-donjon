// Card presentation model - data for rendering a card
//
// Bridges domain card representation to what the renderer needs.
// Access as: card.Model, card.Kind, card.State, etc.

const std = @import("std");
const cards = @import("../../../domain/cards.zig");
const lib = @import("infra");
const entity = lib.entity;
const types = @import("../types.zig");
const AssetId = types.AssetId;

/// Visual card kind (determines background color scheme)
pub const Kind = enum {
    action,
    passive,
    reaction,
    modifier,
    other,
};

/// Visual rarity (determines border treatment)
pub const Rarity = enum {
    common,
    uncommon,
    rare,
    epic,
    legendary,
};

/// Instance state that affects rendering
pub const State = packed struct {
    exhausted: bool = false,
    selected: bool = false,
    highlighted: bool = false,
    disabled: bool = false, // !playable by player - potentially expensive to compute
    played: bool = false,
    target: bool = false, // drag & drop target
    warning: bool = false, // playable but no valid targets currently (e.g. out of range)
};

/// All data the renderer needs to draw a card
pub const Model = struct {
    id: entity.ID,
    name: []const u8,
    description: []const u8,
    kind: Kind,
    rarity: Rarity,
    stamina_cost: f32,
    time_cost: f32,
    state: State,
    icon: ?AssetId = null,

    /// Create view model from domain instance
    pub fn fromInstance(instance: cards.Instance, state: State) Model {
        return fromTemplate(instance.id, instance.template, state);
    }

    /// Create view model from template (for previews, deck building, etc.)
    pub fn fromTemplate(id: entity.ID, template: *const cards.Template, state: State) Model {
        return .{
            .id = id,
            .name = template.name,
            .description = template.description,
            .kind = kindFromTags(template.tags),
            .rarity = mapRarity(template.rarity),
            .stamina_cost = template.cost.stamina,
            .time_cost = template.cost.time,
            .state = state,
            .icon = mapIcon(template.icon),
        };
    }

    pub fn mapIcon(icon: ?cards.RuneIcon) ?AssetId {
        const i = icon orelse return null;
        return switch (i) {
            .eo => .rune_eo,
            .th => .rune_th,
            .u => .rune_u,
            .y => .rune_y,
            .f => .rune_f,
        };
    }

    /// Derive visual kind from tag set
    fn kindFromTags(tags: cards.TagSet) Kind {
        if (tags.modifier) return .modifier;
        if (tags.reaction) return .reaction;
        return .action;
    }

    fn mapRarity(rarity: cards.Rarity) Rarity {
        return switch (rarity) {
            .common => .common,
            .uncommon => .uncommon,
            .rare => .rare,
            .epic => .epic,
            .legendary => .legendary,
        };
    }
};
