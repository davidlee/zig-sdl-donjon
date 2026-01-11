//! Range validation integration tests.
//!
//! Tests that attacks are properly validated at resolution time based on
//! weapon reach vs engagement range. Part of T009.

const std = @import("std");
const testing = std.testing;

const root = @import("integration_root");
const Harness = root.integration.harness.Harness;
const personas = root.data.personas;
const combat = root.domain.combat;

// ============================================================================
// Out of Range Scenarios
// ============================================================================

test "Attack at far range emits attack_out_of_range event" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup: use player_swordsman persona (default player has no weapon)
    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);

    // Setup: add enemy (default engagement range is .far)
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Verify starting range is far
    const eng = harness.getEngagement(enemy.id) orelse return error.NoEngagement;
    try testing.expectEqual(combat.Reach.far, eng.range);

    try harness.beginSelection();

    // Play thrust (weapon reach is .sabre, which is less than .far)
    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    // Commit and resolve
    try harness.commitPlays();
    try harness.transitionTo(.tick_resolution);
    harness.clearEvents();
    try harness.resolveTick();

    // Should emit attack_out_of_range, not technique_resolved
    try harness.expectEvent(.attack_out_of_range);
    try harness.expectNoEvent(.technique_resolved);
}

test "Attack at far range does not deal damage" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Record initial enemy state
    const initial_pain = enemy.pain.current;

    try harness.beginSelection();

    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    try harness.commitPlays();
    try harness.transitionTo(.tick_resolution);
    try harness.resolveTick();

    // Enemy should not have taken any damage (no pain increase)
    try testing.expectEqual(initial_pain, enemy.pain.current);
}

// ============================================================================
// In Range Scenarios
// ============================================================================

test "Attack at close range resolves normally" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Set range to sabre (matching weapon reach)
    harness.setRange(enemy.id, .sabre);

    try harness.beginSelection();

    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    try harness.commitPlays();
    try harness.transitionTo(.tick_resolution);
    harness.clearEvents();
    try harness.resolveTick();

    // Should emit technique_resolved, not attack_out_of_range
    try harness.expectResolutionEvent();
    try harness.expectNoEvent(.attack_out_of_range);
}

test "Attack with longer reach weapon hits at medium range" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Set range to longsword (player has sabre, which is shorter)
    harness.setRange(enemy.id, .longsword);

    try harness.beginSelection();

    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    try harness.commitPlays();
    try harness.transitionTo(.tick_resolution);
    harness.clearEvents();
    try harness.resolveTick();

    // Sabre reach < longsword range, so should be out of range
    try harness.expectEvent(.attack_out_of_range);
    try harness.expectNoEvent(.technique_resolved);
}

test "Attack at dagger range with sabre weapon hits" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Set range to dagger (closer than sabre reach)
    harness.setRange(enemy.id, .dagger);

    try harness.beginSelection();

    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    try harness.commitPlays();
    try harness.transitionTo(.tick_resolution);
    harness.clearEvents();
    try harness.resolveTick();

    // Sabre reach >= dagger range, so should resolve
    try harness.expectResolutionEvent();
    try harness.expectNoEvent(.attack_out_of_range);
}

// ============================================================================
// UI Warning State (CardStatus.has_valid_targets)
// ============================================================================

test "Card status shows warning when attack has no valid targets in range" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);
    _ = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    // Default engagement range is .far

    try harness.beginSelection();

    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;

    // Get card status from snapshot
    const status = try harness.getCardStatus(thrust_id) orelse
        return error.CardNotInSnapshot;

    // Card should be playable (no hard validation failures)
    try testing.expect(status.playable);

    // But has_valid_targets should be false (enemy is at far range, weapon is sabre)
    try testing.expect(!status.has_valid_targets);
}

test "Card status shows no warning when attack has valid targets in range" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Set range to sabre (matching weapon reach)
    harness.setRange(enemy.id, .sabre);

    try harness.beginSelection();

    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;

    const status = try harness.getCardStatus(thrust_id) orelse
        return error.CardNotInSnapshot;

    // Card should be playable
    try testing.expect(status.playable);

    // And has_valid_targets should be true (enemy is in range)
    try testing.expect(status.has_valid_targets);
}

// ============================================================================
// Advantage Threshold Filter (Riposte)
// ============================================================================

test "Riposte shows warning when control below threshold" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Set range to sabre (in weapon reach)
    harness.setRange(enemy.id, .sabre);

    // Set control below threshold (riposte requires >= 0.6)
    harness.setControl(enemy.id, 0.4);

    try harness.beginSelection();

    const riposte_id = harness.findAlwaysAvailable("riposte") orelse
        return error.RiposteNotFound;

    const status = try harness.getCardStatus(riposte_id) orelse
        return error.CardNotInSnapshot;

    // Card should be playable (no hard validation failures)
    try testing.expect(status.playable);

    // But has_valid_targets should be false (control < 0.6)
    try testing.expect(!status.has_valid_targets);
}

test "Riposte shows no warning when control meets threshold" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    try harness.setPlayerFromTemplate(&personas.Agents.player_swordsman);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Set range to sabre (in weapon reach)
    harness.setRange(enemy.id, .sabre);

    // Set control at threshold (riposte requires >= 0.6)
    harness.setControl(enemy.id, 0.7);

    try harness.beginSelection();

    const riposte_id = harness.findAlwaysAvailable("riposte") orelse
        return error.RiposteNotFound;

    const status = try harness.getCardStatus(riposte_id) orelse
        return error.CardNotInSnapshot;

    // Card should be playable
    try testing.expect(status.playable);

    // And has_valid_targets should be true (control >= 0.6)
    try testing.expect(status.has_valid_targets);
}
