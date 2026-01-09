//! Body and tissue definitions - data-driven body plans loaded from CUE.
//!
//! Provides comptime validation that CUE-defined body parts reference
//! valid tissue templates. Fails at compile time with clear error messages
//! if CUE/Zig data disagrees.
//!
//! Also provides runtime-ready TissueStack types built from the generated
//! definitions at comptime.

const std = @import("std");
const generated = @import("../gen/generated_data.zig");
const body = @import("body.zig");

// Generated definition types (from CUE)
pub const TissueTemplateDef = generated.TissueTemplateDefinition;
pub const TissueLayerDef = generated.TissueLayerDefinition;
pub const BodyPlanDef = generated.BodyPlanDefinition;
pub const BodyPartDef = generated.BodyPartDefinition;
pub const BodyPartGeometry = generated.BodyPartGeometry;

// Runtime types (from body.zig)
pub const TissueLayerMaterial = body.TissueLayerMaterial;
pub const TissueStack = body.TissueStack;

// Re-export generated tables for direct access to definitions
pub const tissue_template_defs = generated.GeneratedTissueTemplates;
pub const body_plan_defs = generated.GeneratedBodyPlans;

// ============================================================================
// Definition Lookups (generated CUE data)
// ============================================================================

/// Resolve a tissue template definition by ID at comptime.
pub fn resolveTissueTemplateDef(comptime id: []const u8) *const TissueTemplateDef {
    for (&tissue_template_defs) |*def| {
        if (std.mem.eql(u8, def.id, id)) {
            return def;
        }
    }
    @compileError("Unknown tissue template ID: '" ++ id ++ "'. Add it to data/bodies.cue under tissue_templates.");
}

/// Resolve a body plan definition by ID at comptime.
pub fn resolveBodyPlanDef(comptime id: []const u8) *const BodyPlanDef {
    for (&body_plan_defs) |*def| {
        if (std.mem.eql(u8, def.id, id)) {
            return def;
        }
    }
    @compileError("Unknown body plan ID: '" ++ id ++ "'. Add it to data/bodies.cue under body_plans.");
}

// ============================================================================
// Runtime Type Builders
// ============================================================================

/// Build a runtime TissueLayerMaterial from a generated layer definition.
fn buildTissueLayer(comptime def: *const TissueLayerDef) TissueLayerMaterial {
    return .{
        .material_id = def.material_id,
        .thickness_ratio = def.thickness_ratio,
        // Shielding
        .deflection = def.deflection,
        .absorption = def.absorption,
        .dispersion = def.dispersion,
        // Susceptibility
        .geometry_threshold = def.geometry_threshold,
        .geometry_ratio = def.geometry_ratio,
        .energy_threshold = def.energy_threshold,
        .energy_ratio = def.energy_ratio,
        .rigidity_threshold = def.rigidity_threshold,
        .rigidity_ratio = def.rigidity_ratio,
    };
}

/// Convert a layer definition slice to TissueLayerMaterial array at comptime.
fn convertLayers(comptime layers: []const TissueLayerDef) [layers.len]TissueLayerMaterial {
    var result: [layers.len]TissueLayerMaterial = undefined;
    for (layers, 0..) |*layer, i| {
        result[i] = buildTissueLayer(layer);
    }
    return result;
}

// ============================================================================
// Generated Lookup Tables
// ============================================================================

/// Get max layer count across all tissue templates (for static allocation).
fn getMaxLayers() usize {
    var max: usize = 0;
    for (&tissue_template_defs) |*def| {
        if (def.layers.len > max) max = def.layers.len;
    }
    return if (max == 0) 1 else max;
}

/// Static layer data for each tissue template, to avoid comptime local refs.
const LayerData = blk: {
    var data: [tissue_template_defs.len]struct {
        layers: [getMaxLayers()]TissueLayerMaterial,
        len: usize,
    } = undefined;
    for (&tissue_template_defs, 0..) |*def, i| {
        const converted = convertLayers(def.layers);
        for (converted, 0..) |layer, j| {
            data[i].layers[j] = layer;
        }
        data[i].len = def.layers.len;
    }
    break :blk data;
};

/// Comptime-built runtime tissue stacks indexed by generated order.
pub const TissueStacks = blk: {
    var stacks: [tissue_template_defs.len]TissueStack = undefined;
    for (&tissue_template_defs, 0..) |*def, i| {
        stacks[i] = .{
            .id = def.id,
            .layers = LayerData[i].layers[0..LayerData[i].len],
        };
    }
    break :blk stacks;
};

/// Look up a runtime tissue stack by ID at comptime.
pub fn getTissueStack(comptime id: []const u8) *const TissueStack {
    for (&TissueStacks, 0..) |*stack, i| {
        if (std.mem.eql(u8, tissue_template_defs[i].id, id)) {
            return stack;
        }
    }
    @compileError("Unknown tissue template ID: '" ++ id ++ "'");
}

/// Look up a runtime tissue stack by ID at runtime.
/// Returns null if not found.
pub fn getTissueStackRuntime(id: []const u8) ?*const TissueStack {
    for (&TissueStacks, 0..) |*stack, i| {
        if (std.mem.eql(u8, tissue_template_defs[i].id, id)) {
            return stack;
        }
    }
    return null;
}

// ============================================================================
// Comptime Validation
// ============================================================================

/// Validate all body parts reference valid tissue templates.
fn validateAllBodyParts() void {
    for (&body_plan_defs) |*plan| {
        for (plan.parts) |*part| {
            _ = resolveTissueTemplateDef(part.tissue_template_id);
        }
    }
}

comptime {
    validateAllBodyParts();
}

// ============================================================================
// Tests
// ============================================================================

test "resolveTissueTemplateDef returns correct definition" {
    const core = comptime resolveTissueTemplateDef("core");
    try std.testing.expectEqualStrings("core", core.id);
    try std.testing.expect(core.layers.len > 0);
}

test "resolveBodyPlanDef returns correct definition" {
    const humanoid = comptime resolveBodyPlanDef("humanoid");
    try std.testing.expectEqualStrings("humanoid", humanoid.id);
    try std.testing.expectEqualStrings("Humanoid Plan", humanoid.name);
}

test "buildTissueLayer creates runtime layer from definition" {
    const core_def = comptime resolveTissueTemplateDef("core");
    const layer = comptime buildTissueLayer(&core_def.layers[0]);
    try std.testing.expectEqualStrings("skin", layer.material_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), layer.thickness_ratio, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), layer.deflection, 0.001);
}

test "TissueStacks table is populated" {
    try std.testing.expect(TissueStacks.len == tissue_template_defs.len);
    try std.testing.expect(TissueStacks.len > 0);
    // First stack should match first definition
    try std.testing.expectEqualStrings(tissue_template_defs[0].id, TissueStacks[0].id);
}

test "getTissueStack returns correct runtime stack" {
    const stack = comptime getTissueStack("core");
    try std.testing.expectEqualStrings("core", stack.id);
    try std.testing.expect(stack.layers.len > 0);
    // Core template has skin as outer layer
    try std.testing.expectEqualStrings("skin", stack.layers[0].material_id);
}

test "getTissueStackRuntime returns correct stack" {
    const stack = getTissueStackRuntime("limb");
    try std.testing.expect(stack != null);
    try std.testing.expectEqualStrings("limb", stack.?.id);
}

test "getTissueStackRuntime returns null for unknown ID" {
    const stack = getTissueStackRuntime("nonexistent");
    try std.testing.expect(stack == null);
}

test "TissueStack.hasMaterial finds layers" {
    const stack = comptime getTissueStack("core");
    try std.testing.expect(stack.hasMaterial("skin"));
    try std.testing.expect(stack.hasMaterial("bone"));
    try std.testing.expect(!stack.hasMaterial("tendon")); // core doesn't have tendon
}

test "all body parts have valid tissue templates" {
    // If this compiles, all parts reference valid tissue templates
    inline for (&body_plan_defs) |*plan| {
        inline for (plan.parts) |*part| {
            const stack = comptime getTissueStack(part.tissue_template_id);
            try std.testing.expect(stack.layers.len > 0);
        }
    }
}
