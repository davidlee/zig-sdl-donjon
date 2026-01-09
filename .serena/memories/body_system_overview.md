# Body System Overview

## Core Files
- `src/domain/body.zig` - Body struct, Part, PartDef, damage application
- `src/domain/body_list.zig` - Comptime wiring from CUE-generated data
- `data/bodies.cue` - Body plan definitions (humanoid, etc.)

## Creating Bodies
Bodies are now created from CUE-generated plans via string ID:
```zig
var bod = try Body.fromPlan(alloc, "humanoid");  // uses body_list lookup
var bod = try Body.fromParts(alloc, &TestBodyPlan);  // for test fixtures only
```

The old `HumanoidPlan` constant still exists but is deprecated (Phase 5 cleanup).

## Key Types
- `Body` - runtime body with ArrayList of Parts, hash index for lookups
- `Part` - runtime instance with severity, wounds, parent/enclosing indices
- `PartDef` - static definition (id, tag, side, flags, tissue, stats)
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

## Capability Queries
- `effectiveIntegrity(idx)` - integrity factoring in parent chain
- `graspStrength(idx)` - hand strength including finger count
- `functionalGraspingParts(min)` - find working hands
- `mobilityScore()`, `visionScore()`, `hearingScore()`
- `getChildren(idx)`, `getEnclosed(idx)` - iterators

## Species Integration
`Species.body_plan_id: []const u8` references a body plan by ID.
Agent.init looks up the plan: `Body.fromPlan(alloc, sp.body_plan_id)`
