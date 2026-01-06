// Tick resolution module - see doc/decomposition.md for refactor notes
//
// This module handles:
// - CommittedAction: data type for actions committed for resolution
// - TickResolver: orchestrates combat resolution for a single tick
//
// Key decoupling: TickResolver depends only on apply/targeting.zig,
// not the full apply module. This enables alternative resolvers
// (e.g. AI simulations) to reuse targeting without UI command code.

pub const committed_action = @import("committed_action.zig");
pub const resolver = @import("resolver.zig");

// Re-export commonly used types at top level
pub const CommittedAction = committed_action.CommittedAction;
pub const ResolutionEntry = committed_action.ResolutionEntry;
pub const TickResult = committed_action.TickResult;
pub const TickResolver = resolver.TickResolver;
