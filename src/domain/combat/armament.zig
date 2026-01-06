//! Armament - weapon configuration for combat agents.
//!
//! Handles single weapons, dual-wielding, and compound weapon sets.

const std = @import("std");
const weapon = @import("../weapon.zig");
const cards = @import("../cards.zig");

/// Weapon configuration for an agent.
pub const Armament = union(enum) {
    single: *weapon.Instance,
    dual: struct {
        primary: *weapon.Instance,
        secondary: *weapon.Instance,
    },
    compound: [][]*weapon.Instance,

    pub fn hasCategory(self: Armament, cat: weapon.Category) bool {
        return switch (self) {
            .single => |w| hasWeaponCategory(w.template, cat),
            .dual => |d| hasWeaponCategory(d.primary.template, cat) or
                hasWeaponCategory(d.secondary.template, cat),
            .compound => |sets| {
                for (sets) |set| {
                    for (set) |w| {
                        if (hasWeaponCategory(w.template, cat)) return true;
                    }
                }
                return false;
            },
        };
    }

    fn hasWeaponCategory(template: *const weapon.Template, cat: weapon.Category) bool {
        for (template.categories) |c| {
            if (c == cat) return true;
        }
        return false;
    }

    /// Get the offensive mode (swing/thrust) from the primary weapon for a given attack mode.
    /// Returns null if the weapon lacks that mode, or for .ranged/.none modes.
    pub fn getOffensiveMode(self: Armament, mode: cards.AttackMode) ?weapon.Offensive {
        const template = switch (self) {
            .single => |w| w.template,
            .dual => |d| d.primary.template,
            .compound => {
                std.debug.print("warning: getOffensiveMode called on compound armament (not yet supported)\n", .{});
                return null;
            },
        };
        return switch (mode) {
            .swing => template.swing,
            .thrust => template.thrust,
            .ranged => null, // ranged uses Ranged type, not Offensive
            .none => null,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testId(index: u32) @import("infra").entity.ID {
    return .{ .index = index, .generation = 0 };
}

test "Armament.hasCategory single weapon" {
    const weapon_list = @import("../weapon_list.zig");
    var buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    var sword_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.knights_sword };

    const shield_armament = Armament{ .single = &buckler_instance };
    try testing.expect(shield_armament.hasCategory(.shield));
    try testing.expect(!shield_armament.hasCategory(.sword));

    const sword_armament = Armament{ .single = &sword_instance };
    try testing.expect(!sword_armament.hasCategory(.shield));
    try testing.expect(sword_armament.hasCategory(.sword));
}

test "Armament.hasCategory dual wield" {
    const weapon_list = @import("../weapon_list.zig");
    var buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    var sword_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.knights_sword };

    const sword_and_shield = Armament{ .dual = .{
        .primary = &sword_instance,
        .secondary = &buckler_instance,
    } };
    try testing.expect(sword_and_shield.hasCategory(.shield));
    try testing.expect(sword_and_shield.hasCategory(.sword));
    try testing.expect(!sword_and_shield.hasCategory(.axe));
}
