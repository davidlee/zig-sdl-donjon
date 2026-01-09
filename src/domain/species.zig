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

fn parseTag(comptime name: []const u8) Tag {
    return std.meta.stringToEnum(Tag, name) orelse
        @compileError("Unknown species tag: '" ++ name ++ "'. Add it to species.Tag or check CUE data.");
}

fn buildTagSet(comptime tag_names: []const []const u8) TagSet {
    comptime {
        var set = TagSet.initEmpty();
        for (tag_names) |name| {
            set.insert(parseTag(name));
        }
        return set;
    }
}

fn resolveNaturalWeaponTemplate(comptime name: []const u8) *const weapon.Template {
    if (std.mem.eql(u8, name, "natural.fist")) return &FIST;
    if (std.mem.eql(u8, name, "natural.bite")) return &BITE;
    if (std.mem.eql(u8, name, "natural.headbutt")) return &HEADBUTT;
    @compileError("Unknown natural weapon ID: '" ++ name ++ "'. Add it to resolveNaturalWeaponTemplate() or check CUE data.");
}

fn NaturalWeaponsType(comptime refs: []const generated.NaturalWeaponRef) type {
    return [refs.len]NaturalWeapon;
}

fn buildNaturalWeapons(comptime refs: []const generated.NaturalWeaponRef) *const NaturalWeaponsType(refs) {
    return &comptime blk: {
        var result: NaturalWeaponsType(refs) = undefined;
        for (refs, 0..) |ref, i| {
            result[i] = .{
                .template = resolveNaturalWeaponTemplate(ref.weapon_id),
                .required_part = ref.required_part,
            };
        }
        break :blk result;
    };
}

fn findGeneratedSpecies(comptime id: []const u8) generated.SpeciesDefinition {
    for (generated.GeneratedSpecies) |entry| {
        if (std.mem.eql(u8, entry.id, id)) {
            return entry;
        }
    }
    @compileError("Unknown species ID: '" ++ id ++ "'. Check CUE data or add species to bodies.cue.");
}

fn buildSpecies(comptime id: []const u8) Species {
    const gen = comptime findGeneratedSpecies(id);
    return .{
        .name = gen.name,
        .body_plan = &body.HumanoidPlan, // TODO: resolve from gen.body_plan
        .natural_weapons = buildNaturalWeapons(gen.natural_weapons),
        .base_blood = gen.base_blood,
        .base_stamina = gen.base_stamina,
        .base_focus = gen.base_focus,
        .stamina_recovery = gen.stamina_recovery,
        .focus_recovery = gen.focus_recovery,
        .blood_recovery = gen.blood_recovery,
        .tags = buildTagSet(gen.tags),
    };
}

pub const DWARF = buildSpecies("dwarf");
pub const GOBLIN = buildSpecies("goblin");

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
