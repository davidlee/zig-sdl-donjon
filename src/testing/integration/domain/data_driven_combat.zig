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
const armour = domain.armour;
const armour_list = domain.armour_list;
const gen = @import("../../../gen/generated_data.zig");

// ============================================================================
// Test Runner
// ============================================================================

// Run all data-driven combat tests from GeneratedCombatTests.
test "data-driven combat tests" {
    const alloc = testing.allocator;

    // Optional runtime filter from environment
    const filter = std.posix.getenv("COMBAT_TEST_FILTER");

    // Accumulator for results
    const TestResult = struct {
        id: []const u8,
        passed: bool,
        failure_reason: ?[]const u8 = null,
        damage_dealt: f32 = 0,
    };

    var results = std.ArrayList(TestResult){};
    defer results.deinit(alloc);

    for (gen.GeneratedCombatTests) |test_def| {
        // Apply filter if set
        if (filter) |f| {
            if (std.mem.indexOf(u8, test_def.id, f) == null) continue;
        }

        // Setup harness
        var h = try Harness.init(alloc);
        defer h.deinit();

        // Get attacker (player)
        const attacker = h.player();

        // Look up weapon template
        const weapon_template = lookupWeaponById(test_def.attacker.weapon_id) orelse {
            try results.append(alloc, .{ .id = test_def.id, .passed = false, .failure_reason = "unknown weapon" });
            continue;
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
        var armour_instances = try std.ArrayList(*armour.Instance).initCapacity(alloc, test_def.defender.armour_ids.len);
        defer {
            for (armour_instances.items) |inst| {
                inst.deinit(alloc);
                alloc.destroy(inst);
            }
            armour_instances.deinit(alloc);
        }

        for (test_def.defender.armour_ids) |armour_id| {
            try equipArmourById(alloc, defender, armour_id, &armour_instances);
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
            const msg = std.fmt.allocPrint(alloc, "resolution error: {any}", .{err}) catch "resolution error";
            try results.append(alloc, .{ .id = test_def.id, .passed = false, .failure_reason = msg });
            continue;
        };

        // Check assertions
        var failure_reason: ?[]const u8 = null;

        if (test_def.expected.armour_deflected) |expected| {
            if (result.armour_deflected != expected) {
                failure_reason = if (expected) "expected armour deflection" else "unexpected armour deflection";
            }
        }

        if (failure_reason == null) {
            if (test_def.expected.damage_dealt_min) |min| {
                if (result.damage_dealt < min) {
                    failure_reason = std.fmt.allocPrint(alloc, "damage {d:.2} < min {d:.2}", .{ result.damage_dealt, min }) catch "damage below min";
                }
            }
        }

        if (failure_reason == null) {
            if (test_def.expected.damage_dealt_max) |max| {
                if (result.damage_dealt > max) {
                    failure_reason = std.fmt.allocPrint(alloc, "damage {d:.2} > max {d:.2}", .{ result.damage_dealt, max }) catch "damage above max";
                }
            }
        }

        try results.append(alloc, .{
            .id = test_def.id,
            .passed = failure_reason == null,
            .failure_reason = failure_reason,
            .damage_dealt = result.damage_dealt,
        });
    }

    // Report summary
    var passed: usize = 0;
    var failed: usize = 0;
    for (results.items) |r| {
        if (r.passed) passed += 1 else failed += 1;
    }

    std.debug.print("\n=== Combat Test Summary ===\n", .{});
    std.debug.print("Passed: {d}/{d}\n", .{ passed, passed + failed });

    if (failed > 0) {
        std.debug.print("\nFailures:\n", .{});
        for (results.items) |r| {
            if (!r.passed) {
                std.debug.print("  - {s}: {s}\n", .{ r.id, r.failure_reason orelse "unknown" });
            }
        }
    }

    std.debug.print("\nDetails:\n", .{});
    for (results.items) |r| {
        const status = if (r.passed) "PASS" else "FAIL";
        std.debug.print("  [{s}] {s} (damage={d:.2})\n", .{ status, r.id, r.damage_dealt });
    }

    try testing.expect(failed == 0);
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
fn equipArmourById(
    alloc: std.mem.Allocator,
    defender: *domain.combat.Agent,
    armour_id: []const u8,
    tracker: *std.ArrayList(*armour.Instance),
) !void {
    // 1. Lookup template from generated registry
    const template = armour_list.getTemplateRuntime(armour_id) orelse {
        std.debug.print("Unknown armour ID: {s}\n", .{armour_id});
        return error.UnknownArmourId;
    };

    // 2. Create instance
    const inst = try alloc.create(armour.Instance);
    inst.* = try armour.Instance.init(alloc, template, null);
    try tracker.append(alloc, inst);

    // 3. Rebuild stack with new armour + any existing tracked armour
    // Note: This rebuilds from scratch each time, which is fine for test setup
    try defender.armour.buildFromEquipped(&defender.body, tracker.items);
}
