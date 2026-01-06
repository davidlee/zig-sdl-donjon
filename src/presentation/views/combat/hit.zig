// Combat hit testing types
//
// View-specific zone and hit result types for combat UI interaction.
// Access as: combat.Zone, combat.Hit, combat.Interaction

const entity = @import("infra").entity;
const Rect = @import("sdl3").rect.FRect;

/// View-specific zone enum for layout purposes.
/// Distinct from cards.Zone and combat.CombatZone (domain types).
pub const Zone = enum {
    hand,
    in_play,
    always_available,
    spells, // future
    player_plays, // commit phase
    enemy_plays, // commit phase
};

/// Card interaction state for rendering
pub const Interaction = enum {
    normal,
    hover,
    drag,
    target,
};

/// Unified hit test result for cards and plays.
/// Enables consistent interaction handling across zones.
pub const Hit = union(enum) {
    /// Hit on a standalone card (hand, always_available, in_play during selection)
    card: CardHit,
    /// Hit on a card within a committed play stack
    play: PlayHit,

    pub const CardHit = struct {
        id: entity.ID,
        zone: Zone,
        rect: Rect,
    };

    pub const PlayHit = struct {
        play_index: usize,
        card_id: entity.ID,
        slot: Slot,

        pub const Slot = union(enum) {
            action,
            modifier: u4, // index into modifier stack
        };
    };

    /// Extract card ID regardless of hit type
    pub fn cardId(self: Hit) entity.ID {
        return switch (self) {
            .card => |c| c.id,
            .play => |p| p.card_id,
        };
    }
};
