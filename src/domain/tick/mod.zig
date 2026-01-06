/// Tick resolution module (see doc/decomposition.md for details).
///
/// Groups the committed action data structures with the TickResolver that
/// executes them. TickResolver only depends on apply/targeting, not the full
/// command stack, so it can be reused in simulations.

pub const committed_action = @import("committed_action.zig");
pub const resolver = @import("resolver.zig");

// Re-export commonly used types at top level
pub const CommittedAction = committed_action.CommittedAction;
pub const ResolutionEntry = committed_action.ResolutionEntry;
pub const TickResult = committed_action.TickResult;
pub const TickResolver = resolver.TickResolver;
