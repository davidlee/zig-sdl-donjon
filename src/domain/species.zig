//! Species definitions - creature types with body plans, natural weapons, and traits.
//!
//! Species are data-driven definitions similar to cards. An Agent carries a reference
//! to a Species and uses it to initialize body/resources during creation.

const std = @import("std");
const body = @import("body.zig");
const weapon = @import("weapon.zig");

/// Creature categorisation tags for card/condition targeting.
pub const Tag = enum {
    // morphology
    humanoid,
    quadruped,

    // biology
    mammal,
    reptile,
    insectoid,

    // behaviour
    predator,
    pack_hunter,

    // supernatural
    undead,
    construct,
    demon,
};

pub const TagSet = std.EnumSet(Tag);

/// A natural weapon tied to a body part.
/// Availability is gated by part integrity - no hand = no punch.
pub const NaturalWeapon = struct {
    template: *const weapon.Template,
    required_part: body.PartTag,
};

/// Species definition - body plan, natural weapons, base resources, tags.
pub const Species = struct {
    name: []const u8,
    body_plan: []const body.PartDef,
    natural_weapons: []const NaturalWeapon,
    base_blood: f32,
    base_stamina: f32,
    base_focus: f32,
    tags: TagSet,
};

// ============================================================================
// Natural Weapon Templates
// ============================================================================

pub const FIST = weapon.Template{
    .name = "Fist",
    .categories = &.{.unarmed},
    .length = 10.0,
    .weight = 0.5,
    .balance = 0.5,
    .swing = .{
        .name = "punch",
        .reach = .clinch,
        .damage_types = &.{.bludgeon},
        .accuracy = 0.8,
        .speed = 1.2,
        .damage = 2.0,
        .penetration = 0.0,
        .penetration_max = 0.0,
        .defender_modifiers = .{ .reach = .clinch, .parry = 1.0, .deflect = 0.0, .block = 0.0, .fragility = 0.0 },
        .fragility = 0.0,
    },
    .thrust = null,
    .defence = .{
        .name = "block",
        .reach = .clinch,
        .parry = 0.2,
        .deflect = 0.0,
        .block = 0.3,
        .fragility = 0.0,
    },
};

pub const BITE = weapon.Template{
    .name = "Bite",
    .categories = &.{.unarmed},
    .length = 5.0,
    .weight = 0.3,
    .balance = 0.5,
    .swing = null,
    .thrust = .{
        .name = "bite",
        .reach = .clinch,
        .damage_types = &.{ .pierce, .slash },
        .accuracy = 0.7,
        .speed = 1.0,
        .damage = 3.0,
        .penetration = 1.0,
        .penetration_max = 2.0,
        .defender_modifiers = .{ .reach = .clinch, .parry = 1.0, .deflect = 0.0, .block = 0.0, .fragility = 0.0 },
        .fragility = 0.0,
    },
    .defence = .{
        .name = "snap",
        .reach = .clinch,
        .parry = 0.0,
        .deflect = 0.0,
        .block = 0.0,
        .fragility = 0.0,
    },
};

pub const HEADBUTT = weapon.Template{
    .name = "Headbutt",
    .categories = &.{.unarmed},
    .length = 15.0,
    .weight = 1.0,
    .balance = 0.5,
    .swing = null,
    .thrust = .{
        .name = "headbutt",
        .reach = .clinch,
        .damage_types = &.{.bludgeon},
        .accuracy = 0.6,
        .speed = 0.8,
        .damage = 4.0,
        .penetration = 0.0,
        .penetration_max = 0.0,
        .defender_modifiers = .{ .reach = .clinch, .parry = 1.0, .deflect = 0.0, .block = 0.0, .fragility = 0.0 },
        .fragility = 0.0,
    },
    .defence = .{
        .name = "duck",
        .reach = .clinch,
        .parry = 0.0,
        .deflect = 0.0,
        .block = 0.0,
        .fragility = 0.0,
    },
};

// ============================================================================
// Species Definitions
// ============================================================================

pub const DWARF = Species{
    .name = "Dwarf",
    .body_plan = &body.HumanoidPlan,
    .natural_weapons = &.{
        .{ .template = &FIST, .required_part = .hand },
        .{ .template = &HEADBUTT, .required_part = .head },
    },
    .base_blood = 4.5,
    .base_stamina = 12.0,
    .base_focus = 8.0,
    .tags = TagSet.initMany(&.{ .humanoid, .mammal }),
};

pub const GOBLIN = Species{
    .name = "Goblin",
    .body_plan = &body.HumanoidPlan,
    .natural_weapons = &.{
        .{ .template = &FIST, .required_part = .hand },
        .{ .template = &BITE, .required_part = .head },
    },
    .base_blood = 3.5,
    .base_stamina = 8.0,
    .base_focus = 6.0,
    .tags = TagSet.initMany(&.{ .humanoid, .mammal }),
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "TagSet operations" {
    const predator_pack = TagSet.initMany(&.{ .predator, .pack_hunter });
    try testing.expect(predator_pack.contains(.predator));
    try testing.expect(predator_pack.contains(.pack_hunter));
    try testing.expect(!predator_pack.contains(.humanoid));

    const humanoid = TagSet.initOne(.humanoid);
    const combined = predator_pack.unionWith(humanoid);
    try testing.expect(combined.contains(.predator));
    try testing.expect(combined.contains(.humanoid));
}

test "Species fields accessible" {
    try testing.expectEqualStrings("Dwarf", DWARF.name);
    try testing.expect(DWARF.tags.contains(.humanoid));
    try testing.expect(DWARF.tags.contains(.mammal));
    try testing.expect(!DWARF.tags.contains(.undead));
    try testing.expectEqual(@as(usize, 2), DWARF.natural_weapons.len);
}

test "NaturalWeapon links template and part" {
    const fist_weapon = DWARF.natural_weapons[0];
    try testing.expectEqualStrings("Fist", fist_weapon.template.name);
    try testing.expectEqual(body.PartTag.hand, fist_weapon.required_part);
}

test "Goblin has different natural weapons" {
    try testing.expectEqual(@as(usize, 2), GOBLIN.natural_weapons.len);
    // Goblin has bite instead of headbutt
    const bite_weapon = GOBLIN.natural_weapons[1];
    try testing.expectEqualStrings("Bite", bite_weapon.template.name);
    try testing.expectEqual(body.PartTag.head, bite_weapon.required_part);
}

test "Species base resources differ" {
    try testing.expect(DWARF.base_blood > GOBLIN.base_blood);
    try testing.expect(DWARF.base_stamina > GOBLIN.base_stamina);
}
