# Data Schema & Generation Plan

**Related**: `doc/issues/data_generation.md`, `doc/artefacts/geometry_momentum_rigidity_review.md`, `doc/issues/impulse_penetration_bite.md`

## 0. Current Status (2026-01-09)

- `data/materials.cue`, `data/weapons.cue`, `data/techniques.cue`, and `data/armour.cue` are live and checked in.
- `scripts/cue_to_zig.py` exports weapons (with `moment_of_inertia`, `effective_mass`, `reference_energy_j`) and techniques (channels, damage instances, scaling, overlays, axis bias, etc.), validates technique IDs, and emits `src/gen/generated_data.zig`.
- `just generate` (wired into `just check`) runs the export pipeline automatically; generated files live under `src/gen/`.
- `src/domain/card_list.zig` imports `generated_data.zig`, builds `TechniqueEntries` from the generated definitions at comptime, and retains all overlay/axis metadata.
- `data/bodies.cue` now captures shared tissue templates (referencing the same material presets as armour), per-part geometry metadata for the humanoid plan, and species definitions (body plan selection, resource baselines, natural weapon references). The converter emits `GeneratedTissueTemplates`, `GeneratedBodyPlans`, and `GeneratedSpecies` tables for audit/visualisation.
- Immediate next wiring targets: plug generated armour pieces into runtime resolution and extend the converter to emit material stacks for armour coverage.

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
| Techniques & grips | `src/domain/card_list.zig`, `src/domain/weapon.zig` | Attack modes, axis conversion factors/biases, grip mixins (half-sword, murder-stroke), tags for hooks/draw cuts |
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
3. **Export format**
   - `cue export ... --out json` produces a normalized JSON structure. Proposed shape:

```jsonc
{
  "materials": {
    "tissues": { "muscle": { ...shared fields... } },
    "armour": { "steel_plate": { ... } }
  },
  "weapons": {
    "swords": {
      "knights_sword": {
        "name": "Knight's Sword",
        "category": "sword",
        "physics": {
          "weight_kg": 1.4,
          "length_m": 0.95,
          "balance": 0.55,
          "energy_j": 18.2,
          "geometry_coeff": 0.6,
          "rigidity_coeff": 0.7
        },
        "profiles": {
          "swing": { "reach": "medium" },
          "thrust": { "reach": "medium" }
        }
      }
    }
  }
}
```

   - This JSON feeds a Zig/Python generator (`scripts/cue_to_zig.py` in the prototype) that maps directly to existing structs (`weapon.Template`, `armour.Material`, etc.).
   - Generator enforces deterministic ordering and emits helpful comments linking back to CUE sources. The current prototype produces a `GeneratedWeapons` table to validate the flow before wiring in the rest of the systems.
4. **Build integration**
   - Add `just generate-data` invoked by `just check` before Zig compilation (guarded by file timestamps).
   - Generated Zig files remain checked in initially to keep diffs reviewable; once stable, consider `build.zig` hooks.

## 5. Ergonomics & Edge Cases

- **Shape modifiers**: materials can define optional profiles (e.g., `quilted`, `lamellar`, `solid_plate`) that adjust Dispersion/Absorption to capture geometry-dependent behaviour without duplicating entire materials.
- **Hooks / serrations / draw cuts**: express via boolean tags or embedded structs that tweak derived Geometry/Momentum splits for specific offensive profiles.
- **Species scaling**: allow per-species overrides for baseline part thickness (e.g., Dwarf torso thickness multiplier) so materials aren’t redefined per species.
- **Manual overrides**: everything derived should still permit explicit overrides for exceptional artefacts (ancient relics, magical materials).
- **Armour pieces**: in addition to raw materials, define `#ArmourPiece` schemas that assemble layers (`padding + plate`) with coverage templates so equipment can be generated alongside weapons and techniques.
- **Technique validation**: the converter must validate that every technique ID exported from CUE maps to a Zig enum variant (and ideally generate the enum) to prevent silent mismatches.

## 6. Open Questions

1. Do we generate *only* data, or also helper lookup tables (e.g., ID→template maps)?
2. Should generated Zig live in `src/gen/` to keep diffs contained?
3. How do we version/checksum data sources to ensure in-game saves know which schema version they reference?
4. How do we keep CUE expressions manageable for designers unfamiliar with the language? (Possible answer: provide template files and lint scripts.)

## 7. Next Steps

1. Prototype the shared `#Material` schema (armour + tissue presets) in CUE.
2. Map existing `weapon_list.zig` entries into CUE to test derivation formulas. (Initial prototypes in `data/weapons.cue` cover swords and improvised rocks.)
3. Extend the schema to cover techniques/grips with the conversion metadata required by the Geometry/Energy/Rigidity model (draw cuts, hooks, half-sword, etc.).
4. Add `#ArmourPiece` schemas (layer stacks, coverage templates) and extend the converter so armour items are generated alongside weapons/techniques.
5. Update the converter to validate technique IDs against the Zig enum (or generate the enum) so typos fail early.
6. Build the minimal `cue export → Zig` converter and integrate into `just generate-data`.
7. Document authoring workflow (how to add a new weapon or technique, how to adjust a tissue/armour material).

---

## 8. Wiring Plan – Tissues, Body Plans, Species (2026-01-09)

Now that `data/bodies.cue` and the generator emit `GeneratedTissueTemplates`, `GeneratedBodyPlans`, and `GeneratedSpecies`, we need a staged plan to migrate runtime systems away from bespoke Zig tables.

### 8.1 Required Schema Extensions
- **Parent/enclosing references:** `PartDef` needs `parent` and `enclosing` IDs to build the anatomical tree. Extend `#BodyPart` with `parent` (attachment) and optional `enclosing` (protective shell). Enforce via CUE validation that parents exist and that enclosing targets live earlier in the structure to permit comptime construction.
- **Exposure/coverage metadata:** current `HumanoidPlan` leans on hard-coded exposure tables (`humanoid_exposures`). We should either embed the exposure entries directly per part (prob weighted hit chance per height/side) or reference a shared exposure preset. Without this, hit selection can’t move off the static Zig array.
- **Flag parity:** `#BodyPart.flags` already mirrors `PartDef.Flags`; ensure the schema explicitly validates boolean presence so we don’t silently drop capabilities (vision/hearing/grasp/stand).
- **Tissue thickness alignment:** each template currently provides `thickness_ratio` weights, but we also need an absolute reference thickness per part to convert ratios into actual lengths when computing penetration. Add a `thickness_cm` on parts (already present) and ensure the generator computes derived layer thicknesses for convenience.

### 8.2 Runtime Integration Strategy
1. **Tissue templates first**
   - Introduce a `body/generated_loader.zig` helper that imports `GeneratedTissueTemplates` and builds a comptime dictionary mapping `body.TissueTemplate` enum values to the generated layer stacks. This keeps the rest of the body code referencing the existing enum while allowing us to drive layer properties from data.
   - Replace the hard-coded `layerResistance` absorption/pen tables with functions that consult the generated template → material stack (using the shielding/susceptibility coefficients from `data/materials.cue`). Until the three-axis resolution lands, emit equivalent `absorb`/`pen_cost` aggregates to preserve behaviour.
2. **Body plan generation**
   - Once `#BodyPart` stores `parent`/`enclosing`, write a comptime builder that walks `GeneratedBodyPlans.humanoid.parts`, resolves string IDs to `PartId`s, and produces the existing `PartDef` array. This preserves existing APIs (`body.HumanoidPlan`) but makes the data originate from CUE.
   - Validate at comptime that the generated part count and tag coverage match the previous hard-coded plan (unit test can compare `body.HumanoidPlan.len` against a constant, or even diff by tag).
3. **Species migration**
   - Replace the Zig `Species` constants with a loader that instantiates species records from `GeneratedSpecies`. Natural weapons will reference the generated weapon IDs; add a mapping layer that resolves `weapon_id` strings to existing `weapon.Template` pointers (covering both hand-made Zig templates and generated ones until weapons fully migrate).
   - Move per-species size/blood/stamina defaults into the generated table to retire the Zig definitions.
4. **Armour/tissue integration**
   - Use the shared materials from `GeneratedTissueTemplates.layers[].material_id` to build per-layer `armour.Material` references so armour and tissue layers literally use the same structs during combat resolution. This sets the stage for the unified layer stack from the Geometry review.

### 8.3 Validation & Tooling
- Extend the Python converter to emit assertions or warnings when:
  - A `body_part.parent` reference is missing or loops back.
  - A species references an unknown body plan or natural weapon ID.
  - Tissue templates cite materials not defined in `data/materials.cue`.
- Add a debug command (`just audit-data`) that dumps summaries (part count, coverage per tag, missing capabilities) so the data audit can inspect completeness without diving into Zig.

### 8.4 Rollout Order
1. Implement schema additions and converter updates (parents, exposures, species references).
2. Land the tissue template loader and replace `layerResistance` to start consuming generated materials immediately.
3. Port `HumanoidPlan` construction to use the generated body plan once the schema can describe the tree.
4. Migrate species definitions, natural weapon bindings, and size scalars to the generated data.

Each step should retain the existing external API (enum types, function signatures) so downstream systems stay stable while we transition data sources. Only after all consumers read from generated structures should we delete the old Zig constants.

---

## Appendix: Bootstrap Commands

- Author materials in `data/materials.cue` and validate via:

```bash
cue eval data/materials.cue
```

- Export to JSON (input for forthcoming Zig generator):

```bash
cue export data/materials.cue data/weapons.cue data/techniques.cue --out json \
  | ./scripts/cue_to_zig.py > src/gen/generated_data.zig
```

These commands provide immediate feedback before the full generation pipeline is wired into `just generate-data`.

> **Tooling note:** the commands above require the [`cue`](https://cuelang.org/) CLI to be installed on the path. Install instructions vary by platform (`brew install cue-lang/tap/cue`, `go install cuelang.org/go/cmd/cue@latest`, etc.). Until `cue` is available locally the export/generation pipeline cannot run.
