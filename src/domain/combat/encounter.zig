//! Combat encounter - manages a combat instance with multiple agents.
//!
//! An Encounter tracks all combatants, their engagements with each other,
//! environmental elements, and the turn phase state machine.

const std = @import("std");
const zigfsm = @import("zigfsm");
const lib = @import("infra");
const entity = lib.entity;
const SlotMap = @import("../slot_map.zig").SlotMap;

const types = @import("types.zig");
const plays = @import("plays.zig");
const engagement_mod = @import("engagement.zig");
const agent_mod = @import("agent.zig");

pub const TurnPhase = types.TurnPhase;
pub const TurnEvent = types.TurnEvent;
pub const TurnFSM = types.TurnFSM;
pub const CombatOutcome = types.CombatOutcome;
pub const AgentEncounterState = plays.AgentEncounterState;
pub const AgentPair = engagement_mod.AgentPair;
pub const Engagement = engagement_mod.Engagement;
pub const Agent = agent_mod.Agent;

// Forward reference for combat.Agent in deinit
const combat = @import("../combat.zig");

/// A combat encounter between the player and one or more enemies.
pub const Encounter = struct {
    alloc: std.mem.Allocator,
    enemies: std.ArrayList(*combat.Agent),
    player_id: entity.ID,
    engagements: std.AutoHashMap(AgentPair, Engagement),
    agent_state: std.AutoHashMap(entity.ID, AgentEncounterState),

    // Environmental cards (rubble, thrown items, lootable)
    environment: std.ArrayList(entity.ID),
    // Card ownership tracking for thrown items (card_id -> original_owner_id)
    thrown_by: std.AutoHashMap(entity.ID, entity.ID),

    // Combat result (set when combat ends, for summary display)
    outcome: ?CombatOutcome = null,

    // Turn phase FSM (combat flow within encounter)
    turn_fsm: TurnFSM,

    pub fn init(alloc: std.mem.Allocator, player_id: entity.ID) !*Encounter {
        var fsm = TurnFSM.init();

        // Turn phase transitions
        try fsm.addEventAndTransition(.begin_player_card_selection, .draw_hand, .player_card_selection);
        try fsm.addEventAndTransition(.begin_commit_phase, .player_card_selection, .commit_phase);
        try fsm.addEventAndTransition(.begin_tick_resolution, .commit_phase, .tick_resolution);
        try fsm.addEventAndTransition(.animate_resolution, .tick_resolution, .animating);
        try fsm.addEventAndTransition(.redraw, .animating, .draw_hand);

        const enc = try alloc.create(Encounter);
        enc.* = Encounter{
            .alloc = alloc,
            .enemies = try std.ArrayList(*combat.Agent).initCapacity(alloc, 5),
            .player_id = player_id,
            .engagements = std.AutoHashMap(AgentPair, Engagement).init(alloc),
            .agent_state = std.AutoHashMap(entity.ID, AgentEncounterState).init(alloc),
            .environment = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .thrown_by = std.AutoHashMap(entity.ID, entity.ID).init(alloc),
            .outcome = null,
            .turn_fsm = fsm,
        };
        // Initialize player's encounter state
        try enc.agent_state.put(player_id, .{});
        return enc;
    }

    pub fn deinit(self: *Encounter, agents: *SlotMap(*Agent)) void {
        for (self.enemies.items) |enemy| {
            agents.remove(enemy.id);
            enemy.deinit();
        }
        self.enemies.deinit(self.alloc);
        self.engagements.deinit();
        self.agent_state.deinit();
        self.environment.deinit(self.alloc);
        self.thrown_by.deinit();
        self.alloc.destroy(self);
    }

    /// Get engagement between two agents (order doesn't matter).
    pub fn getEngagement(self: *Encounter, a: entity.ID, b: entity.ID) ?*Engagement {
        return self.engagements.getPtr(AgentPair.canonical(a, b));
    }

    /// Get engagement between two agents (const version, returns value not pointer).
    pub fn getEngagementConst(self: *const Encounter, a: entity.ID, b: entity.ID) ?Engagement {
        return self.engagements.get(AgentPair.canonical(a, b));
    }

    /// Get engagement between player and a mob.
    pub fn getPlayerEngagement(self: *Encounter, mob_id: entity.ID) ?*Engagement {
        return self.getEngagement(self.player_id, mob_id);
    }

    /// Get engagement between player and a mob (const version).
    pub fn getPlayerEngagementConst(self: *const Encounter, mob_id: entity.ID) ?Engagement {
        return self.getEngagementConst(self.player_id, mob_id);
    }

    /// Set or create engagement between two agents.
    pub fn setEngagement(self: *Encounter, a: entity.ID, b: entity.ID, eng: Engagement) !void {
        try self.engagements.put(AgentPair.canonical(a, b), eng);
    }

    /// Add enemy and create default engagement with player.
    pub fn addEnemy(self: *Encounter, enemy: *Agent) !void {
        try self.enemies.append(self.alloc, enemy);
        try self.setEngagement(self.player_id, enemy.id, Engagement{});
        try self.agent_state.put(enemy.id, .{});
    }

    /// Get encounter state for an agent.
    pub fn stateFor(self: *Encounter, agent_id: entity.ID) ?*AgentEncounterState {
        return self.agent_state.getPtr(agent_id);
    }

    /// Get encounter state for an agent (const version for read-only access).
    pub fn stateForConst(self: *const Encounter, agent_id: entity.ID) ?*const AgentEncounterState {
        return self.agent_state.getPtr(agent_id);
    }

    /// Current turn phase.
    pub fn turnPhase(self: *const Encounter) TurnPhase {
        // Note: zigfsm.currentState requires mutable but doesn't actually mutate,
        // so we cast away const here for read-only access.
        const mutable_fsm: *TurnFSM = @constCast(&self.turn_fsm);
        return mutable_fsm.currentState();
    }

    /// Transition to a new turn phase (validates transition is allowed).
    pub fn transitionTurnTo(self: *Encounter, target: TurnPhase) !void {
        if (self.turn_fsm.canTransitionTo(target)) {
            try self.turn_fsm.transitionTo(target);
        } else {
            return error.InvalidTurnPhaseTransition;
        }
    }
};
