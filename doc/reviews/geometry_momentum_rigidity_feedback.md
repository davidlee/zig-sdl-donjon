# Review: Geometry / Energy / Rigidity Proposal

**Target Artefact:** `doc/artefacts/geometry_momentum_rigidity_review.md`  
**Reviewer:** Gemini CLI  
**Date:** 2026-01-09

## 1. Validation of Present State
I have audited the referenced source files (`src/domain/resolution/damage.zig`, `src/domain/armour.zig`, `src/domain/body.zig`, `src/domain/weapon.zig`) and confirm the "Present-State Snapshot" is **highly accurate**.

*   **Damage Packet:** `src/domain/resolution/damage.zig` indeed collapses all weapon properties into `amount` (scalar) and `penetration` (scalar). Weapon reach/weight are currently only used for UI/Stamina or hit chance, not impact calculus.
*   **Armour Resolution:** `src/domain/armour.zig` uses specific scalars (`hardness`, `thickness`) and a loop that mixes probabilistic checks (hardness deflection) with deterministic reduction (resistance thresholds). The lack of orthogonal axes is confirmed.
*   **Tissue Layers:** `src/domain/body.zig` uses `layerResistance` to return hardcoded `absorb`/`pen_cost` values based on `damage.Kind`. This effectively duplicates the armour logic but with a different schema, confirming the redundancy the proposal seeks to eliminate.
*   **Dimensions:** `src/domain/species.zig` and `body.zig` lack explicit physical dimensions (length/circumference) for body parts, verifying the gap identified in "Body/species scaling".

## 2. Feasibility Assessment
The proposed model is **ambitious but feasible**, provided the scope is strictly managed.

*   **Unified Material Model:** Merging `armour.Material` and `body.TissueLayer` logic is the strongest architectural win here. It simplifies the resolution pipeline into a single "layer iterator" that doesn't care if it's hitting steel or bone.
*   **Derivation vs. Authoring:** The plan to *derive* Energy/Geometry from `weapon.Template` (mass, balance, features) is crucial. If designers had to manually author 3 new stats for every weapon, the content burden would be too high. The "physics-first" derivation (`½ Iω²`) is realistic for a game of this detail level.
*   **Performance:** Zig is well-suited for the added math. Replacing switch-statements with coefficient multiplications may actually improve instruction locality, though the increase in per-layer state (3 axes vs 2 scalars) is negligible for modern hardware.

## 3. Gap Analysis
The following areas are missing or underdeveloped in the proposal:

### 3.1. AI Heuristics & Valuation
The proposal focuses on *resolution*, but not *decision making*.
*   **Problem:** Currently, an AI likely picks the technique with the highest `amount`. In the new model, "highest Energy" might be useless against a high-Deflection enemy (who needs High Geometry), or a high-Dispersion enemy (who needs High Rigidity).
*   **Missing:** The roadmap needs a task to update `src/domain/ai.zig` (or equivalent evaluation logic) to understand these new axes. The AI needs a heuristic to "read" the opponent's defensive profile (e.g., "They are wearing Plate -> I need Geometry").

### 3.2. Feedback & "Whiff" Factors
The proposal outlines internal axes but glosses over how the player understands failure.
*   **Distinct Failure Modes:** We need specific UI feedback for *why* an attack failed:
    1.  **Glance (Geometry Fail):** The blade slid off (Deflection > Geometry). Sound: *Skitter/Screech*.
    2.  **Bounce (Energy Fail):** The blow landed square but lacked force to deform the layer (Absorption > Energy). Sound: *Clang/Thud*.
    3.  **Shatter (Rigidity Fail):** The weapon/projectile broke or deformed upon impact. Sound: *Crack/Crunch*.
*   **Recommendation:** The `AbsorptionResult` struct needs to return an enum distinguishing these failure states, not just `amount: 0`.

### 3.3. Determinism vs. Stochasticity
*   **Ambiguity:** The current armour system uses RNG for deflection (`rng.float(f32) < hardness`). The new proposal talks about "coefficients".
*   **Question:** Is the new system purely deterministic (Energy 10 vs Absorption 11 = 0 Damage)? Or is there a variance roll? Pure determinism can feel "stat-checky" and flat; pure RNG feels chaotic.
*   **Suggestion:** Clarify if `Deflection` is a threshold (deterministic) or a probability curve.

## 4. Refinements to Roadmap

### 4.1. Add "Math Prototype" Step
Before writing Zig code, create a standalone script (Python/Excel) to model the equations.
*   **Why:** Tuning `½ Iω²` to result in game-appropriate integers (0-20 range?) is hard. You don't want to recompile the game to tune the "Momentum Constant".
*   **Action:** Add a step between **Data Audit** and **Axis Specification** to "Prototype Derivation Formulas".

### 4.2. Schema-First Data Migration
*   **Action:** Update `scripts/cue_to_zig.py` (or the relevant data pipeline) early. Defining the schemas in `.cue` (or the data source) helps visualise the complexity before the engine logic exists.

## 5. Specific Challenges (Devil's Advocate)

### Re: 7.1 Axis Independence (Geometry vs Rigidity)
*   **Challenge:** The proposal argues they are independent. I argue they are coupled at the extremes.
*   **Reasoning:** A material cannot have high Geometry (fine edge) without minimal Rigidity (to hold the edge). Conversely, a "soft" weapon (low Rigidity) creates a larger contact area upon impact, inherently lowering Geometry.
*   **Mitigation:** This doesn't invalidate the model, but the *derivation formulas* must respect this coupling. You cannot define a weapon with "Max Geometry, Min Rigidity" without it breaking immediately.

### Re: 7.6 Non-Physical Spillover
*   **Challenge:** "Opt-in" is dangerous for code complexity.
*   **Refinement:** Instead of opt-in, define **Standard Conversion Defaults**.
    *   Fire/Cold/Acid: Geometry = 0 (Fluids don't pierce), Rigidity = 0 (Fluids don't shatter), Energy = Heat/Chemical Potential.
    *   This allows the same resolution pipeline to handle a fireball (High Energy, 0 Geo) vs a Sword (Mix) without `if (is_physical)` branches everywhere.

## 6. Conclusion
The proposal is **approved for the next phase (Data Audit)**. The conceptual foundation is sound and aligns with the project's simulationist goals. The identified gaps (AI, Feedback) can be addressed in parallel with the data work.
