# T042: Generalized Physiology & Scaling
Created: 2026-01-10

## Problem statement / value driver
The current implementation of body parts is heavily coupled to humanoid physiology. `PartTag` is a fixed Zig enum, and body geometry is statically defined in body plans without account for species-level scaling (e.g., a Dwarf being shorter but stockier than a baseline human). We need to unlock arbitrary physiologies (amoeboids, multi-limbed) and dynamic scaling to meet the design goals.

### Scope - goals
- **Data-Driven Taxonomy:** Move `PartTag` from a hardcoded Zig enum to a CUE-generated enum.
- **Dynamic Body Scaling:** Implement logic to scale per-part `thickness`, `length`, and `area` based on species-level `height` and `mass` modifiers.
- **Abstract Part Interfaces:** Ensure core logic (grasping, mobility) uses capability flags rather than hardcoded tag lookups where possible.

### Scope - non-goals
- Implementing full anatomical models for complex non-humanoids (we just need the *support* for them).
- Redesigning the hit-distribution (exposure) tables (keep `humanoid_exposures` for now).

## Background
- `doc/reviews/non_humanoid_risks.md` identifies the hardcoded `PartTag` as a critical bottleneck.
- `data/bodies.cue` currently contains static geometry values.
- `SpeciesDefinition` in CUE already contains `size_modifiers` (height/mass).

## Changes Required

### 1. Data-Driven Tags
- Create `data/taxonomy.cue` listing all valid `PartTag` values.
- Update `cue_to_zig.py` to generate `pub const PartTag = enum { ... };` in `src/gen/generated_data.zig`.
- Refactor `src/domain/body.zig` to use the generated enum.

### 2. Body Scaling Logic
- Define scaling formulas in `body.zig`:
    - `length_scale = species.height_modifier`
    - `thickness_scale = species.mass_modifier / species.height_modifier` (approximation of stockiness)
    - `area_scale = thickness_scale * length_scale` (exposed surface)
- Update `Body.fromPlan` to accept these modifiers and apply them to the `Part` geometry during initialization.

### 3. Capability Abstraction
- Review `Body.graspStrength`, `mobilityScore`, etc.
- Ensure they rely on `flags.can_grasp` and `flags.can_stand` rather than tag-specific checks.

## Tasks / Sequence of Work
1. [ ] Create `data/taxonomy.cue` and update `cue_to_zig.py`.
2. [ ] Refactor `body.zig` to use generated `PartTag`.
3. [ ] Implement scaling math in `Body.fromPlan`.
4. [ ] Update `Agent.init` to pass species modifiers to `Body.fromPlan`.
5. [ ] Verify scaling via debug prints or unit tests (e.g., Dwarf should have shorter limbs than Human).

## Test / Verification Strategy
- **Scaling Test:** Assert that a Dwarf agent's torso thickness is greater than the plan default, and limb length is shorter.
- **Custom Tag Test:** Define a new tag `"wing"` in CUE and verify it compiles and can be equipped.
