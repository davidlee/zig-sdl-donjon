// CardViewModel - presentation data for rendering a card
//
// Bridges domain card representation to what the renderer needs.
// Lives in views/ because it knows about domain types.

const std = @import("std");
const cards = @import("../../domain/cards.zig");
const lib = @import("infra");
const entity = lib.entity;

/// Visual card kind (determines background color scheme)
pub const CardKind = enum {
    action,
    passive,
    reaction,
    other,
};

/// Visual rarity (determines border treatment)
pub const CardRarity = enum {
    common,
    uncommon,
    rare,
    epic,
    legendary,
};

/// Instance state that affects rendering
pub const CardState = packed struct {
    exhausted: bool = false,
    selected: bool = false,
    highlighted: bool = false,
    disabled: bool = false,
};

/// All data the renderer needs to draw a card
pub const CardViewModel = struct {
    id: entity.ID,
    name: []const u8,
    description: []const u8,
    kind: CardKind,
    rarity: CardRarity,
    stamina_cost: f32,
    time_cost: f32,
    state: CardState,

    /// Create view model from domain instance
    pub fn fromInstance(instance: cards.Instance, state: CardState) CardViewModel {
        return fromTemplate(instance.id, instance.template, state);
    }

    /// Create view model from template (for previews, deck building, etc.)
    pub fn fromTemplate(id: entity.ID, template: *const cards.Template, state: CardState) CardViewModel {
        return .{
            .id = id,
            .name = template.name,
            .description = template.description,
            .kind = mapKind(template.kind),
            .rarity = mapRarity(template.rarity),
            .stamina_cost = template.cost.stamina,
            .time_cost = template.cost.time,
            .state = state,
        };
    }

    fn mapKind(kind: cards.Kind) CardKind {
        return switch (kind) {
            .action => .action,
            .passive => .passive,
            .reaction => .reaction,
            else => .other,
        };
    }

    fn mapRarity(rarity: cards.Rarity) CardRarity {
        return switch (rarity) {
            .common => .common,
            .uncommon => .uncommon,
            .rare => .rare,
            .epic => .epic,
            .legendary => .legendary,
        };
    }
};
