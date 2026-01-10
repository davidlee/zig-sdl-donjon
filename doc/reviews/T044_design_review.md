# Review: CUE Weapon Unification Design

**Target Design:** `doc/designs/T044_cue_weapon_unification.md`  
**Reviewer:** Gemini CLI  
**Date:** 2026-01-10

## 1. Design Validity
The design is **sound** and strictly aligned with the architectural direction established in `geometry_momentum_rigidity_review.md`. It resolves the "split brain" data problem.

*   **Pattern Match:** The loader pattern (`weapon_list.zig` as a registry for `GeneratedWeapons`) perfectly mirrors the successful `armour_list.zig` implementation.
*   **Comptime Safety:** Using `getTemplate(comptime id)` with `@compileError` ensures no regressions for static references.

## 2. Refinements & Recommendations

### 2.1. Handling `Ranged` (Deferred vs Stubbed)
*   **Design Doc:** "Ranged (optional, defer to later)"
*   **Risk:** `weapon.Template` *has* a `ranged` field. If we leave it null in the generated struct, `shortbow` (which relies on `ranged.projectile`) will break.
*   **Recommendation:** Do not defer `ranged`. Stub it in the schema now, even if basic. `shortbow` needs it to function in existing tests (Agent `Snik`).
    *   Add `#RangedProfile` to CUE immediately to support `projectile` (bows) and `thrown` (rocks).

### 2.2. Category Mapping
*   **Schema:** `#Category: "sword" | ...`
*   **Zig:** `weapon.Category` is an enum.
*   **Note:** Ensure `cue_to_zig.py` correctly emits `weapon.Category.sword` (enum literal), not string literals, for the `categories` array.

### 2.3. Default Values
*   **Observation:** The schema uses strict typing.
*   **Refinement:** Use CUE defaults aggressively (`| *false`) for booleans (done in draft). Consider defaults for `fragility` (1.0) to reduce boilerplate.

## 3. Approval
The plan is approved for implementation with the **mandatory inclusion of Ranged support** to avoid breaking `shortbow`.

**Action:** Proceed with T043, ensuring `data/weapons.cue` includes `ranged` schema sufficient to cover `shortbow` and `fist_stone`.
