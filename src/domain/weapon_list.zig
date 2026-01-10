//! Weapon definitions - data-driven weapon templates loaded from CUE.
//!
//! Provides comptime validation and lookup for weapon templates. Templates
//! are built at comptime from CUE-generated definitions.
//!
//! Usage:
//!   const sword = weapon_list.getTemplate("swords.knights_sword");
//!   const tmpl = weapon_list.getTemplateRuntime(id) orelse return error.UnknownWeapon;

const std = @import("std");
const generated = @import("../gen/generated_data.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const damage = @import("damage.zig");

// Re-export generated definition types
pub const WeaponDef = generated.WeaponDefinition;
pub const OffensiveDef = generated.OffensiveProfileDefinition;
pub const DefensiveDef = generated.DefensiveProfileDefinition;
pub const DefenderModsDef = generated.DefenderModifiersDefinition;
pub const GripDef = generated.GripDefinition;
pub const FeaturesDef = generated.FeaturesDefinition;
pub const RangedDef = generated.RangedDefinition;
pub const ThrownDef = generated.ThrownDefinition;
pub const ProjectileDef = generated.ProjectileDefinition;

// Re-export generated table
pub const weapon_defs = generated.GeneratedWeapons;

// Runtime types
pub const Template = weapon.Template;
pub const Offensive = weapon.Offensive;
pub const Defensive = weapon.Defensive;
pub const Category = weapon.Category;
pub const Grip = weapon.Grip;
pub const Features = weapon.Features;
pub const Reach = combat.Reach;

// ============================================================================
// Builders - convert generated definitions to runtime types
// ============================================================================

/// Build runtime defender modifiers from definition.
/// Note: defender_modifiers in Offensive is of type Defensive.
fn buildDefenderMods(def: DefenderModsDef) Defensive {
    return .{
        .name = "", // defender_modifiers don't have a name in the runtime struct
        .reach = def.reach,
        .parry = def.parry,
        .deflect = def.deflect,
        .block = def.block,
        .fragility = def.fragility,
    };
}

/// Build runtime Offensive from generated definition.
fn buildOffensive(def: OffensiveDef) Offensive {
    return .{
        .name = def.name,
        .reach = def.reach,
        .damage_types = def.damage_types,
        .accuracy = def.accuracy,
        .speed = def.speed,
        .damage = def.damage,
        .penetration = def.penetration,
        .penetration_max = def.penetration_max,
        .fragility = def.fragility,
        .defender_modifiers = buildDefenderMods(def.defender_modifiers),
    };
}

/// Build runtime Defensive from generated definition.
fn buildDefensive(def: DefensiveDef) Defensive {
    return .{
        .name = def.name,
        .reach = def.reach,
        .parry = def.parry,
        .deflect = def.deflect,
        .block = def.block,
        .fragility = def.fragility,
    };
}

/// Build runtime Grip from generated definition.
fn buildGrip(def: GripDef) Grip {
    return .{
        .one_handed = def.one_handed,
        .two_handed = def.two_handed,
        .versatile = def.versatile,
        .bastard = def.bastard,
        .half_sword = def.half_sword,
        .murder_stroke = def.murder_stroke,
    };
}

/// Build runtime Features from generated definition.
fn buildFeatures(def: FeaturesDef) Features {
    return .{
        .hooked = def.hooked,
        .spiked = def.spiked,
        .crossguard = def.crossguard,
        .pommel = def.pommel,
    };
}

/// Build runtime Thrown from generated definition.
fn buildThrown(def: ThrownDef) weapon.Thrown {
    return .{
        .throw = buildOffensive(def.throw),
        .range = def.range,
    };
}

/// Build runtime Projectile from generated definition.
fn buildProjectile(def: ProjectileDef) weapon.Projectile {
    return .{
        .ammunition = def.ammunition,
        .range = def.range,
        .accuracy = def.accuracy,
        .speed = def.speed,
        .reload = def.reload,
    };
}

/// Build runtime Ranged from generated definition.
fn buildRanged(def: RangedDef) weapon.Ranged {
    if (def.thrown) |thrown| {
        return .{ .thrown = buildThrown(thrown) };
    }
    if (def.projectile) |proj| {
        return .{ .projectile = buildProjectile(proj) };
    }
    // Should not happen if data is valid
    return .{ .thrown = .{
        .throw = .{
            .name = "invalid",
            .reach = .clinch,
            .damage_types = &.{},
            .accuracy = 0,
            .speed = 0,
            .damage = 0,
            .penetration = 0,
            .penetration_max = 0,
            .fragility = 1,
            .defender_modifiers = .{
                .reach = .clinch,
                .parry = 1,
                .deflect = 1,
                .block = 1,
                .fragility = 1,
            },
        },
        .range = .clinch,
    } };
}

/// Build runtime Template from generated definition.
pub fn buildTemplate(comptime def: *const WeaponDef) Template {
    return .{
        .name = def.name,
        .categories = def.categories,
        .features = buildFeatures(def.features),
        .grip = buildGrip(def.grip),
        .length = def.length,
        .weight = def.weight,
        .balance = def.balance,
        .swing = if (def.swing) |s| buildOffensive(s) else null,
        .thrust = if (def.thrust) |t| buildOffensive(t) else null,
        .defence = buildDefensive(def.defence),
        .ranged = if (def.ranged) |r| buildRanged(r) else null,
        .integrity = def.integrity,
        .moment_of_inertia = def.moment_of_inertia,
        .effective_mass = def.effective_mass,
        .reference_energy_j = def.reference_energy_j,
        .geometry_coeff = def.geometry_coeff,
        .rigidity_coeff = def.rigidity_coeff,
    };
}

// ============================================================================
// Generated Lookup Tables
// ============================================================================

/// Comptime-built runtime templates.
pub const Templates = blk: {
    var tmpls: [weapon_defs.len]Template = undefined;
    for (&weapon_defs, 0..) |*def, i| {
        tmpls[i] = buildTemplate(def);
    }
    break :blk tmpls;
};

/// Public entry list for iteration (pointers to Templates array).
pub const WeaponEntries = blk: {
    var entries: [weapon_defs.len]*const Template = undefined;
    for (0..weapon_defs.len) |i| {
        entries[i] = &Templates[i];
    }
    break :blk entries;
};

// ============================================================================
// Lookup Functions
// ============================================================================

/// Look up a runtime template by CUE ID at comptime.
/// Example: getTemplate("swords.knights_sword")
pub fn getTemplate(comptime id: []const u8) *const Template {
    for (&Templates, 0..) |*tmpl, i| {
        if (comptime std.mem.eql(u8, weapon_defs[i].id, id)) {
            return tmpl;
        }
    }
    @compileError("Unknown weapon ID: '" ++ id ++ "'. Add it to data/weapons.cue.");
}

/// Runtime lookup by string ID. Returns null if not found.
pub fn getTemplateRuntime(id: []const u8) ?*const Template {
    for (&weapon_defs, 0..) |*def, i| {
        if (std.mem.eql(u8, def.id, id)) {
            return &Templates[i];
        }
    }
    return null;
}

/// Comptime lookup by name (legacy compatibility).
/// Example: byName("knight's sword")
pub fn byName(comptime name: []const u8) *const Template {
    return comptime byNameIndex(name);
}

fn byNameIndex(comptime name: []const u8) *const Template {
    @setEvalBranchQuota(10000);
    for (weapon_defs, 0..) |def, i| {
        if (std.mem.eql(u8, def.name, name)) {
            return &Templates[i];
        }
    }
    @compileError("Unknown weapon name: '" ++ name ++ "'");
}

// ============================================================================
// Legacy Named Exports (backward compatibility)
// These are Template values (not pointers) for backward compatibility with
// code that does &weapon_list.knights_sword to get a pointer.
// ============================================================================

pub const horsemans_mace: Template = getTemplate("maces.horsemans_mace").*;
pub const footmans_axe: Template = getTemplate("axes.footmans_axe").*;
pub const greataxe: Template = getTemplate("axes.greataxe").*;
pub const knights_sword: Template = getTemplate("swords.knights_sword").*;
pub const falchion: Template = getTemplate("swords.falchion").*;
pub const dirk: Template = getTemplate("daggers.dirk").*;
pub const spear: Template = getTemplate("polearms.spear").*;
pub const buckler: Template = getTemplate("shields.buckler").*;
pub const fist_stone: Template = getTemplate("improvised.fist_stone").*;

// ============================================================================
// Tests
// ============================================================================

test "Templates table is populated" {
    try std.testing.expect(Templates.len == weapon_defs.len);
    try std.testing.expect(Templates.len > 0);
}

test "getTemplate returns correct weapon" {
    const sword = comptime getTemplate("swords.knights_sword");
    try std.testing.expectEqualStrings("knight's sword", sword.name);
    try std.testing.expectEqual(Category.sword, sword.categories[0]);
}

test "getTemplateRuntime returns correct weapon" {
    const sword = getTemplateRuntime("swords.knights_sword");
    try std.testing.expect(sword != null);
    try std.testing.expectEqualStrings("knight's sword", sword.?.name);
}

test "getTemplateRuntime returns null for unknown" {
    const unknown = getTemplateRuntime("nonexistent.weapon");
    try std.testing.expect(unknown == null);
}

test "byName returns correct weapon" {
    const sword = comptime byName("knight's sword");
    try std.testing.expectEqualStrings("knight's sword", sword.name);
}

test "legacy named exports work" {
    try std.testing.expectEqualStrings("knight's sword", knights_sword.name);
    try std.testing.expectEqualStrings("horseman's mace", horsemans_mace.name);
    try std.testing.expectEqualStrings("fist stone", fist_stone.name);
}

test "all weapons have valid offensive profiles" {
    for (WeaponEntries) |w| {
        // At least one attack method
        try std.testing.expect(w.swing != null or w.thrust != null);

        if (w.swing) |swing| {
            try std.testing.expect(swing.accuracy > 0 and swing.accuracy <= 1.5);
            try std.testing.expect(swing.speed > 0);
            try std.testing.expect(swing.damage > 0);
        }

        if (w.thrust) |thrust| {
            try std.testing.expect(thrust.accuracy > 0 and thrust.accuracy <= 1.5);
            try std.testing.expect(thrust.speed > 0);
            try std.testing.expect(thrust.damage > 0);
        }
    }
}

test "all weapons have valid defensive profiles" {
    for (WeaponEntries) |w| {
        try std.testing.expect(w.defence.parry >= 0 and w.defence.parry <= 1.5);
        try std.testing.expect(w.defence.deflect >= 0 and w.defence.deflect <= 1.5);
        try std.testing.expect(w.defence.block >= 0 and w.defence.block <= 1.5);
    }
}

test "weapon categories are correct" {
    try std.testing.expectEqual(Category.mace, horsemans_mace.categories[0]);
    try std.testing.expectEqual(Category.axe, footmans_axe.categories[0]);
    try std.testing.expectEqual(Category.axe, greataxe.categories[0]);
    try std.testing.expectEqual(Category.sword, knights_sword.categories[0]);
    try std.testing.expectEqual(Category.sword, falchion.categories[0]);
    try std.testing.expectEqual(Category.dagger, dirk.categories[0]);
    try std.testing.expectEqual(Category.polearm, spear.categories[0]);
    try std.testing.expectEqual(Category.shield, buckler.categories[0]);
    try std.testing.expectEqual(Category.improvised, fist_stone.categories[0]);
}

test "grip constraints are sensible" {
    // Two-handed weapons shouldn't be one-handed
    try std.testing.expect(!greataxe.grip.one_handed);
    try std.testing.expect(greataxe.grip.two_handed);

    // Spear is two-handed with versatile grip
    try std.testing.expect(!spear.grip.one_handed);
    try std.testing.expect(spear.grip.two_handed);
    try std.testing.expect(spear.grip.versatile);

    // Buckler and dirk are one-handed only
    try std.testing.expect(buckler.grip.one_handed);
    try std.testing.expect(!buckler.grip.two_handed);
    try std.testing.expect(dirk.grip.one_handed);
    try std.testing.expect(!dirk.grip.two_handed);
}

test "fist_stone has ranged thrown profile" {
    try std.testing.expect(fist_stone.ranged != null);
    const ranged = fist_stone.ranged.?;
    try std.testing.expectEqual(weapon.Ranged.thrown, std.meta.activeTag(ranged));
    const thrown = ranged.thrown;
    try std.testing.expectEqualStrings("fist stone throw", thrown.throw.name);
    try std.testing.expectEqual(Reach.medium, thrown.range);
}
