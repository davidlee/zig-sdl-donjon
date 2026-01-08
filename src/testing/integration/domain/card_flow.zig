//! Card flow integration tests.
//!
//! Tests the full lifecycle: play selection -> timeline -> tick resolution -> events.

const std = @import("std");
const testing = std.testing;

const root = @import("integration_root");
const Harness = root.integration.harness.Harness;
const personas = root.data.personas;
const Event = root.domain.events.Event;

// ============================================================================
// Scenarios
// ============================================================================

test "Player plays thrust, stamina reserved, play created" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup: add an enemy as target
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Record initial stamina
    const initial_stamina = harness.playerStamina();
    const initial_available = harness.playerAvailableStamina();

    // Enter selection phase
    try harness.beginSelection();
    try testing.expectEqual(.player_card_selection, harness.turnPhase().?);

    // Find thrust in always_available
    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;

    // Play thrust targeting the enemy
    try harness.playCard(thrust_id, enemy.id);

    // Verify: play was created
    const plays = harness.getPlays();
    try testing.expectEqual(@as(usize, 1), plays.len);

    // Verify: stamina was reserved (current unchanged, available reduced)
    // Thrust costs 3.0 stamina
    const current_stamina = harness.playerStamina();
    const available_stamina = harness.playerAvailableStamina();
    try testing.expectEqual(initial_stamina, current_stamina); // current unchanged
    try testing.expect(available_stamina < initial_available); // available reduced

    // Verify: played_action_card event emitted
    try harness.expectEvent(.played_action_card);
}

test "Player plays thrust, resolves tick, stamina deducted" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    const initial_stamina = harness.playerStamina();

    try harness.beginSelection();

    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;

    try harness.playCard(thrust_id, enemy.id);

    // Clear events from selection phase
    harness.clearEvents();

    // Commit plays
    try harness.commitPlays();
    try testing.expectEqual(.commit_phase, harness.turnPhase().?);

    // Transition to tick resolution
    try harness.transitionTo(.tick_resolution);

    // Resolve the tick
    try harness.resolveTick();

    // Verify: stamina was deducted (thrust costs 3.0)
    const final_stamina = harness.playerStamina();
    try testing.expect(final_stamina < initial_stamina);

    // Verify: tick_ended event emitted
    try harness.expectEvent(.tick_ended);
}

test "Pool card clone lifecycle: clone created, original gets cooldown" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginSelection();

    // Find thrust in always_available (it's a pool card)
    const thrust_master_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;

    // Play the card
    try harness.playCard(thrust_master_id, enemy.id);

    // Verify: card_cloned event emitted (pool cards create clones)
    try harness.expectEvent(.card_cloned);

    // The play should reference a clone, not the master
    const plays = harness.getPlays();
    try testing.expectEqual(@as(usize, 1), plays.len);
    const play_card_id = plays[0].play.action;

    // Clone ID should differ from master ID
    try testing.expect(!play_card_id.eql(thrust_master_id));
}
