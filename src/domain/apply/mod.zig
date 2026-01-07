//! Apply module - card validation, targeting, effect execution, and command handling.
//!
//! This module aggregates the apply subsystem. Import as:
//!   const apply = @import("apply/mod.zig");
//!   // or via domain: const apply = @import("domain").apply;

// Submodules
pub const validation = @import("validation.zig");
pub const targeting = @import("targeting.zig");
pub const command_handler = @import("command_handler.zig");
pub const event_processor = @import("event_processor.zig");
pub const costs = @import("costs.zig");

// Effects submodules
pub const effects = struct {
    pub const commit = @import("effects/commit.zig");
    pub const resolve = @import("effects/resolve.zig");
    pub const manoeuvre = @import("effects/manoeuvre.zig");
    pub const positioning = @import("effects/positioning.zig");
};

// Re-export commonly used types at top level for convenience
pub const ValidationError = validation.ValidationError;
pub const PredicateContext = validation.PredicateContext;
pub const PlayTarget = targeting.PlayTarget;
pub const CommandHandler = command_handler.CommandHandler;
pub const CommandError = command_handler.CommandError;
pub const EventProcessor = event_processor.EventProcessor;

// Re-export commonly used validation functions
pub const canPlayerPlayCard = validation.canPlayerPlayCard;
pub const isCardSelectionValid = validation.isCardSelectionValid;
pub const validateCardSelection = validation.validateCardSelection;
pub const rulePredicatesSatisfied = validation.rulePredicatesSatisfied;
pub const canWithdrawPlay = validation.canWithdrawPlay;
pub const evaluatePredicate = validation.evaluatePredicate;
pub const compareReach = validation.compareReach;
pub const compareF32 = validation.compareF32;

// Re-export commonly used targeting functions
pub const expressionAppliesToTarget = targeting.expressionAppliesToTarget;
pub const cardHasValidTargets = targeting.cardHasValidTargets;
pub const evaluateTargets = targeting.evaluateTargets;
pub const evaluatePlayTargets = targeting.evaluatePlayTargets;
pub const resolvePlayTargetIDs = targeting.resolvePlayTargetIDs;
pub const getModifierTargetPredicate = targeting.getModifierTargetPredicate;
pub const canModifierAttachToPlay = targeting.canModifierAttachToPlay;

// Re-export command handler helpers
pub const PlayResult = command_handler.PlayResult;
pub const playValidCardReservingCosts = command_handler.playValidCardReservingCosts;

// Re-export effect functions
pub const applyCommitPhaseEffect = effects.commit.applyCommitPhaseEffect;
pub const executeCommitPhaseRules = effects.commit.executeCommitPhaseRules;
pub const executeResolvePhaseRules = effects.resolve.executeResolvePhaseRules;
pub const tickConditions = effects.resolve.tickConditions;
pub const executeManoeuvreEffects = effects.manoeuvre.executeManoeuvreEffects;
pub const adjustRange = effects.manoeuvre.adjustRange;

// Re-export positioning types and functions
pub const ManoeuvreType = effects.positioning.ManoeuvreType;
pub const ManoeuvreOutcome = effects.positioning.ManoeuvreOutcome;
pub const calculateManoeuvreScore = effects.positioning.calculateManoeuvreScore;
pub const resolveManoeuvreConflict = effects.positioning.resolveManoeuvreConflict;
pub const getAgentFootwork = effects.positioning.getAgentFootwork;
pub const resolvePositioningContests = effects.positioning.resolvePositioningContests;

// Re-export cost functions
pub const applyCommittedCosts = costs.applyCommittedCosts;
