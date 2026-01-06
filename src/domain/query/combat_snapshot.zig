//! Combat Snapshot: Pre-computed validation results for UI consumption.
//!
//! This module provides a read-only snapshot of combat validation state,
//! decoupling the presentation layer from direct apply.* calls.
//! The snapshot is rebuilt once per tick (not per frame) and provides
//! O(1) lookups for card playability and play target information.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const combat = @import("../combat.zig");
const validation = @import("../apply/validation.zig");
const targeting = @import("../apply/targeting.zig");
const World = @import("../world.zig").World;
const Agent = combat.Agent;

/// Card playability status for UI display.
pub const CardStatus = struct {
    card_id: entity.ID,
    playable: bool,
};

/// Play status with resolved target information.
pub const PlayStatus = struct {
    play_index: usize,
    owner_id: entity.ID,
    target_id: ?entity.ID,
};

/// Pre-computed combat state for UI consumption.
pub const CombatSnapshot = struct {
    card_statuses: std.AutoHashMap(entity.ID, CardStatus),
    play_statuses: std.ArrayList(PlayStatus),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CombatSnapshot {
        return .{
            .card_statuses = std.AutoHashMap(entity.ID, CardStatus).init(allocator),
            .play_statuses = try std.ArrayList(PlayStatus).initCapacity(allocator, 8),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CombatSnapshot) void {
        self.card_statuses.deinit();
        self.play_statuses.deinit(self.allocator);
    }

    /// Query if a card is playable.
    pub fn isCardPlayable(self: *const CombatSnapshot, card_id: entity.ID) bool {
        if (self.card_statuses.get(card_id)) |status| {
            return status.playable;
        }
        return false;
    }

    /// Query the resolved target for a play by index.
    pub fn playTarget(self: *const CombatSnapshot, play_index: usize) ?entity.ID {
        for (self.play_statuses.items) |status| {
            if (status.play_index == play_index) {
                return status.target_id;
            }
        }
        return null;
    }
};

/// Build a combat snapshot from current world state.
/// Validates all player cards and resolves play targets.
pub fn buildSnapshot(allocator: std.mem.Allocator, world: *const World) !CombatSnapshot {
    var snapshot = try CombatSnapshot.init(allocator);
    errdefer snapshot.deinit();

    const player = world.player;
    const encounter = world.encounter orelse return snapshot;
    const phase = encounter.turnPhase();

    // Validate cards from all player sources
    try validateCards(&snapshot, allocator, player, phase, encounter, world);

    // Resolve play targets for commit phase
    try resolvePlayTargets(&snapshot, allocator, player.id, encounter, world);

    // Also resolve enemy play targets
    for (encounter.enemies.items) |enemy| {
        try resolvePlayTargets(&snapshot, allocator, enemy.id, encounter, world);
    }

    return snapshot;
}

/// Validate all cards from player's card sources.
fn validateCards(
    snapshot: *CombatSnapshot,
    allocator: std.mem.Allocator,
    player: *const Agent,
    phase: combat.TurnPhase,
    encounter: *const combat.Encounter,
    world: *const World,
) !void {
    _ = allocator; // Reserved for future use

    // Hand cards
    if (player.combat_state) |cs| {
        for (cs.hand.items) |card_id| {
            const inst = world.card_registry.getConst(card_id) orelse continue;
            const playable = validation.validateCardSelection(player, inst, phase, encounter) catch false;
            try snapshot.card_statuses.put(card_id, .{ .card_id = card_id, .playable = playable });
        }

        // In-play cards (for modifier stacking validation)
        for (cs.in_play.items) |card_id| {
            const inst = world.card_registry.getConst(card_id) orelse continue;
            const playable = validation.validateCardSelection(player, inst, phase, encounter) catch false;
            try snapshot.card_statuses.put(card_id, .{ .card_id = card_id, .playable = playable });
        }
    }

    // Always-available techniques
    for (player.always_available.items) |card_id| {
        const inst = world.card_registry.getConst(card_id) orelse continue;
        const playable = validation.validateCardSelection(player, inst, phase, encounter) catch false;
        try snapshot.card_statuses.put(card_id, .{ .card_id = card_id, .playable = playable });
    }

    // Spells known
    for (player.spells_known.items) |card_id| {
        const inst = world.card_registry.getConst(card_id) orelse continue;
        const playable = validation.validateCardSelection(player, inst, phase, encounter) catch false;
        try snapshot.card_statuses.put(card_id, .{ .card_id = card_id, .playable = playable });
    }
}

/// Resolve targets for all plays in an agent's current turn.
fn resolvePlayTargets(
    snapshot: *CombatSnapshot,
    allocator: std.mem.Allocator,
    agent_id: entity.ID,
    encounter: *const combat.Encounter,
    world: *const World,
) !void {
    const agent_state = encounter.stateForConst(agent_id) orelse return;
    const agent_ptr = world.entities.agents.get(agent_id) orelse return;

    for (agent_state.current.slots(), 0..) |slot, i| {
        var target_id: ?entity.ID = null;

        // Resolve target for offensive plays (agent_ptr is **Agent, need *Agent)
        if (targeting.resolvePlayTargetIDs(allocator, &slot.play, agent_ptr.*, world) catch null) |ids| {
            defer allocator.free(ids);
            if (ids.len > 0) {
                target_id = ids[0];
            }
        }

        try snapshot.play_statuses.append(snapshot.allocator, .{
            .play_index = i,
            .owner_id = agent_id,
            .target_id = target_id,
        });
    }
}

// Tests
const testing = std.testing;

test "empty snapshot returns false for unknown cards" {
    var snapshot = try CombatSnapshot.init(testing.allocator);
    defer snapshot.deinit();

    const fake_id = entity.ID{ .index = 0, .generation = 0 };
    try testing.expect(!snapshot.isCardPlayable(fake_id));
}

test "playTarget returns null for unknown play" {
    var snapshot = try CombatSnapshot.init(testing.allocator);
    defer snapshot.deinit();

    try testing.expect(snapshot.playTarget(0) == null);
}
