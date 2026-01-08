//! Integration tests - exercising multiple units working together.
//!
//! Organized by feature/flow, not by component.
//! Run with: zig build test-integration

const std = @import("std");

pub const harness = @import("harness.zig");
pub const domain_tests = @import("domain/mod.zig");
// pub const presentation = @import("presentation/mod.zig");  // future

test {
    _ = harness;
    _ = domain_tests;
}
