# Review: Non-Humanoid Support Risks

**Target:** Support for non-humanoid physiologies (amoeboids, ungulates, winged/multi-limbed).
**Reviewer:** Gemini CLI
**Date:** 2026-01-10

## 1. Topological Support: Excellent
The underlying `Body` system (`parent`/`enclosing` hierarchy) is fully capable of representing arbitrary topologies.
*   **Success:** A Centaur can be modeled as `Torso -> [Humanoid Upper] + [Horse Lower]`. An Amoeba can be `Nucleus -> Pseudopod`.
*   **Bag of Parts Fix:** The recent fix ensuring topological sort order in `cue_to_zig.py` ensures these complex hierarchies load correctly without "gravity" bugs.

## 2. Critical Bottleneck: `PartTag` Enum
**Risk Level: High**
*   **The Issue:** `src/domain/body.zig` defines `PartTag` as a fixed, hand-authored enum focused on humanoid anatomy (`arm`, `leg`, `lung`, `spleen`).
*   **The Constraint:** To define an Imp with a wing, you must add `tag: "wing"` in CUE. The generator will emit `.tag = body.PartTag.wing`. This will **fail to compile** because `wing` is not in the Zig enum.
*   **Impact:** Adding any new physiology requires modifying core engine code (`body.zig`). This defeats the purpose of data-driven definitions.

## 3. Weapon Handling (Armament)
**Risk Level: Medium**
*   **Current State:** `Armament` supports `unarmed`, `single`, `dual`. It has a `compound` variant (slice of slices) for multi-limbed creatures (Marilith), but the logic for it is currently `TODO` / `null`.
*   **Verdict:** Sufficient for "winged or four-legged" mobs (who likely use 0-2 held weapons). Insufficient for "four-armed" mobs *if* they need to wield 4 swords. Natural weapons (claws/bites) bypass this and work fine regardless of limb count.

## 4. Recommendations

### 4.1. Data-Driven Tags (Priority Fix)
Instead of hand-coding `PartTag` in `body.zig`, we should **generate the enum** from the CUE data.
*   **Plan:**
    1.  Create `data/taxonomy.cue` (or similar) to list valid Body Part Tags.
    2.  Update `cue_to_zig.py` to generate `pub const PartTag = enum { ... };` in a new file `src/domain/gen/tags.zig`.
    3.  Import this generated enum in `body.zig`.
*   **Benefit:** Adding "pseudopod" or "wing" becomes a pure data change.

### 4.2. Generalized "Limb" Logic
*   **Observation:** `humanoid_exposures` in `body.zig` hardcodes probabilities for `arm`, `leg`, `head`.
*   **Risk:** An Amoeba has no `head`. The default hit-location logic needs to handle bodies that lack standard tags.
*   **Mitigation:** Ensure the "Target Selection" logic (UI and AI) doesn't crash if `body.get("head")` returns null. The current `Body.hasFunctionalPart` is a good pattern, but hit distribution tables need to be data-driven (part of the Body Plan) rather than static code.

## 5. Conclusion
The architecture allows non-humanoids, but the **Tags** and **Hit Distribution** are currently hard-coupled to humanoids. Generating the `PartTag` enum is the necessary next step to unlock true data-driven physiology.
