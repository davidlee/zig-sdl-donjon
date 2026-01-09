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

### Phase 0: CUE Schema & Generation ✓

- [x] **0.1** Add `parent`/`enclosing` optional fields to CUE `#BodyPart` schema
- [x] **0.2** Populate parent/enclosing for all 62 humanoid parts in `data/bodies.cue`
- [x] **0.3** Update `cue_to_zig.py` to emit parent/enclosing in `BodyPartDefinition`
- [x] **0.4** Change `tissue_template` from enum to string ID in generated code
- [x] **0.5** Run `just generate`, verify output

### Phase 1: Tissue Stack Wiring ✓

- [x] **1.1** Add `TissueLayerMaterial` and `TissueStack` types to `body.zig`
- [x] **1.2** Create `body_list.zig` skeleton (following `armour_list.zig` pattern)
- [x] **1.3** Implement `buildTissueStack()` - convert generated def to runtime type
- [x] **1.4** Build static `TissueStacks` lookup table at comptime
- [x] **1.5** Add `getTissueStack(id: []const u8)` lookup function

### Phase 2: Body Plan Wiring ✓

- [x] **2.1** Update `BodyPartDefinition` to include parent/enclosing string fields (done in Phase 0)
- [x] **2.2** Implement `buildPartDef()` - convert generated def to runtime `PartDef`
  - Resolve parent/enclosing strings to `PartId` (comptime validation)
  - Call `defaultStats(tag)` for hit_chance/durability/trauma_mult
  - Resolve tissue_template string to `TissueStacks` reference
- [x] **2.3** Build static `BodyPlans` lookup table at comptime
- [x] **2.4** Add `getBodyPlan(id: []const u8)` lookup function

### Phase 3: Runtime Integration

- [x] **3.1** Update `Body.fromPlan` signature: `fromPlan(alloc, plan_id: []const u8)`
- [x] **3.2** Wire `Body.fromPlan` to use `body_list.getBodyPlan()`
- [x] **3.3** Add geometry accessor (lookup from plan or store in `Part`)
  - Chose option (a): store geometry in `Part` (direct access, 12 bytes/part)
  - Added `geometry: BodyPartGeometry` to `body.PartDef` and `body.Part`
  - `body_list.buildPartDef` copies geometry from generated `BodyPartDefinition`
  - `applyDamage` now accepts geometry parameter (unused until upstream packet axes ready)
- [x] **3.4** Update callers of `Body.fromPlan` (tests, agent creation)

### Phase 4: Tissue Resolution Update

**Current state:** `body.applyDamage(packet, template: TissueTemplate)` at line 854:
- Uses `template.layers()` → hardcoded `TissueTemplate` enum's layers
- Uses `layerResistance()` / `layerDepth()` → hardcoded per-layer values
- Does NOT use 3-axis model from generated data

**Target:** Follow `armour.resolveThroughArmour()` pattern (line 316):
1. Derive axes: geometry (penetration), energy (amount), rigidity (from kind)
2. Susceptibility: layer takes damage when axes exceed thresholds
3. Shielding: deflection reduces geometry, absorption reduces energy

**Key files:**
- `body.zig:854` - `applyDamage()` - needs rewrite
- `body.zig:611` - `applyDamageToPart()` - calls applyDamage
- `body_list.zig` - `getTissueStackRuntime()` - provides tissue layers
- `armour.zig:316` - `resolveThroughArmour()` - pattern to follow

**Tasks:**
- [x] **4.1** Rewrite `applyDamage()` to:
  - Take `tissue_template_id: []const u8` instead of `TissueTemplate` enum
  - Lookup via `body_list.getTissueStackRuntime(id)`
  - Apply 3-axis model per layer using `TissueLayerMaterial` coefficients
  - Need geometry accessor (3.3) for part thickness → penetration path length
- [x] **4.2** Map layer damage to wound severity:
  - Current: `severityFromDamage(absorbed)` - simple threshold
  - New: consider geometry/energy/rigidity contributions separately?
- [ ] **4.3** Integration test: damage packet → armour → tissue → wound
  - Compare sword-vs-arm results with/without armour
  - Verify layer damage accumulates correctly

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

**2026-01-09**: Phase 0 complete - CUE schema & generation updated.
- [x] **0.1** Added `parent`/`enclosing` optional fields to CUE `#BodyPart` schema
- [x] **0.2** Populated parent/enclosing for all 62 humanoid parts in `data/bodies.cue`
  - Hierarchy matches hardcoded `HumanoidPlan`: torso→neck→head, torso→abdomen→groin, etc.
  - Organs have both parent and enclosing (e.g., brain: parent=head, enclosing=head)
  - Note: CUE has `tongue` which `HumanoidPlan` lacks (62 vs 61 parts)
- [x] **0.3** Updated `cue_to_zig.py` to emit parent/enclosing in `BodyPartDefinition`
- [x] **0.4** Changed `tissue_template` from enum to `tissue_template_id: []const u8`
- [x] **0.5** Ran `just generate` and `just check` - all tests pass

Generated data now includes:
- `parent: ?[]const u8` - attachment hierarchy (null for root parts)
- `enclosing: ?[]const u8` - containment for organs
- `tissue_template_id: []const u8` - string ID for lookup in tissue tables
- `BodyPartGeometry` and `BodyPartDefinition` now public (`pub const`)

Ready for Phase 1: Tissue Stack Wiring

**2026-01-09**: Phase 1 complete - Tissue stack wiring.
- [x] **1.1** Added `TissueLayerMaterial` and `TissueStack` types to `body.zig:186-217`
  - `TissueLayerMaterial`: material_id, thickness_ratio, 3-axis shielding, 3-axis susceptibility
  - `TissueStack`: id, layers[], `hasMaterial()` helper
- [x] **1.2** Created `body_list.zig` following `armour_list.zig` pattern
- [x] **1.3** Implemented `buildTissueLayer()` and `convertLayers()` converters
- [x] **1.4** Built static `TissueStacks` lookup table at comptime with `LayerData` backing
- [x] **1.5** Added `getTissueStack()` (comptime) and `getTissueStackRuntime()` (runtime) lookups
- Added comptime validation: `validateAllBodyParts()` checks all tissue_template_id references
- Added 9 unit tests for tissue stack wiring
- All tests pass

**Terminology fix:** Renamed `momentum_threshold`/`momentum_ratio` → `energy_threshold`/`energy_ratio` across CUE, Python generator, and Zig code. This aligns with the design doc (`geometry_momentum_rigidity_review.md` §3) which specifies **Geometry / Energy / Rigidity** as the 3-axis model, not "momentum".

Ready for Phase 2: Body Plan Wiring

**2026-01-09**: Phase 2 complete - Body plan wiring.
- [x] **2.2** Implemented `buildPartDef()` in `body_list.zig:169-208`
  - `stringToTissueTemplate()` converts string ID → TissueTemplate enum with helpful comptime error
  - `findPartIndexInPlan()` resolves part references within a body plan
  - Parent/enclosing strings validated and converted to `PartId` at comptime
  - Stats derived via `body.defaultStats(tag)` (made public)
- [x] **2.3** Built `PartDefData` + `BodyPlans` lookup tables following armour_list pattern
- [x] **2.4** Added `getBodyPlan()` (comptime) and `getBodyPlanRuntime()` (runtime) lookups
- Added `BodyPlan` struct with id, name, parts slice
- Added `validateAllPartReferences()` comptime validation
- Added 10 unit tests for body plan wiring
- All tests pass

Key implementation notes:
- `PartDef.tissue` still uses `TissueTemplate` enum (not string ID) - deferred to Phase 5
- Humanoid plan has 67 parts (CUE includes `tongue` which original `HumanoidPlan` lacked)
- Comptime errors include helpful file references (e.g., "Check data/bodies.cue")

Ready for Phase 3: Runtime Integration

**2026-01-10**: Phase 3 in progress - Runtime integration.
- [x] **3.1** Changed `Body.fromPlan(alloc, plan: []const PartDef)` → `fromPlan(alloc, plan_id: []const u8)`
- [x] **3.2** Added `fromParts(alloc, parts)` for test fixtures (e.g., armour.zig's `TestBodyPlan`)
- [x] **3.4** Updated all callers:
  - body.zig tests: `&HumanoidPlan` → `"humanoid"`
  - armour_list.zig, armour.zig: same
  - Species.body_plan → Species.body_plan_id (now uses CUE-generated plan ID)
  - agent.zig: uses `sp.body_plan_id`

**Critical fix:** Generator now outputs parts in topological order (parents before children).
- `computeEffectiveIntegrities()` requires parents to be processed before children
- Added `topological_sort_parts()` in `cue_to_zig.py` to ensure correct ordering
- Previously alphabetical order caused parent chain traversal to fail

**Branch quota increases:** Added `@setEvalBranchQuota()` to several comptime functions:
- `stringToTissueTemplate`, `findPartIndexInPlan`, `buildPartDef`, `buildBodyPlan`
- `validateAllBodyParts`, `validateAllPartReferences`
- 67 parts × multiple lookups × string comparisons exceeded default limits

**Generator fix:** Made `TissueLayerDefinition` public (was missing `pub`)

All tests pass. Geometry accessor (3.3) deferred - will add when Phase 4 needs it

**2026-01-10**: Phase 4.1 complete - Tissue resolution rewritten with 3-axis model.

Changes to `body.zig`:
- Added `materialIdToTissueLayer(material_id)` - converts string ID to TissueLayer enum
- Added `deriveRigidity(kind)` - derives rigidity axis from damage kind (matches armour.zig)
- Rewrote `applyDamage()` to use 3-axis model:
  - Looks up TissueStack via `body_list.getTissueStackRuntime(@tagName(template))`
  - Tracks all three axes: geometry (penetration), energy (amount), rigidity (from kind)
  - **Shielding** (per layer): deflection reduces geometry, absorption reduces energy, dispersion reduces rigidity
  - **Susceptibility** (per layer): uses POST-shielding axes vs thresholds/ratios to compute layer damage
  - Correctly implements doc §5.1: shielding first, then susceptibility on residuals

Test updates:
- "pierce damage" test: now verifies pierce reaches multiple layers and damages all penetrated layers
- "bludgeon damage" test: now verifies energy transfers through layers (outer absorb more)
- Removed old model assumptions (e.g., "skin_sev <= muscle_sev" for pierce was physically dubious)

Key insight from design doc: Dispersion reduces rigidity axis for the NEXT layer, not for self-damage calculation. This matches §5.1: "plate can have low dispersion (transmits force) yet high thresholds (hard to dent), while padding has high dispersion but low thresholds (protects what's beneath while getting chewed up)."

Note: Current tissue data produces physically reasonable but possibly unbalanced results. The damage number audit (mentioned in design doc §9) will tune coefficients. Model is correct; numbers need calibration.

All tests pass.

**2026-01-10**: Phase 4.1 fixes - axis decoupling and non-physical bypass.

Code review identified two issues with the initial implementation:

1. **Non-physical damage bypass** - Fire, radiation, magical damage was incorrectly running through 3-axis mechanics. Fixed: early return for non-physical kinds (§6 of design doc).

2. **Axis coupling via `dominated_by_pen`** - The check that stopped slash/pierce when geometry=0 prevented residual energy/rigidity from reaching deeper layers. This violated axis independence (§7.1). Fixed: removed the check; all three axes now flow independently through the layer stack.

**Blocked items documented in code:**

1. **Packet axes** (NOTE at line ~896): Currently derived from legacy `packet.amount`/`packet.penetration`. Blocked on upstream `damage.Packet` refactor to carry weapon/technique-derived Geometry/Energy/Rigidity directly. Until then, CUE weapon/technique coefficients are ignored.

2. **Thickness ratio** (TODO at line ~920): `layer.thickness_ratio` available but not yet used. Geometry accessor (task 3.3) now complete - `applyDamage` receives `geometry.thickness_cm`. Path-length math blocked on upstream `damage.Packet` refactor to carry proper axes.

All tests pass.

**2026-01-10**: Phase 3.3 complete - Geometry accessor added.
- Added `geometry: BodyPartGeometry` field to `body.PartDef` (plan definition)
- Added `geometry: BodyPartGeometry` field to `body.Part` (runtime instance)
- `body_list.buildPartDef` copies geometry directly from generated `BodyPartDefinition`
  - Comptime validation: if CUE omits geometry, compilation fails immediately
- `Body.fromParts` copies geometry from `PartDef` to `Part`
- Updated `applyDamage` signature to accept geometry parameter
  - `_ = geometry; // TODO` until upstream packet axes are available
  - Updated NOTE in function body about path-length math
- Updated test fixtures:
  - `TestGeometry` constant in body.zig and armour.zig for test calls
  - Hardcoded `HumanoidPlan` gets placeholder geometry (deprecated in Phase 5)

All tests pass. Phase 3 now fully complete.
