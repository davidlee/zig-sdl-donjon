# Review: Geometry / Energy / Rigidity Implementation

**Target Artefact:** `doc/artefacts/geometry_momentum_rigidity_review.md` (and linked source files)  
**Reviewer:** Gemini CLI  
**Date:** 2026-01-10

## 1. Executive Summary
The implementation state is **highly coherent** and strictly aligned with the design specifications. The "Completed Work" section in the review document accurately reflects the codebase. The transition from design to implementation has been executed with discipline, particularly in the data generation pipeline (`cue_to_zig.py`), which successfully acts as the bridge between the CUE schemas and Zig runtime.

## 2. Validation of Claims

### 2.1. Armour Integration (T033) - **Verified**
*   `src/domain/armour.zig` correctly implements the 3-axis logic (`deflection`, `absorption`, `dispersion`) and the `ShapeProfile` modifiers.
*   The resolution loop properly handles layer-by-layer reduction.
*   **Observation:** The unit tests in `armour.zig` use local `TestMaterials` constants. This is correct for logic verification, but it means the *generated* materials are currently only validated by the audit script, not by runtime combat tests.

### 2.2. Data-Driven Bodies (T035) - **Verified**
*   `src/domain/body.zig` has successfully migrated to use `body_list` and generated plans.
*   `Body.fromPlan` is the primary entry point, decoupling body composition from hardcoded Zig structs.
*   **Pending:** The `TODO` regarding `thickness_ratio * part_geometry.thickness_cm` is clearly marked in `applyDamage`, confirming the "Phase 4 polish" status.

### 2.3. Damage Packet Axes (T037) - **Verified**
*   `src/domain/resolution/damage.zig` exports the 3 axes.
*   Derivation logic (`deriveEnergy`, etc.) matches the "Reference Energy" model decided in T037.
*   Tests confirm proper scaling by stakes and stats.

### 2.4. Audit Tooling - **Verified**
*   `scripts/cue_to_zig.py` is a robust piece of infrastructure. The addition of `AuditReport` with cross-reference validation (`armour_pieces` -> `materials`) is a high-value safety net.

## 3. Observations & Recommendations

### 3.1. Code Duplication: `deriveRigidityFromKind`
*   **Observation:** Both `src/domain/armour.zig` and `src/domain/body.zig` contain identical `deriveRigidityFromKind` functions for legacy fallback.
*   **Risk:** Low, but if we tune these magic numbers, we might miss one.
*   **Recommendation:** Move this helper to `src/domain/damage.zig` (or a shared utility) as `damage.defaultRigidityFor(kind)`.

### 3.2. Phase 4: Path Length & Thickness
*   **Context:** `src/domain/body.zig` currently ignores `geometry` (thickness) in `applyDamage`.
*   **Impact:** A dagger (low geometry consumption) currently penetrates a "thick" torso layer just as easily as a "thin" finger layer, provided it passes the threshold.
*   **Action:** prioritizing the `TODO` in `body.zig:904` is critical for distinguishing deep vs. shallow wounds in the new model.

### 3.3. Testing Strategy for Generated Data
*   **Gap:** We validate the *schema* of generated data (via audit), and the *logic* of resolution (via unit tests with mocks), but we lack an end-to-end test that asserts "A Knight's Sword swing vs Plate Cuirass results in X".
*   **Recommendation:** As part of "Pilot Implementation Plan", create an integration test (`src/integration_tests.zig` or similar) that uses **only** generated IDs (`"knights_sword"`, `"steel_plate"`) to verify the data values produce sensible outcomes in the engine.

## 4. Conclusion
The "State of Play" is excellent. The architecture supports the complexity well.
**Immediate Priority:** Complete T035 Phase 4 (Tissue Resolution Polish) to fully enable the "Geometry vs Thickness" mechanic, which is the final piece of the core physics puzzle.
