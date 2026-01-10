# T039: Severity Mapping & Volume Thresholds
Created: 2026-01-10

## Problem statement / value driver
`severityFromDamage` currently escalates to `Severity.missing` purely based on accumulated “amount” per layer. With the new axis model, high-geometry / low-energy attacks (e.g., needles) can deliver concentrated damage to a single tissue layer and incorrectly trigger “missing limb/part” behaviour—dropping weapons, severing capabilities, etc. The critical physics review (§2.3) calls this out as a major simulation failure. We need to distinguish between perforation (depth) and structural loss (volume) so severity outcomes reflect physical damage rather than just a numeric threshold.

### Scope – goals
- Define how volume/area loss should map to severity states (minor → missing) for different tissue types.
- Extend the wound model (and possibly materials data) to track both penetration depth and destroyed volume.
- Update `severityFromDamage` (or its replacement) to use the new criteria so piercing attacks can puncture deeply without flagging the part as “missing” unless sufficient structural material is removed.
- Adjust downstream systems (bleeding, trauma, capability loss) to consume the refined severity metrics.

### Scope – non-goals
- Rewriting the entire wound/condition framework (only change what’s needed to fix the severity mapping).
- Redesigning armour interactions beyond ensuring they produce sensible volume inputs.
- Implementing full volumetric modeling per voxel (we just need a plausible approximation per layer).

## Background
- `doc/artefacts/geometry_momentum_rigidity_review.md` §5 and §7 discuss layer behaviours and severity concerns.
- `doc/reviews/critical_physics_review.md` §2.3 documents the current failure mode and the need for volume-aware thresholds.
- `src/domain/body.zig` currently accumulates “layer damage” and passes it through `severityFromDamage`, which uses simple scalar thresholds.

## Changes Required
1. Design a volume-aware severity model: e.g., track “structural percentage lost” separately from “penetration depth,” or add a second metric to `LayerDamage`.
2. Extend layer/material data if needed (e.g., per-layer volume coefficients, structural vs. soft tissue weighting).
3. Update `applyDamage` and `severityFromDamage` to compute severity based on the new criteria (e.g., structural layers require high volume loss + muscle/tendon damage before marking “missing”).
4. Adjust severing checks, bleeding, and trauma calculations to align with the refined severity signals.
5. Document the new behaviour and add tests that cover both perforation and structural loss cases.

## Tasks / Sequence of Work
1. Draft the updated severity mapping in the design doc (how each axis contributes, volume thresholds per layer).
2. Update data schemas (`data/materials.cue`, `data/bodies.cue`) if additional parameters are needed.
3. Implement code changes in `body.zig` (and any other consumers) to use the new model.
4. Update unit tests (existing slash/pierce/bludgeon tests) to assert the correct severity classification.
5. Add regression tests for edge cases (needle → deep puncture but no missing limb, axe → missing limb).
6. Verify manually via combat logs or integration tests.

## Test / Verification Strategy
- Unit tests for `applyDamage` and `severityFromDamage` covering piercing vs. chopping scenarios.
- Integration test (or existing ones) to ensure capability loss (e.g., dropping a weapon) only occurs when the structural volume threshold is met.
- Manual verification via `event.log` or debug outputs for representative attacks.

## Risks / Open Questions
- Requires careful balancing so “missing” still occurs for plausible severing events; might need different thresholds per layer/part.
- Extra data might be needed (layer volumes, structural multipliers); ensure the CUE pipeline supports it without bloating authoring.
- Need to communicate the new behaviour to downstream systems (trauma, bleeding, UI) so they can reuse the improved severity signals.

## Design Decisions (2026-01-10)

### Dual Severity Model (Option A)
Separate severity curves for **volume** (energy-derived) and **depth** (geometry-derived):

- `severityFromVolume(energy_excess, is_structural)` – how much stuff is destroyed
- `severityFromDepth(geometry_excess)` – how deep the wound penetrates

Combination rules per layer:
- Soft tissue: max of volume and depth severity, capped at `.disabled`
- Structural tissue (bone, cartilage): volume curve drives severity; depth contributes but cannot alone reach `.missing`
- `.missing` requires: structural layer AND volume severity ≥ `.broken`

### Severing as Separate Check
Severing is NOT just `Severity.missing` on a structural layer. It's a dedicated check:
- Requires sufficient depth (geometry penetrated through) AND volume (structural material removed)
- Small parts (digits) have lower volume thresholds for severing
- Blunt trauma (high energy, low geometry) crushes but doesn't cleanly sever

### Schema Changes
Add `is_structural: bool` to `#Material` in `data/materials.cue`:
- `bone`, `cartilage` → structural
- `muscle`, `fat`, `skin`, `tendon`, `nerve`, `organ` → non-structural

### Test Scenarios
1. Needle (high geo, low energy) → deep puncture, max `.disabled`, no sever
2. Axe (moderate geo, high energy) → can sever if structural threshold met
3. Hammer (low geo, high energy) → `.broken` via crushing, no clean sever
4. Small part (digit) → lower volume threshold for `.missing`/sever

## Complication: Point vs Plane Geometries (Resolved)

Concern: Geometry as a scalar can't distinguish needle (point) from scimitar (cutting plane) - both penetrate well but have very different severing potential.

**Resolution:** `damage.Kind` already encodes this distinction. The existing `checkSevering` switches on kind:
- **Slash** (edge/plane): severs at `structural ≥ broken` + `soft tissue ≥ disabled`
- **Pierce** (point): severs only at `structural ≥ missing`
- **Bludgeon** (blunt): severs only at `structural ≥ missing`

No new fields needed. A scimitar slash and needle pierce may share similar geometry coefficients for penetration math, but their `damage.Kind` determines severing eligibility. The 3-axis model stays clean; severing logic uses kind as the implicit "contact shape" discriminator.

## Progress Log / Notes
- 2026-01-10: Card created per `doc/reviews/critical_physics_review.md` §2.3.
- 2026-01-10: Design decisions documented. Starting implementation.
- 2026-01-10: Implementation complete.
  - Added `is_structural: bool` to `#Material` in CUE schema (bone, cartilage = true)
  - Generator updated to pass `is_structural` through to Zig
  - `TissueLayerMaterial` extended with `is_structural` field
  - Implemented dual severity functions: `severityFromVolume()` and `severityFromDepth()`
  - `computeLayerSeverity()` combines volume and depth with structural/non-structural rules
  - Non-structural layers cap at `.disabled` regardless of damage
  - Structural layers use volume for `.missing` escalation; depth caps at `.broken`
  - `checkSevering()` updated with small-part threshold adjustment (area < 30 cm²)
  - Added 7 T039-specific tests covering needle/axe/hammer scenarios + soft tissue cap
  - All tests pass; `just check` clean

- Design complication added.
