//! Stance phase integration tests.
//!
//! Tests the stance selection phase flow: stance_selection -> draw_hand -> player_card_selection.

const std = @import("std");
const testing = std.testing;

const root = @import("integration_root");
const Harness = root.integration.harness.Harness;
const personas = root.data.personas;

// ============================================================================
// Scenarios
// ============================================================================

test "Encounter starts in stance_selection phase" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Add enemy so encounter is valid
    _ = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    // Start encounter (without bypassing stance phase)
    try harness.beginStanceSelection();

    // Verify we're in stance_selection phase
    try testing.expectEqual(.stance_selection, harness.turnPhase().?);
}

test "Confirm stance transitions to draw_hand then player_card_selection" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    _ = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginStanceSelection();

    // Confirm stance with balanced weights
    try harness.confirmStance(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0);

    // After confirm_stance, should transition through draw_hand to player_card_selection
    // (draw_hand is an automatic transition when hand is empty/needs drawing)
    const phase = harness.turnPhase().?;
    // Could be draw_hand (if awaiting event processing) or player_card_selection (if processed)
    try testing.expect(phase == .draw_hand or phase == .player_card_selection);
}

test "Stance weights are stored in turn state" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    _ = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    try harness.beginStanceSelection();

    // Confirm with attack-heavy stance
    try harness.confirmStance(0.6, 0.2, 0.2);

    // Verify stance was stored
    const enc_state = harness.encounter().stateFor(harness.player().id).?;
    try testing.expectApproxEqAbs(@as(f32, 0.6), enc_state.current.stance.attack, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.2), enc_state.current.stance.defense, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.2), enc_state.current.stance.movement, 0.01);
}
