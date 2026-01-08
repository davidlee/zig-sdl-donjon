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

// ============================================================================
// Cancel Workflow
// ============================================================================

test "Cancel pool card: clone destroyed, stamina returned" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginSelection();

    const thrust_master_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;

    // Record initial state
    const initial_available = harness.playerAvailableStamina();

    // Play the card (creates clone)
    try harness.playCard(thrust_master_id, enemy.id);

    // Get the clone ID from the play
    const plays = harness.getPlays();
    const clone_id = plays[0].play.action;

    // Verify clone differs from master
    try testing.expect(!clone_id.eql(thrust_master_id));

    // Clear events from play
    harness.clearEvents();

    // Cancel the play
    try harness.cancelCard(clone_id);

    // Verify: play removed
    try testing.expectEqual(@as(usize, 0), harness.getPlays().len);

    // Verify: stamina returned
    try testing.expectEqual(initial_available, harness.playerAvailableStamina());

    // Verify: card_cancelled event emitted (uses master_id since clone is destroyed)
    try harness.expectEvent(.card_cancelled);
}

test "Cancel hand card: card returned to hand, time returned" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup - need an enemy for encounter but card targets self
    _ = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginSelection();

    // Give a hand card (breath work targets .self, playable from hand)
    const card_id = try harness.giveCard(harness.player(), "breath work");

    // Record initial state
    const initial_time = harness.player().time_available;
    try testing.expect(harness.isInHand(card_id));

    // Play the card (targets self, no enemy target needed)
    try harness.playCard(card_id, null);

    // Verify: card removed from hand, play created
    try testing.expect(!harness.isInHand(card_id));
    try testing.expectEqual(@as(usize, 1), harness.getPlays().len);

    // Verify: time was reserved
    try testing.expect(harness.player().time_available < initial_time);

    // Clear events from play
    harness.clearEvents();

    // Cancel the play
    try harness.cancelCard(card_id);

    // Verify: play removed
    try testing.expectEqual(@as(usize, 0), harness.getPlays().len);

    // Verify: card returned to hand
    try testing.expect(harness.isInHand(card_id));

    // Verify: time returned
    try testing.expectEqual(initial_time, harness.player().time_available);

    // Verify: card_moved event emitted (not card_cancelled - that's for clones)
    try harness.expectEvent(.card_moved);
}

// ============================================================================
// Commit Phase Workflow
// ============================================================================

test "Withdraw play in commit phase: card returned, focus spent" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginSelection();

    // Give a hand card for withdraw test (hand cards can be withdrawn)
    const card_id = try harness.giveCard(harness.player(), "breath work");
    const initial_focus = harness.playerFocus();

    // Play the card
    try harness.playCard(card_id, null);
    try testing.expectEqual(@as(usize, 1), harness.getPlays().len);

    // Transition to commit phase
    try harness.commitPlays();
    try testing.expectEqual(.commit_phase, harness.turnPhase().?);

    harness.clearEvents();

    // Withdraw the play (costs 1 focus)
    try harness.withdrawCard(card_id);

    // Verify: play removed
    try testing.expectEqual(@as(usize, 0), harness.getPlays().len);

    // Verify: card returned to hand
    try testing.expect(harness.isInHand(card_id));

    // Verify: focus spent (1 focus for withdraw)
    try testing.expectEqual(initial_focus - 1.0, harness.playerFocus());

    // Verify: card_moved event emitted
    try harness.expectEvent(.card_moved);

    _ = enemy; // silence unused warning
}

test "Stack modifier in commit phase: modifier added to play" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginSelection();

    // Play thrust (offensive action for modifier target)
    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    // Give a modifier card (high - targets offensive plays)
    const high_id = try harness.giveCard(harness.player(), "high");

    // Transition to commit phase
    try harness.commitPlays();

    const initial_focus = harness.playerFocus();
    harness.clearEvents();

    // Stack the modifier on the play (index 0)
    try harness.stackModifier(high_id, 0);

    // Verify: modifier added to play
    const plays = harness.getPlays();
    try testing.expectEqual(@as(usize, 1), plays.len);
    try testing.expectEqual(@as(usize, 1), plays[0].play.modifier_stack_len);

    // Verify: focus spent (1 focus for first stack)
    try testing.expectEqual(initial_focus - 1.0, harness.playerFocus());
}

// ============================================================================
// Turn Lifecycle / Event Processor
// ============================================================================

test "Full turn cycle: selection -> commit -> resolve -> cleanup" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginSelection();

    // Play a card
    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    // Verify: in selection phase with one play
    try testing.expectEqual(.player_card_selection, harness.turnPhase().?);
    try testing.expectEqual(@as(usize, 1), harness.getPlays().len);

    // Commit
    try harness.commitPlays();
    try testing.expectEqual(.commit_phase, harness.turnPhase().?);

    // Resolve all ticks
    try harness.resolveAllTicks();

    // After resolution, timeline should be cleared
    try testing.expectEqual(@as(usize, 0), harness.getPlays().len);

    // Verify tick events were emitted
    try harness.expectEvent(.tick_ended);
}

test "Tick resolution emits technique_resolved event" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginSelection();

    // Play thrust
    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    // Commit and resolve
    try harness.commitPlays();
    harness.clearEvents();

    try harness.transitionTo(.tick_resolution);
    try harness.resolveTick();

    // Verify technique was resolved
    try harness.expectEvent(.technique_resolved);
}
