//! Species definitions - creature types with body plans, natural weapons, and traits.
//!
//! Species are data-driven definitions similar to cards. An Agent carries a reference
//! to a Species and uses it to initialize body/resources during creation.

const std = @import("std");
const body = @import("body.zig");
const weapon = @import("weapon.zig");
const generated = @import("../gen/generated_data.zig");

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

// ============================================================================
// Global Resource Defaults
// ============================================================================

/// Default stamina recovery per turn (can be overridden per-species).
pub const DEFAULT_STAMINA_RECOVERY: f32 = 2.0;

/// Default focus recovery per turn (can be overridden per-species).
pub const DEFAULT_FOCUS_RECOVERY: f32 = 1.0;

/// Default blood recovery per turn (can be overridden per-species).
/// Zero by default - blood doesn't regenerate without magic/healing.
pub const DEFAULT_BLOOD_RECOVERY: f32 = 0.0;

/// A natural weapon tied to a body part.
/// Availability is gated by part integrity - no hand = no punch.
pub const NaturalWeapon = struct {
    template: *const weapon.Template,
    required_part: body.PartTag,
};

fn buildTagSet(names: []const []const u8) TagSet {
    var set = TagSet.initEmpty();
    inline for (names) |name| {
        set.insert(parseTag(name));
    }
    return set;
}

fn parseTag(name: []const u8) Tag {
    inline for (std.meta.fields(Tag)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @field(Tag, field.name);
        }
    }
    @compileError("Unknown species tag '" ++ name ++ "'");
}
/// Species definition - body plan, natural weapons, base resources, tags.
/// Recovery rates default to global values if not specified.
pub const Species = struct {
    name: []const u8,
    body_plan: []const body.PartDef,
    natural_weapons: []const NaturalWeapon,
    base_blood: f32,
    base_stamina: f32,
    base_focus: f32,
    /// Override stamina recovery (null = use DEFAULT_STAMINA_RECOVERY).
    stamina_recovery: ?f32 = null,
    /// Override focus recovery (null = use DEFAULT_FOCUS_RECOVERY).
    focus_recovery: ?f32 = null,
    /// Override blood recovery (null = use DEFAULT_BLOOD_RECOVERY).
    blood_recovery: ?f32 = null,
    tags: TagSet,

    /// Get stamina recovery rate, using global default if not overridden.
    pub fn getStaminaRecovery(self: *const Species) f32 {
        return self.stamina_recovery orelse DEFAULT_STAMINA_RECOVERY;
    }

    /// Get focus recovery rate, using global default if not overridden.
    pub fn getFocusRecovery(self: *const Species) f32 {
        return self.focus_recovery orelse DEFAULT_FOCUS_RECOVERY;
    }

    /// Get blood recovery rate, using global default if not overridden.
    pub fn getBloodRecovery(self: *const Species) f32 {
        return self.blood_recovery orelse DEFAULT_BLOOD_RECOVERY;
    }
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
        .damage = 2.0, // natural weapon: weaker than steel (sword = 10.0)
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
        .damage = 4.0, // natural weapon: weaker than steel (sword = 10.0)
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
        .damage = 3.0, // natural weapon: weaker than steel (sword = 10.0)
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
// Generated Species Integration
// ============================================================================

const TotalNaturalWeapons = blk: {
    var count: usize = 0;
    for (generated.GeneratedSpecies) |entry| {
        count += entry.natural_weapons.len;
    }
    break :blk count;
};

const SpeciesBuild = blk: {
    var species_storage: [generated.GeneratedSpecies.len]Species = undefined;
    var id_storage: [generated.GeneratedSpecies.len][]const u8 = undefined;
    var natural_weapon_storage: [TotalNaturalWeapons]NaturalWeapon = undefined;
    var cursor: usize = 0;

    for (generated.GeneratedSpecies, 0..) |entry, idx| {
        id_storage[idx] = entry.id;
        const start = cursor;
        for (entry.natural_weapons) |natural| {
            natural_weapon_storage[cursor] = .{
                .template = resolveNaturalWeaponTemplate(natural.weapon_id),
                .required_part = natural.required_part,
            };
            cursor += 1;
        }

        const natural_slice = natural_weapon_storage[start..cursor];

        species_storage[idx] = .{
            .name = entry.name,
            .body_plan = resolveBodyPlan(entry.body_plan),
            .natural_weapons = natural_slice,
            .base_blood = entry.base_blood,
            .base_stamina = entry.base_stamina,
            .base_focus = entry.base_focus,
            .stamina_recovery = entry.stamina_recovery,
            .focus_recovery = entry.focus_recovery,
            .blood_recovery = entry.blood_recovery,
            .tags = buildTagSet(entry.tags),
        };
    }

    break :blk .{
        .species = species_storage,
        .ids = id_storage,
        .natural_weapons = natural_weapon_storage,
    };
};

fn resolveBodyPlan(name: []const u8) []const body.PartDef {
    if (std.mem.eql(u8, name, "humanoid")) return &body.HumanoidPlan;
    @compileError("Unknown body plan '" ++ name ++ "'");
}

fn resolveNaturalWeaponTemplate(name: []const u8) *const weapon.Template {
    if (std.mem.eql(u8, name, "natural.fist")) return &FIST;
    if (std.mem.eql(u8, name, "natural.bite")) return &BITE;
    if (std.mem.eql(u8, name, "natural.headbutt")) return &HEADBUTT;
    @compileError("Unknown natural weapon '" ++ name ++ "'");
}

fn speciesIndex(comptime id: []const u8) usize {
    inline for (SpeciesBuild.ids, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry, id)) {
            return idx;
        }
    }
    @compileError("Unknown species id '" ++ id ++ "'");
}

fn getSpeciesPtr(comptime id: []const u8) *const Species {
    return &SpeciesBuild.species[speciesIndex(id)];
}

pub const DWARF = getSpeciesPtr("dwarf").*;
pub const GOBLIN = getSpeciesPtr("goblin").*;

pub fn listAll() []const Species {
    return SpeciesBuild.species[0..];
}

pub fn getById(comptime id: []const u8) *const Species {
    return getSpeciesPtr(id);
}

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

test "Species recovery rates use global defaults" {
    // DWARF and GOBLIN don't override, so get global defaults
    try testing.expectEqual(DEFAULT_STAMINA_RECOVERY, DWARF.getStaminaRecovery());
    try testing.expectEqual(DEFAULT_FOCUS_RECOVERY, DWARF.getFocusRecovery());
    try testing.expectEqual(DEFAULT_BLOOD_RECOVERY, DWARF.getBloodRecovery());
}

test "Species can override recovery rates" {
    const dragon = Species{
        .name = "Dragon",
        .body_plan = &body.HumanoidPlan, // placeholder
        .natural_weapons = &.{},
        .base_blood = 20.0,
        .base_stamina = 30.0,
        .base_focus = 25.0,
        .blood_recovery = 1.0, // dragons regenerate blood
        .tags = TagSet.initMany(&.{.reptile}),
    };
    try testing.expectEqual(@as(f32, 1.0), dragon.getBloodRecovery());
    // Non-overridden still use defaults
    try testing.expectEqual(DEFAULT_STAMINA_RECOVERY, dragon.getStaminaRecovery());
}
