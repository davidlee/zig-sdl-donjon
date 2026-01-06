//! Combat module - re-exports from combat/ subdirectory.
//!
//! This file maintains backward compatibility for existing imports.
//! New code should import specific submodules as needed.

const combat_mod = @import("combat/mod.zig");

// Re-export submodules
pub const types = combat_mod.types;
pub const state = combat_mod.state;
pub const armament = combat_mod.armament;
pub const advantage = combat_mod.advantage;
pub const plays = combat_mod.plays;
pub const engagement = combat_mod.engagement;
pub const agent = combat_mod.agent;
pub const encounter = combat_mod.encounter;

// Re-export all public types at top level for backward compatibility

// From types.zig
pub const Director = combat_mod.Director;
pub const Reach = combat_mod.Reach;
pub const AdvantageAxis = combat_mod.AdvantageAxis;
pub const DrawStyle = combat_mod.DrawStyle;
pub const CombatOutcome = combat_mod.CombatOutcome;
pub const TurnPhase = combat_mod.TurnPhase;
pub const TurnEvent = combat_mod.TurnEvent;
pub const TurnFSM = combat_mod.TurnFSM;

// From state.zig
pub const CombatZone = combat_mod.CombatZone;
pub const CombatState = combat_mod.CombatState;

// From armament.zig
pub const Armament = combat_mod.Armament;

// From advantage.zig
pub const AdvantageEffect = combat_mod.AdvantageEffect;
pub const TechniqueAdvantage = combat_mod.TechniqueAdvantage;

// From plays.zig
pub const Play = combat_mod.Play;
pub const TimeSlot = combat_mod.TimeSlot;
pub const Timeline = combat_mod.Timeline;
pub const PendingTarget = combat_mod.PendingTarget;
pub const TurnState = combat_mod.TurnState;
pub const TurnHistory = combat_mod.TurnHistory;
pub const AgentEncounterState = combat_mod.AgentEncounterState;
pub const getPlayDuration = combat_mod.getPlayDuration;
pub const getPlayChannels = combat_mod.getPlayChannels;
pub const hasFootworkInTimeline = combat_mod.hasFootworkInTimeline;

// From engagement.zig
pub const AgentPair = combat_mod.AgentPair;
pub const Engagement = combat_mod.Engagement;
pub const FlankingStatus = combat_mod.FlankingStatus;

// From agent.zig
pub const Agent = combat_mod.Agent;
pub const ConditionIterator = combat_mod.ConditionIterator;

// From encounter.zig
pub const Encounter = combat_mod.Encounter;

// Re-export tests from submodules
test {
    _ = @import("combat/types.zig");
    _ = @import("combat/state.zig");
    _ = @import("combat/armament.zig");
    _ = @import("combat/advantage.zig");
    _ = @import("combat/plays.zig");
    _ = @import("combat/engagement.zig");
    _ = @import("combat/agent.zig");
    _ = @import("combat/encounter.zig");
}
