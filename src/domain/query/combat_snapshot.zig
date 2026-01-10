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
const cards = @import("../cards.zig");
const validation = @import("../apply/validation.zig");
const targeting = @import("../apply/targeting.zig");
const World = @import("../world.zig").World;
const Agent = combat.Agent;

/// Key for modifier-to-play attachment lookup.
const ModifierPlayKey = struct {
    modifier_id: entity.ID,
    play_index: usize,
};

/// Card playability status for UI display.
pub const CardStatus = struct {
    card_id: entity.ID,
    playable: bool,
    /// True if card has at least one valid target currently.
    /// For melee attacks: any enemy in weapon reach.
    /// For non-targeting cards: always true.
    has_valid_targets: bool,
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
    /// Maps (modifier_id, play_index) -> true for valid attachments.
    /// Absence from map means attachment not allowed.
    modifier_attachability: std.AutoHashMap(ModifierPlayKey, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CombatSnapshot {
        return .{
            .card_statuses = std.AutoHashMap(entity.ID, CardStatus).init(allocator),
            .play_statuses = try std.ArrayList(PlayStatus).initCapacity(allocator, 8),
            .modifier_attachability = std.AutoHashMap(ModifierPlayKey, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CombatSnapshot) void {
        self.card_statuses.deinit();
        self.play_statuses.deinit(self.allocator);
        self.modifier_attachability.deinit();
    }

    /// Query if a card is playable.
    pub fn isCardPlayable(self: *const CombatSnapshot, card_id: entity.ID) bool {
        if (self.card_statuses.get(card_id)) |status| {
            return status.playable;
        }
        return false;
    }

    /// Query if a card has valid targets currently.
    pub fn cardHasValidTargets(self: *const CombatSnapshot, card_id: entity.ID) bool {
        if (self.card_statuses.get(card_id)) |status| {
            return status.has_valid_targets;
        }
        return true; // Unknown cards assumed to have valid targets
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

    /// Query if a modifier can attach to a play (predicate match only).
    /// Does not check for conflicts - caller should also check play.wouldConflict().
    pub fn canModifierAttachToPlay(self: *const CombatSnapshot, modifier_id: entity.ID, play_index: usize) bool {
        return self.modifier_attachability.contains(.{ .modifier_id = modifier_id, .play_index = play_index });
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

    // Compute which modifiers can attach to which plays
    try computeModifierAttachability(&snapshot, player, encounter, world);

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
            const has_targets = targeting.hasAnyValidTarget(inst, player, world);
            try snapshot.card_statuses.put(card_id, .{
                .card_id = card_id,
                .playable = playable,
                .has_valid_targets = has_targets,
            });
        }

        // In-play cards from timeline (for modifier stacking validation)
        if (encounter.stateForConst(player.id)) |enc_state| {
            for (enc_state.current.timeline.slots()) |slot| {
                // Action card
                const action_inst = world.card_registry.getConst(slot.play.action) orelse continue;
                const action_playable = validation.validateCardSelection(player, action_inst, phase, encounter) catch false;
                const action_has_targets = targeting.hasAnyValidTarget(action_inst, player, world);
                try snapshot.card_statuses.put(slot.play.action, .{
                    .card_id = slot.play.action,
                    .playable = action_playable,
                    .has_valid_targets = action_has_targets,
                });

                // Modifier cards
                for (slot.play.modifiers()) |mod| {
                    const mod_inst = world.card_registry.getConst(mod.card_id) orelse continue;
                    const mod_playable = validation.validateCardSelection(player, mod_inst, phase, encounter) catch false;
                    // Modifiers don't have range requirements themselves
                    try snapshot.card_statuses.put(mod.card_id, .{
                        .card_id = mod.card_id,
                        .playable = mod_playable,
                        .has_valid_targets = true,
                    });
                }
            }
        }
    }

    // Always-available techniques
    for (player.always_available.items) |card_id| {
        const inst = world.card_registry.getConst(card_id) orelse continue;
        const playable = validation.validateCardSelection(player, inst, phase, encounter) catch false;
        const has_targets = targeting.hasAnyValidTarget(inst, player, world);
        try snapshot.card_statuses.put(card_id, .{
            .card_id = card_id,
            .playable = playable,
            .has_valid_targets = has_targets,
        });
    }

    // Spells known
    for (player.spells_known.items) |card_id| {
        const inst = world.card_registry.getConst(card_id) orelse continue;
        const playable = validation.validateCardSelection(player, inst, phase, encounter) catch false;
        const has_targets = targeting.hasAnyValidTarget(inst, player, world);
        try snapshot.card_statuses.put(card_id, .{
            .card_id = card_id,
            .playable = playable,
            .has_valid_targets = has_targets,
        });
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

/// Compute which modifiers can attach to which plays.
/// Only considers player's modifiers and player's current plays.
fn computeModifierAttachability(
    snapshot: *CombatSnapshot,
    player: *const Agent,
    encounter: *const combat.Encounter,
    world: *const World,
) !void {
    const player_state = encounter.stateForConst(player.id) orelse return;
    const slots = player_state.current.slots();
    if (slots.len == 0) return;

    // Collect modifier card IDs from player's card sources
    const cs = player.combat_state orelse return;

    // Check hand cards
    for (cs.hand.items) |card_id| {
        try checkModifierAgainstPlays(snapshot, card_id, slots, world);
    }

    // Check always-available (some might be modifiers)
    for (player.always_available.items) |card_id| {
        try checkModifierAgainstPlays(snapshot, card_id, slots, world);
    }
}

/// Check a single card against all plays, storing attachability if it's a modifier.
fn checkModifierAgainstPlays(
    snapshot: *CombatSnapshot,
    card_id: entity.ID,
    slots: []const combat.TimeSlot,
    world: *const World,
) !void {
    const inst = world.card_registry.getConst(card_id) orelse return;
    if (inst.template.kind != .modifier) return;

    for (slots, 0..) |slot, play_index| {
        const can_attach = targeting.canModifierAttachToPlay(inst.template, &slot.play, world) catch false;
        if (can_attach) {
            try snapshot.modifier_attachability.put(.{
                .modifier_id = card_id,
                .play_index = play_index,
            }, {});
        }
    }
}

// Tests
const testing = std.testing;

test "empty snapshot returns false for unknown cards" {
    var snapshot = try CombatSnapshot.init(testing.allocator);
    defer snapshot.deinit();

    const fake_id = entity.ID{ .index = 0, .generation = 0, .kind = .action };
    try testing.expect(!snapshot.isCardPlayable(fake_id));
}

test "playTarget returns null for unknown play" {
    var snapshot = try CombatSnapshot.init(testing.allocator);
    defer snapshot.deinit();

    try testing.expect(snapshot.playTarget(0) == null);
}

test "canModifierAttachToPlay returns false for unknown modifier" {
    var snapshot = try CombatSnapshot.init(testing.allocator);
    defer snapshot.deinit();

    const fake_id = entity.ID{ .index = 0, .generation = 0, .kind = .action };
    try testing.expect(!snapshot.canModifierAttachToPlay(fake_id, 0));
}
