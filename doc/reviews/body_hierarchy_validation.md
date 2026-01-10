# Review: Body Hierarchy & Implementation Validity

**Target:** `data/bodies.cue`, `scripts/cue_to_zig.py`, `src/domain/body_list.zig`, `src/domain/body.zig`  
**Reviewer:** Gemini CLI  
**Date:** 2026-01-10

## 1. Validation of "Bag of Parts" Fix
I probed the specific concern about the "bag of parts" oversight.
*   **Data Source (`data/bodies.cue`):** The schema explicitly includes `parent: string` and `enclosing: string`. The `humanoid` plan uses these to define a single-root tree (Root: `torso`).
*   **Build Pipeline (`cue_to_zig.py`):** The `topological_sort_parts` function is present and correct. It guarantees that parents are emitted before children in the `GeneratedBodyPlans` array.
*   **Runtime Reconstruction (`body_list.zig`):** The `buildPartDef` function runs at **comptime**. It resolves the string names (e.g., "torso") to `PartId` hashes and, crucially, validates that the parent exists within the same plan using `findPartIndexInPlan`.
*   **Verdict:** The system is **not** a bag of parts. It is a validated, topologically stable hierarchy.

## 2. Deep Dive Findings & Risks

### 2.1. Latent Fragility: Topological Assumption
*   **Risk:** `Body.computeEffectiveIntegrities` iterates the parts array linearly (`0..len`) and looks up `parent_idx`. It **implicitly assumes** `parent_idx < current_index`.
*   **Scenario:** If `Body.fromParts` is ever called with an unsorted slice (e.g., a manually constructed test fixture that defies gravity), damage propagation will read uninitialized/stale integrity values for the parent.
*   **Mitigation:** Add a `std.debug.assert(parent_idx < i)` inside the loop in `computeEffectiveIntegrities`, or validate the sort order in `Body.fromParts`.

### 2.2. Root Count Enforcement
*   **Observation:** The current pipeline permits multiple disjoint trees (multiple roots) if the CUE data defines them. While `humanoid` has one root, nothing prevents a `hydra` plan from having `head1` (root), `head2` (root), `body` (root).
*   **Impact:** This might actually be desirable for some creatures (swarm constructs?), but it's worth noting as a design allowance rather than a constraint.

### 2.3. String-based ID Fragility
*   **Observation:** The CUE IDs (`"torso"`) become the runtime `PartId` hashes.
*   **Risk:** Renaming a part in CUE invalidates existing saves (expected) and potentially breaks code that does `body.indexOf("torso")` if the name changes to `chest`.
*   **Status:** Acceptable for this stage, but "Magic String" hygiene is required in the `.cue` files.

## 3. Conclusion
The hierarchy implementation is robust. The "bag of parts" issue is fully resolved by the CUE->Python->Zig pipeline. The only significant finding is the **Topological Assumption** in the Zig runtime, which should be guarded against.

**Action:**
1.  Add `std.debug.assert` in `body.zig` to enforce topological order during integrity updates.
