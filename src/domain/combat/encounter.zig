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
pub const AttentionState = plays.AttentionState;
pub const AgentPair = engagement_mod.AgentPair;
pub const Engagement = engagement_mod.Engagement;
pub const FlankingStatus = engagement_mod.FlankingStatus;
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
        try fsm.addEventAndTransition(.confirm_stance, .stance_selection, .draw_hand);
        try fsm.addEventAndTransition(.begin_player_card_selection, .draw_hand, .player_card_selection);
        try fsm.addEventAndTransition(.begin_commit_phase, .player_card_selection, .commit_phase);
        try fsm.addEventAndTransition(.begin_tick_resolution, .commit_phase, .tick_resolution);
        try fsm.addEventAndTransition(.animate_resolution, .tick_resolution, .animating);
        try fsm.addEventAndTransition(.redraw, .animating, .stance_selection);

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
        self.initAttentionFor(enemy.id, enemy.stats.acuity);
    }

    /// Get encounter state for an agent.
    pub fn stateFor(self: *Encounter, agent_id: entity.ID) ?*AgentEncounterState {
        return self.agent_state.getPtr(agent_id);
    }

    /// Get encounter state for an agent (const version for read-only access).
    pub fn stateForConst(self: *const Encounter, agent_id: entity.ID) ?*const AgentEncounterState {
        return self.agent_state.getPtr(agent_id);
    }

    /// Initialize attention state for an agent from their acuity stat.
    pub fn initAttentionFor(self: *Encounter, agent_id: entity.ID, acuity: f32) void {
        if (self.agent_state.getPtr(agent_id)) |state| {
            state.attention = AttentionState.init(acuity);
        }
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

    /// Force transition without FSM validation. For tests only.
    pub fn forceTransitionTo(self: *Encounter, target: TurnPhase) void {
        self.turn_fsm.transitionToSilently(target, false) catch unreachable;
    }

    /// Assess flanking status for an agent based on engagement count and position values.
    /// Position < 0.35 means the *other* agent has angle advantage on us.
    pub fn assessFlanking(self: *const Encounter, agent_id: entity.ID) FlankingStatus {
        // Get list of opponents for this agent
        const is_player = agent_id.eql(self.player_id);
        const opponents: []const *combat.Agent = if (is_player) self.enemies.items else &[_]*combat.Agent{};

        if (!is_player) {
            // For enemies, they're engaged with the player only (for now)
            if (self.getEngagementConst(agent_id, self.player_id)) |eng| {
                // From enemy's perspective, check inverted position
                const inverted = eng.invert();
                if (inverted.position < 0.35) {
                    return .partial; // Player has angle on this enemy
                }
            }
            return .none;
        }

        // Player case: check all enemy engagements
        const active_count = opponents.len;
        if (active_count <= 1) return .none;

        var flanking_enemies: u8 = 0;
        for (opponents) |enemy| {
            if (self.getEngagementConst(self.player_id, enemy.id)) |eng| {
                // Position < 0.35 means enemy has angle advantage on player
                if (eng.position < 0.35) flanking_enemies += 1;
            }
        }

        if (flanking_enemies >= 2 or active_count >= 3) return .surrounded;
        if (flanking_enemies >= 1) return .partial;
        return .none;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const stats = @import("../stats.zig");
const species = @import("../species.zig");
const ai = @import("../ai.zig");

fn makeTestEncounter(alloc: std.mem.Allocator, agents: *SlotMap(*Agent)) !struct { enc: *Encounter, player: *Agent } {
    const player = try Agent.init(
        alloc,
        agents,
        .player,
        .shuffled_deck,
        &species.DWARF,
        stats.Block.splat(5),
    );

    const enc = try Encounter.init(alloc, player.id);
    return .{ .enc = enc, .player = player };
}

fn makeTestEnemy(alloc: std.mem.Allocator, agents: *SlotMap(*Agent)) !*Agent {
    return Agent.init(
        alloc,
        agents,
        ai.noop(),
        .shuffled_deck,
        &species.DWARF,
        stats.Block.splat(5),
    );
}

test "assessFlanking returns none for single opponent" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc, .agent);
    defer agents.deinit();

    const setup = try makeTestEncounter(alloc, &agents);
    defer setup.enc.deinit(&agents);
    defer setup.player.deinit();

    const enemy = try makeTestEnemy(alloc, &agents);
    try setup.enc.addEnemy(enemy);

    // Single opponent = no flanking
    try testing.expectEqual(FlankingStatus.none, setup.enc.assessFlanking(setup.player.id));
}

test "assessFlanking returns partial when one enemy has angle advantage" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc, .agent);
    defer agents.deinit();

    const setup = try makeTestEncounter(alloc, &agents);
    defer setup.enc.deinit(&agents);
    defer setup.player.deinit();

    // Add two enemies
    const enemy1 = try makeTestEnemy(alloc, &agents);
    const enemy2 = try makeTestEnemy(alloc, &agents);
    try setup.enc.addEnemy(enemy1);
    try setup.enc.addEnemy(enemy2);

    // Set one engagement to have enemy advantage (position < 0.35)
    if (setup.enc.getEngagement(setup.player.id, enemy1.id)) |eng| {
        eng.position = 0.30; // enemy1 has angle
    }
    // enemy2 has neutral position (default 0.5)

    try testing.expectEqual(FlankingStatus.partial, setup.enc.assessFlanking(setup.player.id));
}

test "assessFlanking returns surrounded with 3+ enemies" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc, .agent);
    defer agents.deinit();

    const setup = try makeTestEncounter(alloc, &agents);
    defer setup.enc.deinit(&agents);
    defer setup.player.deinit();

    // Add three enemies
    const enemy1 = try makeTestEnemy(alloc, &agents);
    const enemy2 = try makeTestEnemy(alloc, &agents);
    const enemy3 = try makeTestEnemy(alloc, &agents);
    try setup.enc.addEnemy(enemy1);
    try setup.enc.addEnemy(enemy2);
    try setup.enc.addEnemy(enemy3);

    // 3+ enemies = surrounded regardless of position
    try testing.expectEqual(FlankingStatus.surrounded, setup.enc.assessFlanking(setup.player.id));
}

test "assessFlanking returns surrounded when 2+ enemies have angle advantage" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc, .agent);
    defer agents.deinit();

    const setup = try makeTestEncounter(alloc, &agents);
    defer setup.enc.deinit(&agents);
    defer setup.player.deinit();

    // Add two enemies
    const enemy1 = try makeTestEnemy(alloc, &agents);
    const enemy2 = try makeTestEnemy(alloc, &agents);
    try setup.enc.addEnemy(enemy1);
    try setup.enc.addEnemy(enemy2);

    // Both enemies have angle advantage
    if (setup.enc.getEngagement(setup.player.id, enemy1.id)) |eng| {
        eng.position = 0.25;
    }
    if (setup.enc.getEngagement(setup.player.id, enemy2.id)) |eng| {
        eng.position = 0.30;
    }

    try testing.expectEqual(FlankingStatus.surrounded, setup.enc.assessFlanking(setup.player.id));
}
