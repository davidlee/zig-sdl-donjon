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
1. [x] Create `data/taxonomy.cue` and update `cue_to_zig.py`.
2. [x] Refactor `body.zig` to use generated `PartTag`.
3. [x] Implement scaling math in `Body.fromPlan`.
4. [x] Update `Agent.init` to pass species modifiers to `Body.fromPlan`.
5. [x] Add data-audit warning for missing `size_modifiers`.
6. [x] Verify scaling via unit tests (e.g., Dwarf should have shorter limbs than Human).

## Test / Verification Strategy
- **Scaling Test:** Assert that a Dwarf agent's torso thickness is greater than the plan default, and limb length is shorter.
- **Custom Tag Test:** Define a new tag `"wing"` in CUE and verify it compiles and can be equipped.

---

## Progress Notes

### Session 1 (2026-01-10)

**Completed:**

1. **Data-Driven PartTag** - DONE
   - Created `data/taxonomy.cue` with all valid part tags
   - Updated `cue_to_zig.py` to emit `pub const PartTag = enum {...};` at top of generated file
   - Changed `format_part_tag()` to use local `PartTag.x` instead of `body.PartTag.x`
   - Updated all 4 occurrences of `body.PartTag` in generator to use local enum
   - Added `taxonomy.cue` to Justfile's `generate` and `audit-data` recipes
   - `body_list.zig` re-exports: `pub const PartTag = generated.PartTag;`
   - `body.zig` imports: `pub const PartTag = body_list.PartTag;`
   - All tests pass

2. **Species size_modifiers wiring** - DONE
   - Generator already emits `size_height` and `size_mass` (confirmed)
   - Added `height_modifier: f32 = 1.0` and `mass_modifier: f32 = 1.0` to `Species` struct
   - Updated `buildSpecies()` to copy from generated definition
   - Compiles successfully

3. **Capability Abstraction** - Already done (no changes needed)
   - `graspStrength()` uses child iterator, not tag checks
   - `mobilityScore()` uses `p.flags.can_stand`

**Remaining:**

1. **Write tests** for scaling behavior
2. **Run `just check`** (format, test, build)

**Key files touched:**
- `data/taxonomy.cue` (new)
- `scripts/cue_to_zig.py`
- `Justfile`
- `src/gen/generated_data.zig` (regenerated)
- `src/domain/body_list.zig`
- `src/domain/body.zig`
- `src/domain/species.zig`
- `src/domain/combat/agent.zig`
- `src/domain/armour.zig`
- `src/domain/armour_list.zig`
- `src/testing/integration/domain/damage_resolution.zig`

### Session 1 continued...

**Additional completed work:**

4. **Scaling logic in Body.fromPlan** - DONE
   - Added `SizeModifiers` struct with `height` and `mass` fields (default 1.0)
   - Formulas implemented as methods with clear "GAME LOGIC" comments:
     - `lengthScale()` = height
     - `thicknessScale()` = mass / height (stockiness)
     - `areaScale()` = length * thickness
   - `scaleGeometry()` applies scaling to `BodyPartGeometry`
   - `fromPlan()` and `fromParts()` now accept `?SizeModifiers`
   - Updated ~30 call sites to pass `null` (tests) or actual modifiers (Agent.init)

5. **Agent.init wiring** - DONE
   - Creates `SizeModifiers{ .height = sp.height_modifier, .mass = sp.mass_modifier }`
   - Passes to `Body.fromPlan()`

6. **Data audit warning** - DONE
   - Added `audit_species()` function to `cue_to_zig.py`
   - Warns when species missing `size_modifiers`
   - Added `body_plan_refs` to AuditReport for cross-ref validation
   - Species -> body_plan cross-reference check added

### Session 2 (2026-01-10)

**Completed:**

7. **Scaling unit tests** - DONE
   - Added 3 tests in `body.zig` (lines 1891-1970):
     - `"T042: scaling modifiers adjust body geometry"`: Verifies dwarf-like mods (h=0.9, m=1.1) produce shorter length, thicker parts on torso
     - `"T042: scaling applies to all parts"`: Verifies tall/thin mods (h=1.2, m=0.8) affect body
     - `"T042: null modifiers preserve baseline geometry"`: Verifies null and `SizeModifiers.NONE` produce identical results
   - `just check` passes: format, unit tests, integration tests, system tests, build

**Task T042 COMPLETE** - Ready for user acceptance and move to `done/`.
