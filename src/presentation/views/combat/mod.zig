/// Combat view components.
///
/// Types and views specific to the combat encounter screen.
/// Note: Status bars and End Turn button are now in chrome.zig.
pub const view = @import("view.zig");
pub const hit = @import("hit.zig");
pub const play = @import("play.zig");
pub const avatar = @import("avatar.zig");
pub const stance = @import("stance.zig");
pub const card_zone = @import("card_zone.zig");
pub const carousel = @import("carousel.zig");

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
pub const StanceView = stance.View;
pub const StanceTriangle = stance.Triangle;
pub const CardZoneView = card_zone.CardZoneView;
pub const CarouselView = carousel.CarouselView;
pub const getLayout = card_zone.getLayout;
pub const getLayoutOffset = card_zone.getLayoutOffset;
