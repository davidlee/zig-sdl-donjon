# T035: Wire Generated Body/Tissue Data to Runtime

Created: 2026-01-09

## Problem statement / value driver

Body parts and tissue layers are fully defined in CUE with 3-axis physics coefficients, but the runtime still uses hardcoded enums and tables. Wiring the generated data completes the "unified material model" goal - armour and tissue layers share the same physics, enabling consistent damage resolution through `[cloak][mail][plate][skin][fat][muscle][bone]` stacks.

### Scope - goals

- Create `body_list.zig` to build runtime types from generated definitions
- Replace hardcoded `HumanoidPlan` with generated body plan
- Replace hardcoded `TissueTemplate` layer tables with generated tissue stacks
- Update tissue damage resolution to use 3-axis model

### Scope - non-goals

- Species/natural weapons migration (separate, see T034)
- New body plans beyond humanoid (can add to CUE later)
- Wound/severity system changes (uses existing)

## Background

### Relevant documents

- `doc/artefacts/geometry_momentum_rigidity_review.md` - §5 unified material schema
- `kanban/T033_armour_3axis_migration.md` - completed armour migration (pattern to follow)

### Key files

- `src/domain/body.zig` - current Body, PartDef, TissueTemplate, tissue resolution
- `src/gen/generated_data.zig` - GeneratedBodyPlans, GeneratedTissueTemplates
- `data/bodies.cue` - source definitions
- `data/materials.cue` - tissue material definitions (skin, fat, muscle, bone, etc.)

### What's already generated

```zig
// Tissue layers with full 3-axis coefficients
pub const GeneratedTissueTemplates = [_]TissueTemplateDefinition{
    .{ .id = "core", .layers = &.{
        .{ .material_id = "skin", .deflection = 0.1, .absorption = 0.25, ... },
        .{ .material_id = "fat", .deflection = 0.02, .absorption = 0.55, ... },
        .{ .material_id = "muscle", ... },
        .{ .material_id = "bone", ... },
    }},
    .{ .id = "limb", ... },
    .{ .id = "digit", ... },
    // etc.
};

// Body plans with geometry
pub const GeneratedBodyPlans = [_]BodyPlanDefinition{
    .{ .id = "humanoid", .parts = &.{
        .{ .tag = .torso, .tissue_template = .core,
           .geometry = .{ .thickness_cm = 32, .length_cm = 55, .area_cm2 = 1200 } },
        // ... 60+ parts
    }},
};
```

### Current runtime (to replace)

```zig
// body.zig - hardcoded
pub const TissueTemplate = enum {
    limb, digit, joint, facial, organ, core,

    pub fn layers(self: TissueTemplate) []const TissueLayer {
        return switch (self) {
            .limb => &.{ .skin, .fat, .muscle, .tendon, .nerve, .bone },
            // ... hardcoded
        };
    }
};

pub const HumanoidPlan = [_]PartDef{
    .{ .tag = .torso, .name = "torso", .tissue = .core, ... },
    // ... hardcoded
};
```

## Changes Required

### Phase 1: Create body_list.zig

Following `armour_list.zig` pattern:

```zig
const gen = @import("../gen/generated_data.zig");
const body = @import("body.zig");

/// Build runtime TissueStack from generated definition
pub fn buildTissueStack(comptime def: *const gen.TissueTemplateDefinition) TissueStack {
    // Convert layers to runtime format with 3-axis coefficients
}

/// Comptime-built tissue stacks indexed by template ID
pub const TissueStacks = blk: {
    // Build from GeneratedTissueTemplates
};

/// Build runtime PartDef array from generated body plan
pub fn buildBodyPlan(comptime def: *const gen.BodyPlanDefinition) []const body.PartDef {
    // Convert parts, include geometry
}

/// Comptime-built body plans
pub const BodyPlans = blk: {
    // Build from GeneratedBodyPlans
};

pub fn getBodyPlan(id: []const u8) ?*const []const body.PartDef {
    // Lookup by ID
}
```

### Phase 2: Runtime tissue layer type

Current `TissueLayer` is just an enum (skin, fat, muscle, etc.). Need a struct with 3-axis coefficients:

```zig
pub const TissueLayerMaterial = struct {
    id: []const u8,
    thickness_ratio: f32,
    // Shielding
    deflection: f32,
    absorption: f32,
    dispersion: f32,
    // Susceptibility
    geometry_threshold: f32,
    geometry_ratio: f32,
    momentum_threshold: f32,
    momentum_ratio: f32,
    rigidity_threshold: f32,
    rigidity_ratio: f32,
};

pub const TissueStack = struct {
    id: []const u8,
    layers: []const TissueLayerMaterial,
};
```

### Phase 3: Update Body.fromPlan

Change from hardcoded `HumanoidPlan` to using generated plan:

```zig
pub fn fromPlan(alloc: Allocator, plan_id: []const u8) !Body {
    const plan = body_list.getBodyPlan(plan_id) orelse return error.UnknownBodyPlan;
    // ... build body from plan
}
```

### Phase 4: Update tissue resolution

Current tissue damage uses hardcoded absorption fractions per layer. Update to use 3-axis model like armour:

```zig
fn resolveThroughTissue(part: *Part, packet: damage.Packet) TissueResult {
    const tissue_stack = body_list.getTissueStack(part.tissue_template);

    for (tissue_stack.layers) |layer| {
        // Derive axes
        const geometry = remaining.penetration;
        const momentum = remaining.amount;
        const rigidity = deriveRigidity(remaining.kind);

        // Apply shielding (like armour)
        // Check susceptibility (layer damage → wound severity contribution)
        // Build remaining packet
    }
}
```

### Phase 5: Integrate geometry

Generated parts have `geometry: { thickness_cm, length_cm, area_cm2 }`. Use for:
- Penetration path length (thickness affects how far attack must travel)
- Hit probability weighting (area affects targeting)
- Wound severity scaling (smaller parts = worse wounds per damage)

### Challenges / Open Questions

1. **Part geometry storage**: Add to runtime `Part` struct or lookup from plan?
2. **Tissue stack per-instance**: Does tissue degrade? Or always reference template?
3. **Wound interaction**: How do 3-axis tissue damage values map to wound severity?
4. **Backward compatibility**: Existing tests use `HumanoidPlan` directly

## Tasks / Sequence of Work

- [ ] **1.1** Create `body_list.zig` skeleton
- [ ] **1.2** Add `TissueLayerMaterial` and `TissueStack` types to body.zig
- [ ] **1.3** Implement `buildTissueStack()` in body_list.zig
- [ ] **1.4** Build static `TissueStacks` lookup table
- [ ] **2.1** Implement `buildBodyPlan()`
- [ ] **2.2** Build static `BodyPlans` lookup table
- [ ] **2.3** Add `getBodyPlan()`, `getTissueStack()` lookup functions
- [ ] **3.1** Update `Body.fromPlan` to use generated plan
- [ ] **3.2** Add geometry to runtime Part (or accessor)
- [ ] **4.1** Update tissue resolution to use 3-axis model
- [ ] **4.2** Wire tissue damage to wound severity
- [ ] **5.1** Update tests to use generated plans
- [ ] **5.2** Remove hardcoded `HumanoidPlan` and `TissueTemplate.layers()`

## Test / Verification Strategy

### Success criteria

- `just check` passes
- `Body.fromPlan("humanoid")` builds from generated data
- Tissue resolution uses 3-axis coefficients
- Damage flows correctly: armour → tissue layers → wound

### Unit tests

- `buildTissueStack` produces correct layer count and coefficients
- `buildBodyPlan` produces correct part count with geometry
- Tissue 3-axis resolution math

### Integration tests

- Full damage flow: packet → armour stack → tissue stack → wound
- Compare sword-vs-arm results with/without armour

## Quality Concerns / Risks

- Large change touching core body system
- May surface discrepancies between CUE data and hardcoded behavior
- Wound severity mapping needs design thought

## Progress Log / Notes

**2026-01-09**: Task created.
- CUE definitions complete in `data/bodies.cue` and `data/materials.cue`
- Generation pipeline emits `GeneratedBodyPlans` and `GeneratedTissueTemplates`
- Runtime body.zig still uses hardcoded enums and tables
- This completes the unified material model goal from §5 of design doc
