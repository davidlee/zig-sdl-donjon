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

### Critical Gap: CUE Schema Incomplete

**Problem**: The CUE body schema (`data/bodies.cue`) lacks parent/enclosing hierarchy.

Current `BodyPartDefinition` in generated data:
```zig
const BodyPartDefinition = struct {
    name: []const u8,
    tag: body.PartTag,
    side: body.Side = body.Side.center,
    tissue_template: body.TissueTemplate,  // Uses hardcoded enum!
    has_major_artery: bool = false,
    flags: body.PartDef.Flags = .{},
    geometry: BodyPartGeometry,
    // MISSING: parent, enclosing, base_hit_chance, base_durability, trauma_mult
};
```

vs runtime `PartDef`:
```zig
pub const PartDef = struct {
    id: PartId,
    parent: ?PartId,      // ← Missing from CUE
    enclosing: ?PartId,   // ← Missing from CUE
    tag: PartTag,
    side: Side,
    name: []const u8,
    base_hit_chance: f32, // ← Missing from CUE (from defaultStats)
    base_durability: f32, // ← Missing from CUE
    trauma_mult: f32,     // ← Missing from CUE
    flags: Flags = .{},
    tissue: TissueTemplate = .limb,
    has_major_artery: bool = false,
};
```

The hardcoded `HumanoidPlan` encodes hierarchy through helper functions:
```zig
vital("torso", .torso, .center, null),           // torso has no parent
vitalArtery("neck", .neck, .center, "torso"),    // neck → torso
vital("head", .head, .center, "neck"),           // head → neck
organ("brain", .brain, .center, "head", "head"), // brain enclosed by head
```

**Decision: Option B - Full migration**

## Design Decisions

### 1. Parent/Enclosing Hierarchy

Add explicit fields to CUE `#BodyPart`:

```cue
#BodyPart: {
    tag: string
    parent?: string      // part name for attachment chain
    enclosing?: string   // part name for containment
    // ... existing fields
}

parts: {
    torso: { tag: "torso" }  // no parent = root
    neck: { tag: "neck", parent: "torso" }
    head: { tag: "head", parent: "neck" }
    brain: { tag: "brain", parent: "head", enclosing: "head" }
    heart: { tag: "heart", parent: "torso", enclosing: "torso" }
    left_shoulder: { tag: "shoulder", parent: "torso" }
    left_arm: { tag: "arm", parent: "left_shoulder" }
    // ...
}
```

Part key = ID, parent/enclosing = string references to other part keys.
Validate references at Zig comptime (like `armour_list.zig` does for material IDs).

### 2. Stats (hit_chance, durability, trauma_mult)

**Keep deriving from tag in Zig** - no CUE change needed.

`defaultStats(tag: PartTag)` already provides sensible defaults per tag:
- `.torso` → `{ .hit_chance = 0.30, .durability = 2.0, .trauma_mult = 1.0 }`
- `.finger` → `{ .hit_chance = 0.01, .durability = 0.2, .trauma_mult = 2.0 }`
- etc.

`body_list.zig` will call `defaultStats(def.tag)` when building runtime `PartDef`.

### 3. Tissue Template Reference

CUE already has `tissue_template: string` (e.g., `"core"`, `"limb"`).

Change generated code to:
- Keep string ID in `BodyPartDefinition`
- `body_list.zig` resolves string → `TissueStacks` entry at comptime
- Remove dependency on hardcoded `TissueTemplate` enum for layer data

### 4. Geometry

Already complete in CUE. Wire to runtime:
- Add `geometry: BodyPartGeometry` to runtime `Part` or provide accessor
- Use for penetration path length, hit probability weighting, wound scaling

### Summary Table

| Field | Source | Approach |
|-------|--------|----------|
| parent/enclosing | CUE | Add fields, validate at Zig comptime |
| stats | Zig | Derive from tag via `defaultStats()` |
| tissue_template | CUE | String ID → lookup in `TissueStacks` |
| geometry | CUE | Already complete, wire to runtime |
| flags | CUE | Already complete ✓ |
| has_major_artery | CUE | Already complete ✓ |

## Tasks / Sequence of Work

### Phase 0: CUE Schema & Generation

- [ ] **0.1** Add `parent`/`enclosing` optional fields to CUE `#BodyPart` schema
- [ ] **0.2** Populate parent/enclosing for all 67 humanoid parts in `data/bodies.cue`
- [ ] **0.3** Update `cue_to_zig.py` to emit parent/enclosing in `BodyPartDefinition`
- [ ] **0.4** Change `tissue_template` from enum to string ID in generated code
- [ ] **0.5** Run `just generate`, verify output

### Phase 1: Tissue Stack Wiring

- [ ] **1.1** Add `TissueLayerMaterial` and `TissueStack` types to `body.zig`
- [ ] **1.2** Create `body_list.zig` skeleton (following `armour_list.zig` pattern)
- [ ] **1.3** Implement `buildTissueStack()` - convert generated def to runtime type
- [ ] **1.4** Build static `TissueStacks` lookup table at comptime
- [ ] **1.5** Add `getTissueStack(id: []const u8)` lookup function

### Phase 2: Body Plan Wiring

- [ ] **2.1** Update `BodyPartDefinition` to include parent/enclosing string fields
- [ ] **2.2** Implement `buildPartDef()` - convert generated def to runtime `PartDef`
  - Resolve parent/enclosing strings to `PartId` (comptime validation)
  - Call `defaultStats(tag)` for hit_chance/durability/trauma_mult
  - Resolve tissue_template string to `TissueStacks` reference
- [ ] **2.3** Build static `BodyPlans` lookup table at comptime
- [ ] **2.4** Add `getBodyPlan(id: []const u8)` lookup function

### Phase 3: Runtime Integration

- [ ] **3.1** Update `Body.fromPlan` signature: `fromPlan(alloc, plan_id: []const u8)`
- [ ] **3.2** Wire `Body.fromPlan` to use `body_list.getBodyPlan()`
- [ ] **3.3** Add geometry accessor (lookup from plan or store in `Part`)
- [ ] **3.4** Update callers of `Body.fromPlan` (tests, agent creation)

### Phase 4: Tissue Resolution Update

- [ ] **4.1** Update tissue damage resolution to use 3-axis model (like armour)
- [ ] **4.2** Wire tissue layer damage to wound severity contributions
- [ ] **4.3** Integration test: damage packet → armour → tissue → wound

### Phase 5: Cleanup

- [ ] **5.1** Remove hardcoded `HumanoidPlan` constant
- [ ] **5.2** Remove `TissueTemplate.layers()` method (superseded by `TissueStacks`)
- [ ] **5.3** Consider removing `TissueTemplate` enum if no longer needed
- [ ] **5.4** Update/remove obsolete tests

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

**2026-01-09**: Investigation session - schema gaps identified.

Bug fix completed:
- Fixed `scripts/cue_to_zig.py` flag mapping: `vital` → `is_vital`, `internal` → `is_internal`
- Previously output `.flags = .{ .vital = true }` but `PartDef.Flags` has `is_vital`
- Bug was hidden by Zig lazy compilation (unreferenced `GeneratedBodyPlans` not compiled)

Key findings:

1. **CUE `#BodyPart` lacks hierarchy** - no `parent`/`enclosing` fields
   - CUE stores parts as flat map: `parts: { torso: {...}, neck: {...}, ... }`
   - Zig hardcoded plan uses helpers that encode hierarchy: `vital("neck", ..., "torso")`
   - Blocking issue for full migration

2. **CUE lacks stats** - no `base_hit_chance`, `base_durability`, `trauma_mult`
   - Hardcoded plan derives these from `defaultStats()` based on part tag/flags
   - Could add to CUE or keep deriving from conventions

3. **Tissue template cross-reference**
   - CUE `tissue_template` is string ID (e.g., `"core"`)
   - Generated code converts to `body.TissueTemplate.core` (hardcoded enum)
   - Should reference generated `TissueStacks` instead after wiring

4. **Lazy compilation masked errors**
   - `GeneratedBodyPlans` not referenced anywhere in code
   - Zig tree-shakes unreferenced code, so flag name bug compiled silently
   - Will surface when we wire up the data

What IS ready to wire:
- `GeneratedTissueTemplates` - 6 templates (core, limb, digit, joint, facial, organ)
- Each has full 3-axis coefficients per layer (deflection/absorption/dispersion + susceptibility)
- `GeneratedBodyPlans` - 1 plan (humanoid) with 67 parts, each with geometry
- Geometry data complete: `thickness_cm`, `length_cm`, `area_cm2` per part

**2026-01-09**: Design decisions finalized.
- Chose Option B (full migration)
- Parent/enclosing: Add to CUE, validate at Zig comptime
- Stats: Keep deriving from tag via `defaultStats()`
- Tissue template: Change to string ID, lookup in `TissueStacks`
- Task sequence updated with 5 phases
- Ready for implementation
