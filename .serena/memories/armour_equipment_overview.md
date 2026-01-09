# Armour & Equipment Overview

## Data Model (3-Axis Physics)
- `src/domain/armour.zig` models armor through `Material` using 3-axis physics:
  - **Shielding** (protects layers beneath): deflection, absorption, dispersion
  - **Susceptibility** (damage to layer itself): geometry_threshold/ratio, momentum_threshold/ratio, rigidity_threshold/ratio
  - **Shape** modifiers: ShapeProfile enum (solid, mesh, quilted, laminar, composite) with bonus adjustments
- `Template` references `Material` and `Pattern` (coverage specs)
- `Instance` is runtime state with integrity tracking per covered part

## Generated Data Pipeline
- CUE definitions in `data/materials.cue`, `data/armour.cue` define materials and pieces
- `scripts/cue_to_zig.py` generates `src/gen/generated_data.zig` with `ArmourMaterialDefinition`, `ArmourPieceDefinition`
- `src/domain/armour_list.zig` provides:
  - `buildMaterial()` - converts CUE definition to runtime `Material`
  - `Materials`, `Patterns`, `Templates` - static comptime-built lookup tables
  - `getMaterial(id)`, `getTemplate(id)` - comptime ID-based lookup

## Runtime Flow
- `Instance.init(allocator, template, side)` creates armor instance from template
- `Stack.buildFromEquipped(body, equipped_instances)` aggregates coverage into per-part protection
- `resolveThroughArmour(stack, part_idx, packet, rng)` processes damage through layers using 3-axis physics

## Resolution Algorithm (3-axis)
For each layer (outer to inner):
1. Gap check (random based on totality)
2. Derive axes: geometry=penetration, momentum=amount, rigidity=f(damage.Kind)
3. Susceptibility: layer damage = Σ (axis - threshold) * ratio for each axis
4. Shielding: remaining.penetration = geo * (1 - deflection) - thickness; remaining.amount = mom * (1 - absorption)
5. Stop conditions: piercing/slashing stops if penetration=0; any attack stops if amount<0.05