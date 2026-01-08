//! Integration tests - exercising multiple units working together.
//!
//! Organized by feature/flow, not by component.
//! Run with: zig build test-integration

const std = @import("std");

pub const domain = @import("domain/mod.zig");
// pub const presentation = @import("presentation/mod.zig");  // future

test {
    _ = domain;
}
