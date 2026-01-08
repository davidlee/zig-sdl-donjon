//! Integration test entry point.
//!
//! This file lives at src/ level so it can import domain, data, and testing
//! modules via relative paths.

const std = @import("std");

// Domain imports for integration tests
pub const domain = @import("domain/mod.zig");
pub const data = struct {
    pub const personas = @import("data/personas.zig");
};
pub const testing_utils = @import("testing/mod.zig");

// Integration test modules
pub const integration = @import("testing/integration/mod.zig");

test {
    _ = integration;
}
