//! Combat module - re-exports combat types and state management.
//!
//! This module aggregates the combat subsystem. Import as:
//!   const combat = @import("combat/mod.zig");
//!   // or via domain: const combat = @import("domain").combat;

pub const state = @import("state.zig");

// Re-export commonly used types at top level for convenience
pub const CombatZone = state.CombatZone;
pub const CombatState = state.CombatState;
