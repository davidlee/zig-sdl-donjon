# T033: Armour 3-Axis Material Migration
Created: 2026-01-09

## Problem statement / value driver

Armour and tissue layers should share a unified material model using 3-axis physics (Geometry/Energy/Rigidity) so damage resolution can compose `[cloak][mail][plate][skin][fat][bone]` stacks without special-casing armour vs body layers.

### Scope - goals

- Migrate `armour.Material` from per-damage-kind resistances to canonical 3-axis representation
- Build runtime loader converting generated `ArmourMaterialDefinition`/`ArmourPieceDefinition` to runtime types
- Wire generated armour into equipment system (`Stack.buildFromEquipped`)
- Update `resolveThroughArmour` to use 3-axis model

### Scope - non-goals

- Tissue/body migration (separate task, but should share the material schema)
- Species/natural weapons migration
- Full audit script (§9.4 #4 - separate)

## Background

### Relevant documents

- `doc/artefacts/geometry_momentum_rigidity_review.md` - design spec for 3-axis model
- `doc/artefacts/data_generation_plan.md` - CUE→Zig pipeline

### Key files

- `src/domain/armour.zig` - current armour types and resolution
- `src/domain/armour_list.zig` - comptime validation, will host runtime loader
- `src/gen/generated_data.zig` - generated armour materials/pieces
- `data/materials.cue`, `data/armour.cue` - source definitions

### Existing systems, memories, research, design intent

- Memory: `armour_equipment_overview` - current armour architecture
- §5 of geometry review: unified material schema with shielding (Deflection/Absorption/Dispersion) + susceptibility (per-axis threshold/ratio)
- §5.1: "Processing order: first apply shielding to compute residual axes, then test against layer's own susceptibility"

## Changes Required

### Phase 1: Update `armour.Material` struct

Current fields:
```zig
name, resistances, vulnerabilities, self_resistances, self_vulnerabilities,
quality, durability, thickness, hardness, flexibility
```

New canonical fields:
```zig
name: []const u8,
quality: Quality,

// Shielding - how layer protects what's beneath
deflection: f32,    // redirect/blunt penetrating edges (was: hardness)
absorption: f32,    // soak energy into layer structure
dispersion: f32,    // spread force across larger area

// Susceptibility - how layer itself takes damage (per-axis)
geometry_threshold: f32,
geometry_ratio: f32,
momentum_threshold: f32,  // "energy" axis in design doc
momentum_ratio: f32,
rigidity_threshold: f32,
rigidity_ratio: f32,

// Shape modifiers (from CUE)
shape_profile: ShapeProfile,  // solid, mesh, quilted
shape_dispersion_bonus: f32,
shape_absorption_bonus: f32,

// Transitional - derived from axes for old resolution code
thickness: f32,  // keep for penetration cost until resolution migrates
```

Remove:
- `resistances`, `vulnerabilities` (wearer effects - move to Template or effects system)
- `self_resistances`, `self_vulnerabilities` (replaced by axis susceptibility)
- `flexibility` (fold into shape modifiers or remove)

### Phase 2: Runtime loader in `armour_list.zig`

Add:
- `pub fn buildMaterial(comptime def: *const ArmourMaterialDefinition) Material`
- `pub fn buildTemplate(comptime def: *const ArmourPieceDefinition) Template`
- Comptime-constructed lookup tables: `pub const Materials`, `pub const Templates`

### Phase 3: Wire into equipment

- `Instance.init` works with new Material
- `Stack.buildFromEquipped` unchanged (already generic)
- May need to update `InstanceCoverage` if Material shape changes

### Phase 4: Update resolution

Migrate `resolveThroughArmour` to:
1. Apply shielding (deflection/absorption/dispersion) to compute residual axes
2. Test residuals against layer susceptibility thresholds
3. Compute layer damage and integrity loss

#### Phase 4 Approach: Derive Axes from Packet (Option A)

The full 3-axis model (§5 of design doc) envisions `damage.Packet` carrying explicit geometry/momentum/rigidity values derived during `createDamagePacket`. However, extending the packet requires changes to weapon/technique data and upstream resolution.

**For this task**, we derive axis values *within* `resolveThroughArmour` from the existing packet fields:

```
geometry  ≈ packet.penetration  (concentrated force along narrow contact)
momentum  ≈ packet.amount       (total energy in the attack)
rigidity  = f(packet.kind)      (derived from damage type)
```

Rigidity derivation from `damage.Kind`:
| Kind     | Rigidity | Rationale |
|----------|----------|-----------|
| pierce   | 1.0      | Concentrated tip, structurally supported |
| slash    | 0.7      | Edge cuts but less concentrated than pierce |
| bludgeon | 0.8      | Blunt impact, some spread |
| crush    | 1.0      | Overwhelming concentrated force |
| shatter  | 1.0      | Brittle fracturing, high concentration |
| (non-physical) | 0.0 | No physical rigidity component |

**Resolution algorithm:**
1. Gap check (unchanged)
2. Derive axis values from packet
3. Apply shielding: `residual_X = X * (1 - material.effectiveX())` where X ∈ {geometry→deflection, momentum→absorption}
4. Dispersion reduces what passes to next layer (modifies output packet)
5. Check susceptibility: if `residual_X > threshold_X`, layer takes `(residual_X - threshold_X) * ratio_X` damage
6. Compute total layer damage, update integrity
7. Build output packet for next layer

#### Future Work: Option B (Packet-Native Axes)

When weapons/techniques migrate to 3-axis, extend `damage.Packet`:
```zig
pub const Packet = struct {
    // Legacy (keep for compatibility)
    amount: f32,
    kind: Kind,
    penetration: f32,

    // 3-axis physics (populated by createDamagePacket)
    geometry: f32,   // from weapon geometry + technique bias
    momentum: f32,   // from weapon energy + technique scaling
    rigidity: f32,   // from weapon rigidity + grip modifiers
};
```

This requires:
- Update `createDamagePacket` to derive axes from weapon template + technique
- Update CUE weapon schema with axis coefficients (partially done in `data/weapons.cue`)
- Natural weapons need axis derivation in species data
- Resolution can then use packet axes directly instead of deriving them

### Challenges / Tradeoffs / Open Questions

1. **Derived thickness**: keep for penetration cost or fold into geometry?
2. **Wearer resistances**: where do "wearing plate gives fire resistance" effects go?
3. **Quality multiplier**: applies to durability - does it affect axis values too?
4. **Shape enum vs string**: CUE uses string, Zig should probably use enum

### Decisions

- Keep `thickness` during transition; resolution uses it for penetration cost
- Wearer effects deferred - not blocking armour migration
- Quality multiplies a base durability; axis coefficients are material-intrinsic

## Tasks / Sequence of Work

- [x] **1.1** Add `ShapeProfile` enum to armour.zig
- [x] **1.2** Update `Material` struct with new fields, mark old fields `// DEPRECATED`
- [x] **1.3** Update `TestMaterials` to use new schema
- [x] **2.1** Add `buildMaterial` in armour_list.zig
- [x] **2.2** Add static `Materials`, `Patterns`, `Templates` lookup tables
- [x] **2.3** Add `getMaterial`, `getTemplate` lookup functions
- [x] **3.1** Make `Instance`, `resolvePartIndex` public
- [x] **3.2** Verify `Stack.buildFromEquipped` works with generated templates (integration tests)
- [x] **4.1** Update `resolveThroughArmour` to use shielding axes
- [x] **4.2** Update `resolveThroughArmour` to use susceptibility axes
- [x] **4.3** Remove deprecated fields and `getMaterialResistance`

## Test / Verification Strategy

### success criteria / ACs

- `just check` passes at each phase boundary
- Generated armour pieces resolve to valid runtime types at comptime
- Existing armour tests pass (with updated test materials)
- Resolution produces sensible results for hammer-vs-gambeson, sword-vs-plate scenarios

### unit tests

- Material field validation (coefficients in valid ranges)
- buildMaterial/buildTemplate produce correct output
- Resolution shielding math (deflection reduces geometry, etc.)

### integration tests

- Full flow: equip generated armour → build stack → resolve damage

## Quality Concerns / Risks / Potential Future Improvements

- Tissue migration should reuse same Material schema (verify compatibility)
- Natural weapons need similar axis derivation
- May want material presets/inheritance in CUE to reduce repetition

## Progress Log / Notes

**2026-01-09**: Task created. Current state:
- `armour_list.zig` has comptime validation for generated data
- Generated data uses 3-axis model; runtime `armour.Material` uses old model
- Resolution (`resolveThroughArmour`) uses hardness/thickness/per-kind resistances

**2026-01-09 (session 2)**: Phases 1-3 complete.
- `armour.Material` now uses canonical 3-axis fields (deflection/absorption/dispersion, per-axis susceptibility)
- Added `ShapeProfile` enum with `fromString` for CUE→Zig conversion
- Deprecated fields kept with defaults for transitional resolution compatibility
- `TestMaterials` updated to new schema with deprecated `self_resistances` for old tests
- `armour_list.zig` now provides:
  - `buildMaterial()` - converts generated definition to runtime Material
  - `Materials` - static array of all runtime materials
  - `Patterns` / `Templates` - static arrays of runtime patterns and templates
  - `getMaterial()` / `getTemplate()` - comptime lookup by ID
- Integration tests verify generated templates work with `Instance.init` and `Stack.buildFromEquipped`
- Made `Instance`, `Template`, `Pattern`, `PatternCoverage`, `resolvePartIndex` public

**2026-01-09 (session 3)**: Phase 4 complete. Task finished.
- Implemented 3-axis resolution in `resolveThroughArmour` and `resolveThroughArmourWithEvents`
- Added `deriveRigidity(kind)` helper to derive rigidity coefficient from damage kind
- Resolution now uses:
  - **Shielding**: deflection reduces geometry (penetration), absorption reduces momentum (amount)
  - **Susceptibility**: layer damage computed from (axis - threshold) * ratio for each axis
  - **Penetration exhaustion**: piercing/slashing stopped when geometry reaches 0
  - **Full absorption**: attack stopped when momentum < 0.05
- Removed deprecated fields from `Material`:
  - `resistances`, `vulnerabilities`, `self_resistances`, `self_vulnerabilities`
  - `hardness`, `flexibility`
- Removed `getMaterialResistance()` and its tests
- Updated all test materials and inline test fixtures to use clean 3-axis schema
- Updated test expectations to match new deterministic shielding model (vs old random hardness checks)
- All tests pass (`just check`)

**Option B deferred**: When weapons/techniques migrate, extend `damage.Packet` with explicit geometry/momentum/rigidity fields populated by `createDamagePacket`. See "Phase 4 Approach" section for details.
