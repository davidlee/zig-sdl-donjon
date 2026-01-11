//! Armament - weapon configuration for combat agents.
//!
//! Handles equipped weapons (single, dual-wield, compound) and natural weapons from species.

const std = @import("std");
const weapon = @import("../weapon.zig");
const actions = @import("../actions.zig");
const species = @import("../species.zig");

/// Weapon configuration for an agent.
/// Combines equipped weapons (gear) with natural weapons (from species).
pub const Armament = struct {
    equipped: Equipped,
    natural: []const species.NaturalWeapon,

    /// Equipped weapon configuration.
    pub const Equipped = union(enum) {
        unarmed,
        single: *weapon.Instance,
        dual: struct {
            primary: *weapon.Instance,
            secondary: *weapon.Instance,
        },
        compound: [][]*weapon.Instance,
    };

    /// Create Armament from species natural weapons only (unarmed).
    pub fn fromSpecies(natural_weapons: []const species.NaturalWeapon) Armament {
        return .{ .equipped = .unarmed, .natural = natural_weapons };
    }

    /// Create new Armament with different equipped weapons, preserving natural.
    pub fn withEquipped(self: Armament, new_equipped: Equipped) Armament {
        return .{
            .equipped = new_equipped,
            .natural = self.natural,
        };
    }

    /// Check if equipped weapons include a category (e.g., .shield, .sword).
    /// Does not check natural weapons.
    pub fn hasCategory(self: Armament, cat: weapon.Category) bool {
        return switch (self.equipped) {
            .unarmed => false,
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

    /// Get the offensive mode (swing/thrust) from the primary equipped weapon.
    /// Returns null if unarmed, weapon lacks that mode, or for .ranged/.none modes.
    pub fn getOffensiveMode(self: Armament, mode: actions.AttackMode) ?weapon.Offensive {
        const template = switch (self.equipped) {
            .unarmed => return null,
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

    /// Get the ranged profile from the primary equipped weapon.
    /// Returns null if unarmed or weapon has no ranged capability.
    pub fn getRangedMode(self: Armament) ?weapon.Ranged {
        const template = switch (self.equipped) {
            .unarmed => return null,
            .single => |w| w.template,
            .dual => |d| d.primary.template,
            .compound => return null,
        };
        return template.ranged;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testId(index: u32, kind: @import("infra").entity.EntityKind) @import("infra").entity.ID {
    return .{ .index = index, .generation = 0, .kind = kind };
}

test "Armament.hasCategory single weapon" {
    const weapon_list = @import("../weapon_list.zig");
    var buckler_instance = weapon.Instance{ .id = testId(0, .weapon), .template = &weapon_list.buckler };
    var sword_instance = weapon.Instance{ .id = testId(1, .weapon), .template = &weapon_list.knights_sword };

    const shield_armament = Armament{ .equipped = .{ .single = &buckler_instance }, .natural = &.{} };
    try testing.expect(shield_armament.hasCategory(.shield));
    try testing.expect(!shield_armament.hasCategory(.sword));

    const sword_armament = Armament{ .equipped = .{ .single = &sword_instance }, .natural = &.{} };
    try testing.expect(!sword_armament.hasCategory(.shield));
    try testing.expect(sword_armament.hasCategory(.sword));
}

test "Armament.hasCategory dual wield" {
    const weapon_list = @import("../weapon_list.zig");
    var buckler_instance = weapon.Instance{ .id = testId(0, .weapon), .template = &weapon_list.buckler };
    var sword_instance = weapon.Instance{ .id = testId(1, .weapon), .template = &weapon_list.knights_sword };

    const sword_and_shield = Armament{
        .equipped = .{ .dual = .{
            .primary = &sword_instance,
            .secondary = &buckler_instance,
        } },
        .natural = &.{},
    };
    try testing.expect(sword_and_shield.hasCategory(.shield));
    try testing.expect(sword_and_shield.hasCategory(.sword));
    try testing.expect(!sword_and_shield.hasCategory(.axe));
}

test "Armament.hasCategory unarmed" {
    const armament = Armament{ .equipped = .unarmed, .natural = &.{} };
    try testing.expect(!armament.hasCategory(.shield));
    try testing.expect(!armament.hasCategory(.sword));
}

test "Armament.fromSpecies creates unarmed with natural weapons" {
    const armament = Armament.fromSpecies(species.DWARF.natural_weapons);
    try testing.expect(armament.equipped == .unarmed);
    try testing.expect(armament.natural.len > 0);
}

test "Armament.withEquipped preserves natural weapons" {
    const weapon_list = @import("../weapon_list.zig");
    var sword_instance = weapon.Instance{ .id = testId(0, .weapon), .template = &weapon_list.knights_sword };

    const unarmed = Armament.fromSpecies(species.DWARF.natural_weapons);
    const armed = unarmed.withEquipped(.{ .single = &sword_instance });

    try testing.expect(armed.equipped == .single);
    try testing.expectEqual(unarmed.natural.ptr, armed.natural.ptr);
    try testing.expectEqual(unarmed.natural.len, armed.natural.len);
}

test "Armament.getOffensiveMode returns null when unarmed" {
    const armament = Armament{ .equipped = .unarmed, .natural = &.{} };
    try testing.expect(armament.getOffensiveMode(.swing) == null);
    try testing.expect(armament.getOffensiveMode(.thrust) == null);
}
