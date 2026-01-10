# Body System Overview

## Core Files
- `src/domain/body.zig` - Body struct, Part, PartDef, damage application
- `src/domain/body_list.zig` - Comptime wiring from CUE-generated data
- `data/bodies.cue` - Body plan definitions (humanoid, etc.)
- `data/taxonomy.cue` - T042: Data-driven PartTag enum values

## Creating Bodies
Bodies are created from CUE-generated plans via string ID, with optional scaling:
```zig
// Basic creation (no scaling)
var bod = try Body.fromPlan(alloc, "humanoid", null);

// With species scaling (T042)
const mods = SizeModifiers{ .height = 0.9, .mass = 1.1 };  // dwarf-like
var bod = try Body.fromPlan(alloc, "humanoid", mods);

// Test fixtures only
var bod = try Body.fromParts(alloc, &TestBodyPlan, null);
```

## Key Types
- `Body` - runtime body with ArrayList of Parts, hash index for lookups
- `Part` - runtime instance with severity, wounds, parent/enclosing indices
- `PartDef` - static definition (id, tag, side, flags, tissue, stats)
- `PartTag` - T042: Now generated from `data/taxonomy.cue` into `generated_data.zig`, re-exported via `body_list.zig`
- `TissueTemplate` - enum (limb, digit, joint, facial, organ, core)
- `TissueStack` / `TissueLayerMaterial` - generated 3-axis coefficients

## Generated Data (body_list.zig)
- `BodyPlans` - comptime array of `BodyPlan` structs
- `TissueStacks` - comptime array of `TissueStack` with layer materials
- `getBodyPlan("humanoid")` - comptime lookup
- `getBodyPlanRuntime("humanoid")` - runtime lookup (returns ?*const)
- `getTissueStack("core")` / `getTissueStackRuntime()` - tissue lookup

## Critical: Part Ordering
Parts MUST be in topological order (parents before children) because:
- `computeEffectiveIntegrities()` processes sequentially
- `out[i] = integrity * out[parent_idx]` requires parent already computed
- Generator uses `topological_sort_parts()` to ensure correct order

## Damage Flow
1. `outcome.zig` calls `armour.resolveThroughArmour()` (3-axis model)
2. Remaining damage goes to `body.applyDamageWithEvents()`
3. `applyDamage()` uses 3-axis model with generated TissueStack data:
   - Looks up tissue via `body_list.getTissueStackRuntime(@tagName(template))`
   - Tracks geometry (penetration), energy (amount), rigidity (from damage kind)
   - Per layer: **shielding** first (deflection/absorption/dispersion reduce axes)
   - Then **susceptibility** (post-shielding axes vs thresholds → layer damage)
   - Matches armour's 3-axis pattern per design doc §5.1

## T039: Dual Severity Model
Severity mapping distinguishes volume (energy) from depth (geometry):
- `severityFromVolume(energy_excess)` - how much tissue destroyed
- `severityFromDepth(geometry_excess)` - how deep the wound penetrates
- `computeLayerSeverity()` combines them based on `is_structural` flag

Rules:
- **Non-structural layers** (muscle, fat, skin): max of volume/depth severity, capped at `.disabled`
- **Structural layers** (bone, cartilage): volume drives severity; depth alone caps at `.broken`
- `.missing` requires structural layer + sufficient volume damage
- Small parts (area < 30 cm²) have reduced severing thresholds

## Severing Logic
`checkSevering(part, wound)` checks if a wound severs a part:
- Requires structural damage + soft tissue damage (slash)
- Pierce/bludgeon require structural `.missing` to sever
- Small parts sever more easily (threshold reduction)

## Capability Queries
- `effectiveIntegrity(idx)` - integrity factoring in parent chain
- `graspStrength(idx)` - hand strength including finger count
- `functionalGraspingParts(min)` - find working hands
- `mobilityScore()`, `visionScore()`, `hearingScore()`
- `getChildren(idx)`, `getEnclosed(idx)` - iterators

## Species Integration
`Species.body_plan_id: []const u8` references a body plan by ID.

T042: Species has `height_modifier` and `mass_modifier` (default 1.0).
Agent.init creates `SizeModifiers` from species and passes to `Body.fromPlan()`:
```zig
const mods = SizeModifiers{ .height = sp.height_modifier, .mass = sp.mass_modifier };
self.body = try Body.fromPlan(alloc, sp.body_plan_id, mods);
```

## T042: Body Scaling
`SizeModifiers` struct in `body.zig` scales geometry during body creation:
- `lengthScale()` = height (taller → longer limbs)
- `thicknessScale()` = mass / height (stockiness)
- `areaScale()` = length × thickness (exposed surface)
- `scaleGeometry(base)` applies all three to `BodyPartGeometry`

Example: Dwarf (h=0.9, m=1.1) → length 0.9×, thickness ~1.22×, area ~1.1×
