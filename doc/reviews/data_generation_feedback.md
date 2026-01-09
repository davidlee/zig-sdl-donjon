# Review: Data Generation Strategy & CUE Schemas

**Target Artefacts:** `doc/issues/data_generation.md`, `doc/artefacts/data_generation_plan.md`, `data/*.cue`  
**Reviewer:** Gemini CLI  
**Date:** 2026-01-09

## 1. Validation
I have reviewed the provided documents and the `.cue` files in `data/`. The implementation status is **Proto-Prototype**:
*   **Materials:** `data/materials.cue` correctly implements the unified model (shielding + susceptibility) required by the [Geometry/Momentum/Rigidity proposal](doc/reviews/geometry_momentum_rigidity_feedback.md).
*   **Techniques:** `data/techniques.cue` successfully adds the `axis_bias` struct, addressing the need for technique-specific conversion factors.
*   **Weapons:** `data/weapons.cue` demonstrates the physics derivation logic (`_moment_inertia`), validating the feasibility of "physics-first" data.

## 2. Feasibility
The plan to use CUE -> JSON -> Zig is **highly feasible** and solves the "magic number" problem.
*   **Math Capability:** CUE's `math.Pow` handles the inertia calculations correctly in the schema.
*   **Integration:** The `just generate-data` approach is the correct way to handle this without complicating the main `build.zig` initially.

## 3. Gaps & Risks

### 3.1. Static vs. Dynamic Energy Derivation
**Critical Finding:** `data/weapons.cue` calculates `energy_j` using a static `angular_speed_rad_s` (default 6.0).
*   **Risk:** In-game damage depends on *actual* swing speed (modified by stats, fatigue, wounds). If we only export `energy_j`, we lose the ability to scale damage dynamically.
*   **Fix:** The CUE export must provide the **Inertia** (for swings) and **Effective Mass** (for thrusts) as runtime constants. `energy_j` in CUE should be treated as a "Reference Value" (e.g., "Damage Rating") for UI comparison, not the raw input for the combat engine. The engine should compute `Energy = 0.5 * inertia * (stats.speed)^2`.

### 3.2. Armour Template Definition
*   **Gap:** `data/materials.cue` defines the *substance* (Steel, Bone) but not the *Item* (Breastplate, Helm).
*   **Missing Schema:** We need a schema for `#ArmourPiece` that composes materials into layers (e.g., `layers: [padding, plate]`) and defines coverage. The current plan mentions this but the file is missing.

### 3.3. Technique ID Sync
*   **Gap:** `data/techniques.cue` uses string IDs (`"thrust"`). Zig uses an enum (`.thrust`).
*   **Risk:** If a CUE ID has a typo, the generator might produce a valid Zig struct with a string field, but the runtime lookup will fail or the enum won't match.
*   **Refinement:** The generation script (`scripts/cue_to_zig.py`) must validate that every CUE ID maps to an existing (or generated) Zig Enum variant.

## 4. Refinements to Roadmap

### 4.1. Refine Weapon Export Schema
Modify `#Weapon` in CUE to explicitly export the physics constants needed for runtime scaling:
```cue
derived: {
    // For runtime calculation
    moment_of_inertia: _moment_inertia
    effective_mass: weight_kg // or derived for thrust
    
    // For UI / Reference
    reference_energy_j: ...
}
```

### 4.2. Add `#ArmourPiece` Schema
Create `data/armour.cue` to define the actual equipment:
```cue
#ArmourPiece: {
    name: string
    material: #Material // Reference to specific material
    coverage: { ... }
    layer: "plate" | "mail" | "padding"
}
```

## 5. Specific Questions / Challenges

### Re: Technique Axis Bias
*   **Observation:** `axis_bias` is optional in `data/techniques.cue`.
*   **Challenge:** I recommend making it **required** (even if default is 1.0). This forces the designer to explicitly consider how every technique converts energy. If `parry` has `rigidity_mult: 1.1`, does `block` have `rigidity_mult: 1.5`? Explicit defaults prevent "forgotten" techniques from feeling floaty.

### Re: `cue export` Performance
*   **Note:** As the dataset grows, `cue export` can be slow if schema constraints are complex. Keep an eye on build times. Pre-generating to `src/gen/` (checked in) is a good mitigation strategy mentioned in the plan—stick to that.

## 6. Conclusion
The data generation plan is sound. The CUE files are a solid start but need to shift focus from "calculating final damage" to "providing physics constants" so the Zig engine can handle the dynamic simulation.

**Recommendation:** Proceed with the plan, incorporating the "Inertia Export" refinement immediately.
