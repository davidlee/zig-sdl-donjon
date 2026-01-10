# T038: Quadratic Energy Scaling & Velocity Modelling
Created: 2026-01-10

## Problem statement / value driver
`damage.Packet.energy` currently scales linearly with attacker stats and stakes (`energy = reference_energy_j * (1 + ratio)`). The design document and the critical physics review both call out that kinetic energy should grow quadratically with velocity (`½ m v²`). Failing to implement the non-linear relationship leaves “speed builds” underpowered and breaks the intended power/speed trade-off. We need to revisit the energy derivation so high velocity contributes disproportionately (as it does in physics) while mass/rigidity/geometry continue to interact cleanly with armour and tissue.

### Scope – goals
- Design and implement an energy scaling function that respects the quadratic velocity relationship (e.g., `energy = reference_energy_j * velocity_scale² * mass_scale`) while remaining compatible with the generated data (moment_of_inertia, effective mass, reference energy).
- Expose any new tuning coefficients in data or configuration so stats/grips/techniques can control the scaling explicitly.
- Update packet generation, logging, and tests to reflect the new behaviour.

### Scope – non-goals
- Redesigning stat definitions or introducing new stats.
- Retuning armour/tissue thresholds beyond what’s necessary to keep the test suite coherent.
- Replacing the existing reference energy derivation (moment_of_inertia × reference angular velocity); we’re refining its scaling, not redoing the base physics.

## Background
- `doc/artefacts/geometry_momentum_rigidity_review.md` §4–§6 describe the intended mapping from weapon data + stats to axes.
- `doc/reviews/critical_physics_review.md` §2.2 calls out the linear scaling flaw and recommends quadratic behaviour for speed contributions.
- `src/domain/resolution/damage.zig` currently implements `deriveEnergy` with a linear multiplier; we need to adjust it and keep downstream consumers compatible.

## Changes Required
1. Confirm the desired stat inputs (e.g., `power`, `speed`, `control`) for swing vs. thrust techniques and document the formulas.
2. Update `deriveEnergy` (and any helper) to compute angular/linear velocity from stats using a quadratic relationship (or an equivalent scaling function). Consider separate curves for swing, thrust, throw, and natural weapons.
3. Adjust packet logging/tests to assert the new scaling (e.g., doubling speed → energy ×4).
4. Expose configuration knobs if needed (e.g., per-technique velocity baseline) via the data pipeline.
5. Document the change in the design doc and add risks/validation steps as required.

## Tasks / Sequence of Work
1. Audit existing formulas in `resolution/damage.zig`; capture current behaviour in doc and tests.
2. Prototype new scaling formulas (e.g., `velocity_scale = 1 + (stat_ratio * weight)`, `energy = reference_energy_j * velocity_scale²`).
3. Update code and tests; run `just check`.
4. Validate against a few sample packets (log outputs) to ensure energy differences match expectations.
5. Update documentation/status checklist with the new scaling model and any follow-on research needs.

## Test / Verification Strategy
- Unit tests in `resolution/damage.zig` verifying that energy grows quadratically with stat deltas (e.g., +10% stat → +21% energy if squared).
- Integration test (or existing weapon-resolution test) verifying that a faster attacker produces noticeably higher wounds than a slower one, holding everything else constant.
- Manual log inspection (e.g., `event.log`) to ensure energy outputs are plausible across a range of techniques/weapons.

## Risks / Open Questions
- Need to avoid runaway numbers; may require capping or scaling functions to keep high stats within reasonable ranges.
- Might need to differentiate between “speed” stats (quadratic) and “power” stats (linear) to avoid double-dipping.
- Ensure migration path for existing saves/tests that relied on the linear relationship.

## Progress Log / Notes
- 2026-01-10: Card created in response to `doc/reviews/critical_physics_review.md` §2.2.
