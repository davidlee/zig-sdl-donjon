//! Query module: Read-only snapshots for UI consumption.
//!
//! This module provides pre-computed validation results, decoupling
//! the presentation layer from direct domain.apply.* calls.

pub const combat_snapshot = @import("combat_snapshot.zig");

pub const CombatSnapshot = combat_snapshot.CombatSnapshot;
pub const CardStatus = combat_snapshot.CardStatus;
pub const PlayStatus = combat_snapshot.PlayStatus;
pub const buildSnapshot = combat_snapshot.buildSnapshot;

test {
    _ = combat_snapshot;
}
