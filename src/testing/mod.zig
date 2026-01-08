//! Testing utilities - fixtures, harnesses, and helpers.
//!
//! Not imported by production code. Used by unit tests and integration tests.

pub const fixtures = @import("fixtures.zig");

test {
    _ = fixtures;
}
