//! Apply module - card validation, targeting, and effect execution.
//!
//! This module aggregates the apply subsystem. Import as:
//!   const apply = @import("apply/mod.zig");
//!   // or via domain: const apply = @import("domain").apply;

pub const validation = @import("validation.zig");
pub const targeting = @import("targeting.zig");

// Re-export commonly used types at top level for convenience
pub const ValidationError = validation.ValidationError;
pub const PredicateContext = validation.PredicateContext;
pub const PlayTarget = targeting.PlayTarget;

// Re-export commonly used functions
pub const canPlayerPlayCard = validation.canPlayerPlayCard;
pub const isCardSelectionValid = validation.isCardSelectionValid;
pub const validateCardSelection = validation.validateCardSelection;
pub const rulePredicatesSatisfied = validation.rulePredicatesSatisfied;
pub const canWithdrawPlay = validation.canWithdrawPlay;
pub const evaluatePredicate = validation.evaluatePredicate;
pub const compareReach = validation.compareReach;
pub const compareF32 = validation.compareF32;

pub const expressionAppliesToTarget = targeting.expressionAppliesToTarget;
pub const cardHasValidTargets = targeting.cardHasValidTargets;
pub const evaluateTargets = targeting.evaluateTargets;
pub const evaluatePlayTargets = targeting.evaluatePlayTargets;
pub const resolvePlayTargetIDs = targeting.resolvePlayTargetIDs;
pub const getModifierTargetPredicate = targeting.getModifierTargetPredicate;
pub const canModifierAttachToPlay = targeting.canModifierAttachToPlay;
