//! Combat module - re-exports combat types and state management.
//!
//! This module aggregates the combat subsystem. Import as:
//!   const combat = @import("combat/mod.zig");
//!   // or via domain: const combat = @import("domain").combat;

// Submodules
pub const types = @import("types.zig");
pub const state = @import("state.zig");
pub const armament = @import("armament.zig");
pub const advantage = @import("advantage.zig");
pub const plays = @import("plays.zig");
pub const engagement = @import("engagement.zig");
pub const agent = @import("agent.zig");
pub const encounter = @import("encounter.zig");

// Re-export commonly used types at top level for convenience

// From types.zig
pub const Director = types.Director;
pub const Reach = types.Reach;
pub const AdvantageAxis = types.AdvantageAxis;
pub const DrawStyle = types.DrawStyle;
pub const CombatOutcome = types.CombatOutcome;
pub const TurnPhase = types.TurnPhase;
pub const TurnEvent = types.TurnEvent;
pub const TurnFSM = types.TurnFSM;

// From state.zig
pub const CombatZone = state.CombatZone;
pub const CombatState = state.CombatState;

// From armament.zig
pub const Armament = armament.Armament;

// From advantage.zig
pub const AdvantageEffect = advantage.AdvantageEffect;
pub const TechniqueAdvantage = advantage.TechniqueAdvantage;

// From plays.zig
pub const Play = plays.Play;
pub const TimeSlot = plays.TimeSlot;
pub const Timeline = plays.Timeline;
pub const PendingTarget = plays.PendingTarget;
pub const TurnState = plays.TurnState;
pub const TurnHistory = plays.TurnHistory;
pub const AgentEncounterState = plays.AgentEncounterState;
pub const getPlayDuration = plays.getPlayDuration;
pub const getPlayChannels = plays.getPlayChannels;

// From engagement.zig
pub const AgentPair = engagement.AgentPair;
pub const Engagement = engagement.Engagement;

// From agent.zig
pub const Agent = agent.Agent;
pub const ConditionIterator = agent.ConditionIterator;

// From encounter.zig
pub const Encounter = encounter.Encounter;
