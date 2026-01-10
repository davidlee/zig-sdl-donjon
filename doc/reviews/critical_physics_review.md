# Critical Review: Geometry/Energy/Rigidity Implementation

**Reviewer:** Gemini CLI  
**Date:** 2026-01-10  
**Status:** **CRITICAL RISKS IDENTIFIED**

## 1. Executive Summary
While the architecture (CUE -> Zig) is sound and the topological ordering issue is resolved, a **critical unit mismatch** in the physics math renders the new data-driven weapons effectively harmless against armor. The logic conflates a dimensionless "Sharpness Coefficient" with a "Penetration Depth" magnitude, causing attacks to fail depth checks they should pass.

## 2. Critical Findings

### 2.1. The "Needle vs. Wall" Unit Error
*   **The Bug:** In `src/domain/armour.zig`, the code treats `damage.geometry` (a 0.0-1.0 coefficient) as interchangeable with `damage.penetration` (a dimensioned length in cm).
*   **Evidence:**
    *   `armour.zig:338`: `const geometry = if (remaining.geometry > 0) remaining.geometry else remaining.penetration;`
    *   `armour.zig:360`: `remaining.geometry = geometry * (1.0 - deflection_coeff) - mat.thickness;`
*   **Impact:**
    *   A `knights_sword` has `geometry_coeff = 0.6` (from CUE).
    *   Legacy `penetration` was `4.0` cm.
    *   Plate armor has `thickness = 1.0` cm.
    *   **New Math:** `0.6 - 1.0 = -0.4`. Attack stops.
    *   **Old Math:** `4.0 - 1.0 = 3.0`. Attack penetrates.
*   **Consequence:** Converting to the new system nerfs all weapons by ~85%, making them unable to penetrate even basic armor.
*   **Fix:** `geometry` (Sharpness) and `penetration` (Momentum/Energy derived depth capability) must be distinct. `Sharpness` should reduce the *effective thickness* or *deflection chance* of the armor, not *be* the depth budget.

### 2.2. Energy Scaling linearity
*   **Observation:** `deriveEnergy` scales linearly with stat ratios (`1.0 + ratio`).
*   **Physics:** Kinetic energy scales linearly with mass ($m$) but quadratically with velocity ($v^2$).
*   **Risk:** Fast characters will be significantly underpowered compared to Strong characters for the same stat investment, breaking the "Speed vs Power" balance intended by the design.
*   **Recommendation:** Change the scaling formula for speed-based weapons to use a quadratic multiplier.

### 2.3. Severity Mapping "Missing" Functionality
*   **Observation:** `severityFromDamage` maps high values (e.g., >8.0) directly to `Severity.missing`.
*   **Scenario:** A "Needle" attack (High Geometry, Low Energy) concentrates all its force.
*   **Result:** It generates a high `amount` of effective damage on the specific tissue layer. The system marks the tissue as `missing` (amputated/vaporized).
*   **Risk:** A needle to the arm causing "Missing Arm" logic (dropping weapons) is a simulation failure.
*   **Fix:** Distinguish `Structural Integrity Loss` (Blunt/Chop) from `Perforation` (Pierce). `Severity.missing` should require a threshold of *volume* destroyed, not just *depth* penetrated.

## 3. Test Coverage Gaps
*   **Missing Integration Test:** There are NO tests that pit a **Generated Weapon** against **Generated Armour**.
    *   Existing tests use `TestMaterials` and `TestBody`.
    *   `weapon_list.zig` is manually curated, masquerading as generated data.
*   **Brittleness:** The tests in `armour.zig` verify the *algorithm*, but not the *data*. Since the critical error (2.1) is a data-unit mismatch, the current test suite passes green while the game is broken.

## 4. Mitigation Plan

1.  **Immediate Fix (Physics Math):**
    *   Refactor `damage.Packet` to carry `sharpness` (geometry coeff) AND `penetration_potential` (cm).
    *   Update `armour.zig`: `effective_thickness = mat.thickness * (1.0 - sharpness)`.
    *   Check: `penetration_potential > effective_thickness`.
2.  **Calibration Script:**
    *   Write a Python script that runs the `armour.zig` logic against the CUE data to output a "Penetration Matrix" (Sword vs Plate, Dagger vs Mail).
    *   Fail the build if `Sword vs Plate` > 0 damage (shouldn't penetrate) or `Pick vs Plate` == 0 (should penetrate).
3.  **Quadratic Scaling:**
    *   Update `stats.zig` to support `scalingMultiplierQuadratic`.
