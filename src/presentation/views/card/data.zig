// Card view data - minimal card info for view rendering
//
// Decouples view layer from Instance pointers.
// Access as: card.Data, card.Data.Source

const cards = @import("../../../domain/cards.zig");
const entity = @import("infra").entity;

/// Minimal card data for view rendering.
/// Decouples view layer from Instance pointers.
pub const Data = struct {
    id: entity.ID,
    template: *const cards.Template,
    playable: bool,
    source: Source,

    /// Card sources - where the card originated from.
    /// Currently used: hand, in_play. Others stubbed for future card systems.
    pub const Source = enum {
        hand,
        in_play,
        always_available,
        spells, // future
        equipped, // future
        inventory, // future
        environment, // future
    };

    pub fn fromInstance(inst: *const cards.Instance, source: Source, playable: bool) Data {
        return .{
            .id = inst.id,
            .template = inst.template,
            .playable = playable,
            .source = source,
        };
    }
};
