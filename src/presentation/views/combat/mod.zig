/// Combat view components.
///
/// Types and views specific to the combat encounter screen.
/// Note: Status bars and End Turn button are now in chrome.zig.
pub const view = @import("view.zig");
pub const hit = @import("hit.zig");
pub const play = @import("play.zig");
pub const avatar = @import("avatar.zig");

// Convenience re-exports for combat-specific types
pub const View = view.View;
pub const Zone = hit.Zone;
pub const Hit = hit.Hit;
pub const Interaction = hit.Interaction;
pub const PlayData = play.Data;
pub const PlayZone = play.Zone;
pub const TimelineView = play.TimelineView;
pub const Player = avatar.Player;
pub const Enemy = avatar.Enemy;
pub const Opposition = avatar.Opposition;
