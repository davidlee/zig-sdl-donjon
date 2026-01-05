// Combat view components
//
// Types and views specific to the combat encounter screen.
// Access as: combat.View, combat.Zone, combat.Hit, combat.play.Data, etc.

pub const view = @import("view.zig");
pub const hit = @import("hit.zig");
pub const play = @import("play.zig");
pub const button = @import("button.zig");
pub const avatar = @import("avatar.zig");
pub const status_bar = @import("status_bar.zig");

// Convenience re-exports for combat-specific types
pub const View = view.View;
pub const Zone = hit.Zone;
pub const Hit = hit.Hit;
pub const Interaction = hit.Interaction;
pub const PlayData = play.Data;
pub const PlayZone = play.Zone;
pub const EndTurn = button.EndTurn;
pub const Player = avatar.Player;
pub const Enemy = avatar.Enemy;
pub const Opposition = avatar.Opposition;
pub const StatusBar = status_bar.View;
