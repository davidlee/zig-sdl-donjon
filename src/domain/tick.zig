// Re-export from tick/ submodules - see doc/decomposition.md for refactor notes
const tick_mod = @import("tick/mod.zig");

pub const committed_action = tick_mod.committed_action;
pub const resolver = tick_mod.resolver;

// Re-export commonly used types for backward compatibility
pub const CommittedAction = tick_mod.CommittedAction;
pub const ResolutionEntry = tick_mod.ResolutionEntry;
pub const TickResult = tick_mod.TickResult;
pub const TickResolver = tick_mod.TickResolver;
