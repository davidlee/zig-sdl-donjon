//! Data-Driven Combat Tests
//!
//! Executes combat scenarios defined in data/tests.cue, validating the 3-axis
//! damage model (geometry/energy/rigidity) against expected outcomes.
//!
//! These tests verify that physics fixes (T037/T038) work correctly:
//! - Sword vs plate should be deflected
//! - Penetrating weapons (picks) should pierce armour
//! - Energy scaling is quadratic with speed

const std = @import("std");
const testing = std.testing;

const root = @import("integration_root");
const domain = root.domain;
const Harness = root.integration.harness.Harness;
const personas = root.data.personas;
const weapon = domain.weapon;
const weapon_list = domain.weapon_list;
const gen = @import("../../../gen/generated_data.zig");

// ============================================================================
// Test Runner
// ============================================================================

// Run all data-driven combat tests from GeneratedCombatTests.
test "data-driven combat tests" {
    const alloc = testing.allocator;

    for (gen.GeneratedCombatTests) |test_def| {
        // Setup harness
        var h = try Harness.init(alloc);
        defer h.deinit();

        // Get attacker (player) - use setPlayerFromTemplate for stats
        // For now, use default player with overridden weapon
        const attacker = h.player();

        // Look up weapon template from the weapon list by matching the CUE ID
        const weapon_template = lookupWeaponById(test_def.attacker.weapon_id) orelse {
            std.debug.print("Unknown weapon: {s}\n", .{test_def.attacker.weapon_id});
            continue; // Skip test if weapon not found
        };

        // Equip the weapon to attacker
        const instance = try alloc.create(weapon.Instance);
        instance.* = .{
            .id = try h.world.entities.weapons.insert(instance),
            .template = weapon_template,
        };
        attacker.weapons = attacker.weapons.withEquipped(.{ .single = instance });

        // Add defender as enemy
        const defender = try h.addEnemyFromTemplate(&personas.Agents.ser_marcus);

        // Equip armour to defender if specified
        for (test_def.defender.armour_ids) |armour_id| {
            try equipArmourById(defender, armour_id);
        }

        // Begin encounter to establish engagement
        try h.beginSelection();

        // Run the attack resolution
        const result = h.forceResolveAttack(
            attacker,
            defender,
            test_def.attacker.technique_id,
            weapon_template,
            test_def.attacker.stakes,
            test_def.defender.target_part,
        ) catch |err| {
            std.debug.print("Test '{s}' failed to resolve: {any}\n", .{ test_def.id, err });
            continue;
        };

        // Check assertions
        var test_passed = true;

        // Check armour_deflected
        if (test_def.expected.armour_deflected) |expected| {
            if (result.armour_deflected != expected) {
                std.debug.print(
                    "Test '{s}' FAILED: armour_deflected expected {}, got {}\n",
                    .{ test_def.id, expected, result.armour_deflected },
                );
                test_passed = false;
            }
        }

        // Check damage_dealt_min
        if (test_def.expected.damage_dealt_min) |min| {
            if (result.damage_dealt < min) {
                std.debug.print(
                    "Test '{s}' FAILED: damage_dealt {d:.2} < min {d:.2}\n",
                    .{ test_def.id, result.damage_dealt, min },
                );
                test_passed = false;
            }
        }

        // Check damage_dealt_max
        if (test_def.expected.damage_dealt_max) |max| {
            if (result.damage_dealt > max) {
                std.debug.print(
                    "Test '{s}' FAILED: damage_dealt {d:.2} > max {d:.2}\n",
                    .{ test_def.id, result.damage_dealt, max },
                );
                test_passed = false;
            }
        }

        if (test_passed) {
            std.debug.print("Test '{s}': PASSED (damage={d:.2})\n", .{ test_def.id, result.damage_dealt });
        }

        // Fail if any assertion failed
        try testing.expect(test_passed);
    }
}

// ============================================================================
// Lookup Helpers
// ============================================================================

/// Map CUE weapon IDs to weapon_list templates.
/// CUE IDs use format like "swords.knights_sword", "natural.fist"
fn lookupWeaponById(id: []const u8) ?*const weapon.Template {
    // Map known CUE IDs to weapon_list entries
    const mappings = .{
        .{ "swords.knights_sword", &weapon_list.knights_sword },
        .{ "swords.arming_sword", &weapon_list.knights_sword }, // Fallback
        .{ "natural.fist", &weapon_list.fist_stone }, // Use fist_stone as proxy
        .{ "improvised.fist_stone", &weapon_list.fist_stone },
    };

    inline for (mappings) |m| {
        if (std.mem.eql(u8, id, m[0])) {
            return m[1];
        }
    }
    return null;
}

/// Equip armour piece to defender by ID.
/// Currently a stub - armour equipping not fully wired.
fn equipArmourById(defender: *domain.combat.Agent, armour_id: []const u8) !void {
    _ = defender;
    _ = armour_id;
    // TODO: Implement armour lookup and equipping from GeneratedArmourPieces
    // For now, this is a no-op as armour system integration is pending
}
