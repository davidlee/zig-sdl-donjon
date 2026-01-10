//! Domain layer integration tests.
//!
//! Tests here exercise multiple domain modules working together:
//! cards + timeline + resolution, damage + armour + conditions, etc.

const std = @import("std");

pub const card_flow = @import("card_flow.zig");
pub const damage_resolution = @import("damage_resolution.zig");
pub const range_validation = @import("range_validation.zig");
pub const weapon_resolution = @import("weapon_resolution.zig");
// pub const positioning = @import("positioning.zig");  // future

test {
    _ = card_flow;
    _ = damage_resolution;
    _ = range_validation;
    _ = weapon_resolution;
}
