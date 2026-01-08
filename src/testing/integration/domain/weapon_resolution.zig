//! Weapon resolution integration tests.
//!
//! Tests that the correct weapon is used during attack resolution
//! based on equipped weapons, natural weapons, and channel overrides.

const std = @import("std");
const testing = std.testing;

const root = @import("integration_root");
const Harness = root.integration.harness.Harness;
const personas = root.data.personas;
const weapon_list = root.domain.weapon_list;

// ============================================================================
// Scenarios
// ============================================================================

test "Technique resolves with equipped weapon (not hardcoded)" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup: player with knight's sword, enemy as target at melee range
    try harness.setPlayerFromTemplate(&personas.Agents.ser_marcus);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    harness.setRange(enemy.id, .sabre); // melee range

    try harness.beginSelection();

    // Play thrust targeting the enemy
    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    // Commit and resolve
    try harness.commitPlays();
    try harness.transitionTo(.tick_resolution);
    harness.clearEvents();
    try harness.resolveTick();

    // Verify: technique resolved with knight's sword (from ser_marcus template)
    const weapon_name = harness.getResolvedWeaponName() orelse
        return error.NoTechniqueResolved;
    try testing.expectEqualStrings("knight's sword", weapon_name);
}

test "Unarmed attack uses natural weapon (fist)" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup: unarmed player (uses natural weapons)
    try harness.setPlayerFromTemplate(&personas.Agents.brawler);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    harness.setRange(enemy.id, .clinch); // fist reach

    try harness.beginSelection();

    // Slash uses swing attack mode (compatible with fist's punch)
    const slash_id = harness.findAlwaysAvailable("slash") orelse
        return error.SlashNotFound;
    try harness.playCard(slash_id, enemy.id);

    try harness.commitPlays();
    try harness.transitionTo(.tick_resolution);
    harness.clearEvents();
    try harness.resolveTick();

    // Verify: attack used Fist (natural weapon from dwarf species)
    const weapon_name = harness.getResolvedWeaponName() orelse
        return error.NoTechniqueResolved;
    try testing.expectEqualStrings("Fist", weapon_name);
}

test "Dual-wield main hand attack uses primary weapon" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // Setup: player with dual wield (sword + buckler)
    try harness.setPlayerFromTemplate(&personas.Agents.sword_and_board);
    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);
    harness.setRange(enemy.id, .sabre); // melee range

    try harness.beginSelection();

    // Thrust uses weapon channel (primary)
    const thrust_id = harness.findAlwaysAvailable("thrust") orelse
        return error.ThrustNotFound;
    try harness.playCard(thrust_id, enemy.id);

    try harness.commitPlays();
    try harness.transitionTo(.tick_resolution);
    harness.clearEvents();
    try harness.resolveTick();

    // Verify: attack used knight's sword (primary weapon)
    const weapon_name = harness.getResolvedWeaponName() orelse
        return error.NoTechniqueResolved;
    try testing.expectEqualStrings("knight's sword", weapon_name);
}
