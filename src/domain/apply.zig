//! Apply module - card validation, targeting, effect execution, and command handling.
//!
//! This is a thin re-export module. See apply/ subdirectory for implementations.
//! Import as: const apply = @import("apply.zig");

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;

// Re-export everything from the apply module
const apply_mod = @import("apply/mod.zig");

// Submodule namespaces
pub const validation = apply_mod.validation;
pub const targeting = apply_mod.targeting;
pub const command_handler = apply_mod.command_handler;
pub const event_processor = apply_mod.event_processor;
pub const costs = apply_mod.costs;
pub const effects = apply_mod.effects;

// Types
pub const ValidationError = apply_mod.ValidationError;
pub const PredicateContext = apply_mod.PredicateContext;
pub const PlayTarget = apply_mod.PlayTarget;
pub const CommandHandler = apply_mod.CommandHandler;
pub const CommandError = apply_mod.CommandError;
pub const EventProcessor = apply_mod.EventProcessor;

// Validation functions
pub const canPlayerPlayCard = apply_mod.canPlayerPlayCard;
pub const isCardSelectionValid = apply_mod.isCardSelectionValid;
pub const validateCardSelection = apply_mod.validateCardSelection;
pub const rulePredicatesSatisfied = apply_mod.rulePredicatesSatisfied;
pub const canWithdrawPlay = apply_mod.canWithdrawPlay;
pub const evaluatePredicate = apply_mod.evaluatePredicate;
pub const compareReach = apply_mod.compareReach;
pub const compareF32 = apply_mod.compareF32;
pub const checkOnPlayAttemptBlockers = apply_mod.checkOnPlayAttemptBlockers;
pub const cardTemplateMatchesPredicate = apply_mod.cardTemplateMatchesPredicate;

// Targeting functions
pub const expressionAppliesToTarget = apply_mod.expressionAppliesToTarget;
pub const cardHasValidTargets = apply_mod.cardHasValidTargets;
pub const evaluateTargets = apply_mod.evaluateTargets;
pub const evaluatePlayTargets = apply_mod.evaluatePlayTargets;
pub const resolvePlayTargetIDs = apply_mod.resolvePlayTargetIDs;
pub const getModifierTargetPredicate = apply_mod.getModifierTargetPredicate;
pub const canModifierAttachToPlay = apply_mod.canModifierAttachToPlay;

// Command handler helpers
pub const PlayResult = apply_mod.PlayResult;
pub const playValidCardReservingCosts = apply_mod.playValidCardReservingCosts;

// Effect functions
pub const applyCommitPhaseEffect = apply_mod.applyCommitPhaseEffect;
pub const executeCommitPhaseRules = apply_mod.executeCommitPhaseRules;
pub const executeResolvePhaseRules = apply_mod.executeResolvePhaseRules;
pub const tickConditions = apply_mod.tickConditions;
pub const executeManoeuvreEffects = apply_mod.executeManoeuvreEffects;
pub const adjustRange = apply_mod.adjustRange;

// Positioning types and functions
pub const ManoeuvreType = apply_mod.ManoeuvreType;
pub const ManoeuvreOutcome = apply_mod.ManoeuvreOutcome;
pub const calculateManoeuvreScore = apply_mod.calculateManoeuvreScore;
pub const resolveManoeuvreConflict = apply_mod.resolveManoeuvreConflict;
pub const getAgentFootwork = apply_mod.getAgentFootwork;
pub const resolvePositioningContests = apply_mod.resolvePositioningContests;

// Cost functions
pub const applyCommittedCosts = apply_mod.applyCommittedCosts;
