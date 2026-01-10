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
        .is_structural = def.is_structural,
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
// Body Plan Wiring
// ============================================================================

/// Convert a tissue template string ID to the TissueTemplate enum.
/// Fails at comptime with a helpful error if the ID doesn't match any enum variant.
fn stringToTissueTemplate(comptime id: []const u8) body.TissueTemplate {
    @setEvalBranchQuota(10000);
    return std.meta.stringToEnum(body.TissueTemplate, id) orelse
        @compileError("Unknown tissue template ID: '" ++ id ++ "'. Valid values are: limb, digit, joint, facial, organ, core. Check data/bodies.cue tissue_template field.");
}

/// Find a part's index within a body plan by name.
/// Returns null if not found (caller should emit appropriate error).
fn findPartIndexInPlan(comptime plan: *const BodyPlanDef, comptime name: []const u8) ?usize {
    @setEvalBranchQuota(10000);
    for (plan.parts, 0..) |*part, i| {
        if (std.mem.eql(u8, part.name, name)) {
            return i;
        }
    }
    return null;
}

/// Build a runtime PartDef from a generated definition.
/// Resolves parent/enclosing references and applies default stats.
fn buildPartDef(
    comptime part: *const BodyPartDef,
    comptime plan: *const BodyPlanDef,
) body.PartDef {
    @setEvalBranchQuota(100000);
    // Resolve parent reference
    const parent_id: ?body.PartId = if (part.parent) |parent_name| blk: {
        if (findPartIndexInPlan(plan, parent_name) == null) {
            @compileError("Body part '" ++ part.name ++ "' references unknown parent '" ++ parent_name ++ "'. Check data/bodies.cue - parent must be another part in the same body plan.");
        }
        break :blk body.PartId.init(parent_name);
    } else null;

    // Resolve enclosing reference
    const enclosing_id: ?body.PartId = if (part.enclosing) |enclosing_name| blk: {
        if (findPartIndexInPlan(plan, enclosing_name) == null) {
            @compileError("Body part '" ++ part.name ++ "' references unknown enclosing part '" ++ enclosing_name ++ "'. Check data/bodies.cue - enclosing must be another part in the same body plan.");
        }
        break :blk body.PartId.init(enclosing_name);
    } else null;

    // Get default stats for this part type
    const stats = body.defaultStats(part.tag);

    return .{
        .id = body.PartId.init(part.name),
        .parent = parent_id,
        .enclosing = enclosing_id,
        .tag = part.tag,
        .side = part.side,
        .name = part.name,
        .base_hit_chance = stats.hit_chance,
        .base_durability = stats.durability,
        .trauma_mult = stats.trauma_mult,
        .flags = part.flags,
        .tissue = stringToTissueTemplate(part.tissue_template_id),
        .has_major_artery = part.has_major_artery,
        .geometry = part.geometry,
    };
}

/// Build runtime PartDef array from a generated body plan.
fn buildBodyPlan(comptime plan: *const BodyPlanDef) [plan.parts.len]body.PartDef {
    @setEvalBranchQuota(1000000);
    var result: [plan.parts.len]body.PartDef = undefined;
    for (plan.parts, 0..) |*part, i| {
        result[i] = buildPartDef(part, plan);
    }
    return result;
}

// ============================================================================
// Body Plan Lookup Tables
// ============================================================================

/// Get max part count across all body plans (for static allocation).
fn getMaxParts() usize {
    var max: usize = 0;
    for (&body_plan_defs) |*plan| {
        if (plan.parts.len > max) max = plan.parts.len;
    }
    return if (max == 0) 1 else max;
}

/// Static part data for each body plan, to avoid comptime local refs.
const PartDefData = blk: {
    var data: [body_plan_defs.len]struct {
        parts: [getMaxParts()]body.PartDef,
        len: usize,
    } = undefined;
    for (&body_plan_defs, 0..) |*plan, i| {
        const converted = buildBodyPlan(plan);
        for (converted, 0..) |part, j| {
            data[i].parts[j] = part;
        }
        data[i].len = plan.parts.len;
    }
    break :blk data;
};

/// Runtime body plan with ID and part slice.
pub const BodyPlan = struct {
    id: []const u8,
    name: []const u8,
    parts: []const body.PartDef,
};

/// Comptime-built body plans indexed by generated order.
pub const BodyPlans = blk: {
    var plans: [body_plan_defs.len]BodyPlan = undefined;
    for (&body_plan_defs, 0..) |*def, i| {
        plans[i] = .{
            .id = def.id,
            .name = def.name,
            .parts = PartDefData[i].parts[0..PartDefData[i].len],
        };
    }
    break :blk plans;
};

/// Look up a runtime body plan by ID at comptime.
pub fn getBodyPlan(comptime id: []const u8) *const BodyPlan {
    for (&BodyPlans, 0..) |*plan, i| {
        if (std.mem.eql(u8, body_plan_defs[i].id, id)) {
            return plan;
        }
    }
    @compileError("Unknown body plan ID: '" ++ id ++ "'. Add it to data/bodies.cue under body_plans or check the ID spelling.");
}

/// Look up a runtime body plan by ID at runtime.
/// Returns null if not found.
pub fn getBodyPlanRuntime(id: []const u8) ?*const BodyPlan {
    for (&BodyPlans, 0..) |*plan, i| {
        if (std.mem.eql(u8, body_plan_defs[i].id, id)) {
            return plan;
        }
    }
    return null;
}

// ============================================================================
// Comptime Validation
// ============================================================================

/// Validate all body parts reference valid tissue templates.
fn validateAllBodyParts() void {
    @setEvalBranchQuota(10000);
    for (&body_plan_defs) |*plan| {
        for (plan.parts) |*part| {
            _ = resolveTissueTemplateDef(part.tissue_template_id);
        }
    }
}

/// Validate all parent/enclosing references resolve correctly.
fn validateAllPartReferences() void {
    @setEvalBranchQuota(100000);
    for (&body_plan_defs) |*plan| {
        for (plan.parts) |*part| {
            if (part.parent) |parent_name| {
                if (findPartIndexInPlan(plan, parent_name) == null) {
                    @compileError("Body part '" ++ part.name ++ "' references unknown parent '" ++ parent_name ++ "'");
                }
            }
            if (part.enclosing) |enclosing_name| {
                if (findPartIndexInPlan(plan, enclosing_name) == null) {
                    @compileError("Body part '" ++ part.name ++ "' references unknown enclosing '" ++ enclosing_name ++ "'");
                }
            }
        }
    }
}

comptime {
    validateAllBodyParts();
    validateAllPartReferences();
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

// ============================================================================
// Body Plan Wiring Tests
// ============================================================================

test "stringToTissueTemplate converts valid IDs" {
    try std.testing.expectEqual(body.TissueTemplate.core, comptime stringToTissueTemplate("core"));
    try std.testing.expectEqual(body.TissueTemplate.limb, comptime stringToTissueTemplate("limb"));
    try std.testing.expectEqual(body.TissueTemplate.digit, comptime stringToTissueTemplate("digit"));
    try std.testing.expectEqual(body.TissueTemplate.organ, comptime stringToTissueTemplate("organ"));
}

test "BodyPlans table is populated" {
    try std.testing.expect(BodyPlans.len == body_plan_defs.len);
    try std.testing.expect(BodyPlans.len > 0);
    // First plan should match first definition
    try std.testing.expectEqualStrings(body_plan_defs[0].id, BodyPlans[0].id);
}

test "getBodyPlan returns correct runtime plan" {
    const plan = comptime getBodyPlan("humanoid");
    try std.testing.expectEqualStrings("humanoid", plan.id);
    try std.testing.expectEqualStrings("Humanoid Plan", plan.name);
    try std.testing.expect(plan.parts.len > 0);
}

test "getBodyPlanRuntime returns correct plan" {
    const plan = getBodyPlanRuntime("humanoid");
    try std.testing.expect(plan != null);
    try std.testing.expectEqualStrings("humanoid", plan.?.id);
}

test "getBodyPlanRuntime returns null for unknown ID" {
    const plan = getBodyPlanRuntime("nonexistent");
    try std.testing.expect(plan == null);
}

test "humanoid plan has expected part count" {
    const plan = comptime getBodyPlan("humanoid");
    // CUE humanoid has 67 parts (includes tongue)
    try std.testing.expect(plan.parts.len >= 60);
}

test "buildPartDef produces correct PartDef" {
    const plan = comptime getBodyPlan("humanoid");
    // Find torso
    var torso: ?*const body.PartDef = null;
    for (plan.parts) |*part| {
        if (part.tag == .torso) {
            torso = part;
            break;
        }
    }
    try std.testing.expect(torso != null);
    const t = torso.?;
    try std.testing.expectEqualStrings("torso", t.name);
    try std.testing.expectEqual(body.PartTag.torso, t.tag);
    try std.testing.expectEqual(body.Side.center, t.side);
    try std.testing.expect(t.parent == null); // torso is root
    try std.testing.expect(t.flags.is_vital);
    try std.testing.expectEqual(body.TissueTemplate.core, t.tissue);
    // Stats from defaultStats
    try std.testing.expectApproxEqAbs(@as(f32, 0.30), t.base_hit_chance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), t.base_durability, 0.001);
}

test "buildPartDef resolves parent reference" {
    const plan = comptime getBodyPlan("humanoid");
    // Find neck - should have torso as parent
    var neck: ?*const body.PartDef = null;
    for (plan.parts) |*part| {
        if (part.tag == .neck) {
            neck = part;
            break;
        }
    }
    try std.testing.expect(neck != null);
    const n = neck.?;
    try std.testing.expect(n.parent != null);
    // Parent should be torso's PartId
    const expected_parent = body.PartId.init("torso");
    try std.testing.expectEqual(expected_parent.hash, n.parent.?.hash);
}

test "buildPartDef resolves enclosing reference for organs" {
    const plan = comptime getBodyPlan("humanoid");
    // Find brain - should be enclosed by head
    var brain: ?*const body.PartDef = null;
    for (plan.parts) |*part| {
        if (part.tag == .brain) {
            brain = part;
            break;
        }
    }
    try std.testing.expect(brain != null);
    const b = brain.?;
    try std.testing.expect(b.enclosing != null);
    const expected_enclosing = body.PartId.init("head");
    try std.testing.expectEqual(expected_enclosing.hash, b.enclosing.?.hash);
    // Brain should also have head as parent
    try std.testing.expect(b.parent != null);
    try std.testing.expectEqual(expected_enclosing.hash, b.parent.?.hash);
}

test "all parts have valid parent/enclosing references" {
    // This test verifies comptime validation worked
    inline for (&BodyPlans) |*plan| {
        for (plan.parts) |*part| {
            // Every non-root part should have a parent
            if (part.parent) |parent_id| {
                // Parent ID should be non-zero hash
                try std.testing.expect(parent_id.hash != 0);
            }
            if (part.enclosing) |enclosing_id| {
                try std.testing.expect(enclosing_id.hash != 0);
            }
        }
    }
}
