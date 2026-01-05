// Combat view components
//
// Types and views specific to the combat encounter screen.
// Access as: combat.Zone, combat.Hit, combat.play.Data, etc.

pub const hit = @import("hit.zig");
pub const play = @import("play.zig");

// Convenience re-exports for combat-specific types
pub const Zone = hit.Zone;
pub const Hit = hit.Hit;
pub const Interaction = hit.Interaction;
pub const PlayData = play.Data;
pub const PlayZone = play.Zone;
