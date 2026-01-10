//! Armour piece definitions - data-driven armour templates loaded from CUE.
//!
//! Provides comptime validation that CUE-defined armour pieces reference
//! valid materials. Fails at compile time with clear error messages if
//! CUE/Zig data disagrees.
//!
//! Also provides runtime-ready Material and Template types built from the
//! generated definitions at comptime.

const std = @import("std");
const generated = @import("../gen/generated_data.zig");
const armour = @import("armour.zig");

// Generated definition types (from CUE)
pub const ArmourMaterialDef = generated.ArmourMaterialDefinition;
pub const ArmourPieceDef = generated.ArmourPieceDefinition;
pub const CoverageEntry = generated.ArmourCoverageEntry;

// Runtime types (from armour.zig)
pub const Material = armour.Material;
pub const Template = armour.Template;
pub const Pattern = armour.Pattern;
pub const PatternCoverage = armour.PatternCoverage;
pub const ShapeProfile = armour.ShapeProfile;

// Re-export generated tables for direct access to definitions
pub const material_defs = generated.GeneratedArmourMaterials;
pub const piece_defs = generated.GeneratedArmourPieces;

// ============================================================================
// Definition Lookups (generated CUE data)
// ============================================================================

/// Resolve a material definition by ID at comptime.
pub fn resolveMaterialDef(comptime id: []const u8) *const ArmourMaterialDef {
    for (&material_defs) |*mat| {
        if (std.mem.eql(u8, mat.id, id)) {
            return mat;
        }
    }
    @compileError("Unknown armour material ID: '" ++ id ++ "'. Add it to data/materials.cue under materials.armour or check the piece definition in data/armour.cue.");
}

/// Resolve a piece definition by ID at comptime.
pub fn resolvePieceDef(comptime id: []const u8) *const ArmourPieceDef {
    for (&piece_defs) |*piece| {
        if (std.mem.eql(u8, piece.id, id)) {
            return piece;
        }
    }
    @compileError("Unknown armour piece ID: '" ++ id ++ "'. Add it to data/armour.cue or check the ID spelling.");
}

// ============================================================================
// Runtime Type Builders
// ============================================================================

/// Build a runtime Material from a generated definition.
pub fn buildMaterial(comptime def: *const ArmourMaterialDef) Material {
    return .{
        .name = def.name,
        .quality = .common, // TODO: add to CUE schema
        // 3-axis shielding
        .deflection = def.deflection,
        .absorption = def.absorption,
        .dispersion = def.dispersion,
        // 3-axis susceptibility
        .geometry_threshold = def.geometry_threshold,
        .geometry_ratio = def.geometry_ratio,
        .energy_threshold = def.energy_threshold,
        .energy_ratio = def.energy_ratio,
        .rigidity_threshold = def.rigidity_threshold,
        .rigidity_ratio = def.rigidity_ratio,
        // Shape
        .shape = ShapeProfile.fromString(def.shape_profile),
        .shape_dispersion_bonus = def.shape_dispersion_bonus,
        .shape_absorption_bonus = def.shape_absorption_bonus,
        // Physical (TODO: add thickness/durability to CUE schema)
        .thickness = 3.0,
        .durability = 100,
    };
}

/// Convert a CoverageEntry slice to PatternCoverage array at comptime.
/// Returns a fixed-size array that can be stored in static data.
fn convertCoverage(comptime coverage: []const CoverageEntry) [coverage.len]PatternCoverage {
    var result: [coverage.len]PatternCoverage = undefined;
    for (coverage, 0..) |entry, i| {
        result[i] = .{
            .part_tags = entry.part_tags,
            .side = entry.side,
            .layer = entry.layer,
            .totality = entry.totality,
        };
    }
    return result;
}

// ============================================================================
// Generated Lookup Tables
// ============================================================================

/// Comptime-built runtime materials indexed by generated order.
pub const Materials = blk: {
    var mats: [material_defs.len]Material = undefined;
    for (&material_defs, 0..) |*def, i| {
        mats[i] = buildMaterial(def);
    }
    break :blk mats;
};

/// Static pattern coverage data for each piece, to avoid comptime local refs.
const PatternData = blk: {
    var data: [piece_defs.len]struct {
        coverage: [getMaxCoverage()]PatternCoverage,
        len: usize,
    } = undefined;
    for (&piece_defs, 0..) |*def, i| {
        const converted = convertCoverage(def.coverage);
        for (converted, 0..) |cov, j| {
            data[i].coverage[j] = cov;
        }
        data[i].len = def.coverage.len;
    }
    break :blk data;
};

fn getMaxCoverage() usize {
    var max: usize = 0;
    for (&piece_defs) |*def| {
        if (def.coverage.len > max) max = def.coverage.len;
    }
    return if (max == 0) 1 else max;
}

/// Static Pattern structs pointing into PatternData.
const Patterns = blk: {
    var pats: [piece_defs.len]Pattern = undefined;
    for (0..piece_defs.len) |i| {
        pats[i] = .{
            .coverage = PatternData[i].coverage[0..PatternData[i].len],
        };
    }
    break :blk pats;
};

/// Comptime-built runtime templates indexed by generated order.
pub const Templates = blk: {
    var tmpls: [piece_defs.len]Template = undefined;
    for (&piece_defs, 0..) |*def, i| {
        const mat_def = resolveMaterialDef(def.material_id);
        // Find material index to reference static Materials array
        const mat_idx = blk2: {
            for (&material_defs, 0..) |*md, j| {
                if (std.mem.eql(u8, md.id, mat_def.id)) break :blk2 j;
            }
            unreachable;
        };
        tmpls[i] = .{
            .id = std.hash.Fnv1a_64.hash(def.id),
            .name = def.name,
            .material = &Materials[mat_idx],
            .pattern = &Patterns[i],
        };
    }
    break :blk tmpls;
};

/// Look up a runtime material by ID.
pub fn getMaterial(comptime id: []const u8) *const Material {
    for (&Materials, 0..) |*mat, i| {
        if (std.mem.eql(u8, material_defs[i].id, id)) {
            return mat;
        }
    }
    @compileError("Unknown material ID: '" ++ id ++ "'");
}

/// Look up a runtime template by ID.
pub fn getTemplate(comptime id: []const u8) *const Template {
    for (&Templates, 0..) |*tmpl, i| {
        if (std.mem.eql(u8, piece_defs[i].id, id)) {
            return tmpl;
        }
    }
    @compileError("Unknown template ID: '" ++ id ++ "'");
}

/// Runtime lookup of template by string ID.
/// Returns null if ID not found.
pub fn getTemplateRuntime(id: []const u8) ?*const Template {
    for (&piece_defs, 0..) |*def, i| {
        if (std.mem.eql(u8, def.id, id)) {
            return &Templates[i];
        }
    }
    return null;
}

// ============================================================================
// Comptime Validation
// ============================================================================

fn validateAllPieces() void {
    for (&piece_defs) |*piece| {
        _ = resolveMaterialDef(piece.material_id);
    }
}

comptime {
    validateAllPieces();
}

// ============================================================================
// Tests
// ============================================================================

test "resolveMaterialDef returns correct definition" {
    const steel = comptime resolveMaterialDef("steel_plate");
    try std.testing.expectEqualStrings("steel plate", steel.name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), steel.deflection, 0.001);
}

test "resolvePieceDef returns correct definition" {
    const breastplate = comptime resolvePieceDef("steel_breastplate");
    try std.testing.expectEqualStrings("Steel Breastplate", breastplate.name);
    try std.testing.expectEqualStrings("steel_plate", breastplate.material_id);
}

test "buildMaterial creates runtime Material from definition" {
    const def = comptime resolveMaterialDef("steel_plate");
    const mat = comptime buildMaterial(def);
    try std.testing.expectEqualStrings("steel plate", mat.name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), mat.deflection, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), mat.geometry_ratio, 0.001);
    try std.testing.expectEqual(ShapeProfile.solid, mat.shape);
}

test "Materials table is populated" {
    try std.testing.expect(Materials.len == material_defs.len);
    try std.testing.expect(Materials.len > 0);
    // First material should match first definition
    try std.testing.expectEqualStrings(material_defs[0].name, Materials[0].name);
}

test "Templates table is populated" {
    try std.testing.expect(Templates.len == piece_defs.len);
    try std.testing.expect(Templates.len > 0);
    // First template should match first definition
    try std.testing.expectEqualStrings(piece_defs[0].name, Templates[0].name);
}

test "getMaterial returns correct runtime material" {
    const mat = comptime getMaterial("steel_plate");
    try std.testing.expectEqualStrings("steel plate", mat.name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), mat.deflection, 0.001);
}

test "getTemplate returns correct runtime template" {
    const tmpl = comptime getTemplate("steel_breastplate");
    try std.testing.expectEqualStrings("Steel Breastplate", tmpl.name);
    try std.testing.expectEqualStrings("steel plate", tmpl.material.name);
}

test "all pieces have valid materials" {
    // If this compiles, all pieces reference valid materials
    inline for (&piece_defs) |*piece| {
        const mat = comptime resolveMaterialDef(piece.material_id);
        try std.testing.expect(mat.deflection >= 0);
    }
}

test "generated template can create armour instance" {
    const alloc = std.testing.allocator;
    const tmpl = comptime getTemplate("steel_breastplate");

    // Create instance from generated template
    var instance = try armour.Instance.init(alloc, tmpl, null);
    defer instance.deinit(alloc);

    try std.testing.expectEqualStrings("Steel Breastplate", instance.name);
    try std.testing.expect(instance.coverage.len > 0);
    // Verify coverage has integrity from material
    try std.testing.expect(instance.coverage[0].integrity > 0);
}

test "generated template integrates with armour stack" {
    const alloc = std.testing.allocator;
    const body_mod = @import("body.zig");
    const inventory = @import("inventory.zig");

    // Create a test body using humanoid plan
    var bod = try body_mod.Body.fromPlan(alloc, "humanoid", null);
    defer bod.deinit();

    // Create armour instance from generated template
    const tmpl = comptime getTemplate("steel_breastplate");
    var instance = try armour.Instance.init(alloc, tmpl, null);
    defer instance.deinit(alloc);

    // Build stack from equipped armour
    var stack = armour.Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*armour.Instance{&instance};
    try stack.buildFromEquipped(&bod, &equipped);

    // Verify stack has protection for covered parts
    const torso_idx = armour.resolvePartIndex(&bod, .torso, .center);
    try std.testing.expect(torso_idx != null);
    const protection = stack.getProtection(torso_idx.?);
    // Should have plate layer protection
    try std.testing.expect(protection[@intFromEnum(inventory.Layer.Plate)] != null);
}
