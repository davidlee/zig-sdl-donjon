# Data Schema & Generation Plan

**Related**: `doc/issues/data_generation.md`, `doc/artefacts/geometry_momentum_rigidity_review.md`, `doc/issues/impulse_penetration_bite.md`

## 1. Goals

- Reduce repetition and boilerplate when defining weapons, armour, species, and body templates.
- Encode shared physical materials (armour plates, padding, bone, muscle) exactly once so armour and tissues inherit consistent shielding/self-damage behaviour.
- Support derived fields (Geometry, Momentum, Rigidity, derived resistances) via declarative formulas rather than hand-authored numbers.
- Provide validation before Zig compilation (type checks, constraint enforcement, required coverage).
- Enable tooling to audit the full dataset (search, stats, linting) outside of Zig.

## 2. Target Data Sets

| Domain | Current Files | Schema Needs |
| --- | --- | --- |
| Weapons & natural weapons | `src/domain/weapon_list.zig`, `src/domain/species.zig` | Physical dimensions, mass properties, offensive profiles, derived axes |
| Armour materials & pieces | `src/domain/armour.zig`, `src/domain/inventory.zig` | Material properties (Deflection/Absorption/Dispersion, self-thresholds), coverage patterns |
| Tissue/body templates | `src/domain/body.zig` | Reference to shared tissue materials, per-part scale factors (thickness/area) |
| Species definitions | `src/domain/species.zig` | Body plan selection, size modifiers, natural weapons |

## 3. Schema Strategy

- **Authoring language**: CUE (see `doc/issues/data_generation.md`). Benefits: strong typing, defaults/embedding, derived expressions, validation.
- **Shared material library**:
  - Define a `#Material` schema capturing:
    - Identity (`name`, optional metadata)
    - Shielding coefficients: `deflection`, `absorption`, `dispersion`
    - Self-susceptibility: thresholds/ratios per axis (e.g., `impact_threshold`, `rigidity_ratio`)
    - Geometry-aware modifiers (e.g., quilting vs. plate) via optional `shape` sub-struct.
  - Provide presets for biological tissues (`bone`, `muscle`, `fat`, `cartilage`) and armour materials (`steel_plate`, `chainmail`, `gambeson`, `leather`).
- **Weapons**:
  - Base schema referencing shared materials for durability (blade steel, haft wood).
  - Derived fields for Geometry/Momentum/Rigidity using physical inputs (weight, length, balance, curvature) and technique tags (`swing`, `thrust`, `draw_cut`).
  - Allow mixins for grips (half-sword, murder-stroke) that override derived coefficients.
- **Armour pieces**:
  - Reference material presets; specify coverage (body tags, sides, layers) declaratively.
  - Use totality presets (intimidating/comprehensive/etc.) plus optional adjustments per face (front/back).
- **Bodies & species**:
  - Part definitions link to tissue material presets, optionally scaling thickness/area.
  - Species supply multiplicative modifiers (overall size, limb-length ratios) and natural weapon references.

## 4. Generation Pipeline

1. **Source layout**
   - `data/materials.cue` – shared material presets
   - `data/weapons/*.cue` – weapon families (swords, axes, improvised, natural)
   - `data/armour/*.cue` – armour materials and templates
   - `data/bodies/*.cue` – tissue presets and body plans
2. **Validation**
   - `cue vet` / `cue export` ensures schema constraints are satisfied (e.g., required coverage, normalized reach tags).
3. **Export**
   - `cue export ... --out json` feeding a Zig generator script (`scripts/cue_to_zig.zig` or Python) that maps CUE structs to existing Zig const structures.
   - Generator enforces deterministic ordering and emits helpful comments linking back to source files.
4. **Build integration**
   - Add `just generate-data` invoked by `just check` before Zig compilation (guarded by file timestamps).
   - Generated Zig files remain checked in initially to keep diffs reviewable; once stable, consider `build.zig` hooks.

## 5. Ergonomics & Edge Cases

- **Shape modifiers**: materials can define optional profiles (e.g., `quilted`, `lamellar`, `solid_plate`) that adjust Dispersion/Absorption to capture geometry-dependent behaviour without duplicating entire materials.
- **Hooks / serrations / draw cuts**: express via boolean tags or embedded structs that tweak derived Geometry/Momentum splits for specific offensive profiles.
- **Species scaling**: allow per-species overrides for baseline part thickness (e.g., Dwarf torso thickness multiplier) so materials aren’t redefined per species.
- **Manual overrides**: everything derived should still permit explicit overrides for exceptional artefacts (ancient relics, magical materials).

## 6. Open Questions

1. Do we generate *only* data, or also helper lookup tables (e.g., ID→template maps)?
2. Should generated Zig live in `src/gen/` to keep diffs contained?
3. How do we version/checksum data sources to ensure in-game saves know which schema version they reference?
4. How do we keep CUE expressions manageable for designers unfamiliar with the language? (Possible answer: provide template files and lint scripts.)

## 7. Next Steps

1. Prototype the shared `#Material` schema (armour + tissue presets) in CUE.
2. Map existing `weapon_list.zig` entries into CUE to test derivation formulas.
3. Build the minimal `cue export → Zig` converter and integrate into `just generate-data`.
4. Document authoring workflow (how to add a new weapon, how to adjust a tissue material).
