# T037: Damage Packet Axis Export
Created: 2026-01-10

## Problem statement / value driver
Armour and (soon) tissue resolution operate on Geometry / Energy / Rigidity axes, but `damage.Packet` still carries only `amount` and `penetration`. `body.applyDamage` recreates fake axes from those scalars, so the entire CUE-derived weapon and technique physics data is ignored. To unlock the next stage of the three-axis model we must teach packet creation to emit the real axes (moment-of-inertia-driven energy, geometry/rigidity coefficients, technique axis bias) so downstream systems consume accurate inputs.

### Scope – goals
- Extend `damage.Packet` with Geometry/Energy/Rigidity (and any supporting metadata) and populate them in `createDamagePacket`.
- Derive the axes using generated weapon physics (moment_of_inertia, effective_mass, reference energy) plus technique `axis_bias`, attacker stats, grip, and stakes.
- Thread the new packet fields through combat resolution, armour, tissue, and logging without breaking existing features.
- Provide unit/integration coverage to keep the math honest, and update documentation/audit tooling to reflect the new fields.

### Scope – non-goals
- Retuning armour/tissue coefficients (handled by T033/T035).
- Reworking non-physical damage kinds beyond ensuring they bypass the physical axes.
- Finalising part-thickness usage inside tissue resolution (T035 Phase 4 handles that once real axes arrive).

## Background

### Relevant documents
- `doc/artefacts/geometry_momentum_rigidity_review.md` – conceptual spec for axes, mapping to weapons/techniques and defensive layers.
- `doc/artefacts/data_generation_plan.md` – schema details for weapon/technique data, including emitted physics constants.
- `doc/artefacts/data_audit_report.md` – current data health (warnings for missing technique axis_bias, tissue thickness sums).
- `doc/issues/impulse_penetration_bite.md`, `doc/issues/combat_modifiers_redesign.md` – upstream drivers.

### Key files
- `src/domain/resolution/damage.zig` – builds `damage.Packet`; needs axis derivation logic.
- `src/domain/damage.zig` – packet struct definition; must gain axis fields.
- `src/domain/armour.zig` – already consumes axes, ensure new packet fields arrive intact.
- `src/domain/body.zig` – Phase 4 will consume the axes; update signatures to accept them.
- `src/domain/audit_log.zig` – logs packets; extend to include axes.
- `scripts/cue_to_zig.py` & `src/gen/generated_data.zig` – emit the necessary weapon/technique physics constants.

### Existing systems, memories, research, design intent
- See Serena memories `combat_resolution_overview`, `weapons_system_overview`, `armour_equipment_overview`, `body_system_overview`.
- CUE generator already computes moment_of_inertia, effective mass, reference energy, geometry/rigidity defaults, and technique `axis_bias`; `doc/artefacts/data_audit_report.md` verifies their presence.
- Armour stack (T033) and tissue stack (T035) follow the three-axis design; they currently fake values because packets don’t supply them.

## Changes Required
1. **Schema & data exposure**
   - Ensure generated weapon/technique structs expose the necessary physics (MoI, effective mass, reference energy, default geometry/rigidity coefficients, axis bias). Add validation in `scripts/cue_to_zig.py` if any field is absent.
2. **Packet struct expansion**
   - Update `src/domain/damage.zig` to add `geometry`, `energy`, `rigidity`, and optional `reference_energy` fields. Keep or deprecate `amount`/`penetration` with clear comments.
3. **Axis derivation logic**
   - Implement helpers in `resolution/damage.zig` for swing vs. thrust: `energy = 0.5 * moment_of_inertia * angular_speed^2` or `0.5 * effective_mass * linear_speed^2`, where angular/linear speed derives from attacker stats and stakes. Apply technique axis multipliers to allocate energy across axes.
   - Compute penetration/geometry relationships (e.g., geometry coefficient × blade length) per design doc.
4. **Pipeline wiring**
   - Populate the new packet fields in `createDamagePacket`.
   - Update armour/tissue/audit logging to read the new fields instead of deriving placeholders.
5. **Diagnostics**
   - Extend `audit_log` (and eventually the planned `combat_packet_resolved` event) to capture axes for debugging.
6. **Documentation**
   - Update the review doc’s status checklist (tick “Damage-packet axis export” when complete) and capture the chosen formulas/assumptions.

### Challenges / Tradeoffs / Open Questions
- **Stats → velocity mapping:** How do we convert attacker stats to angular/linear speed? Need an initial formula and calibration notes.
- **Technique defaults:** Many techniques currently rely on implicit axis bias; deciding whether to fail hard or allow defaults matters for data authoring.
- **Penetration vs. geometry:** Do we keep the existing `penetration` scalar for backwards compatibility or derive it directly from geometry? The tissue rewrite expects geometry + path length; armour currently uses penetration.
- **Non-physical damage:** Decide whether to zero out axes or leave packets partially populated when `damage.Kind` is not physical.

### Decisions
1. **Stats → energy mapping:** Use reference-energy scaling for now. `actual_energy = reference_energy_j × scalingMultiplier(stat_value, ratio) × stakes.damageMultiplier()`. Full kinematic derivation (computing ω/v from stats) deferred as future calibration work.
2. **Physics data plumbing:** Add physics fields (`moment_of_inertia`, `effective_mass`, `reference_energy_j`, `geometry_coeff`, `rigidity_coeff`) to `weapon.Template`. Populate from generated data in `weapon_list.zig`. Matches armour pattern.
3. **Technique axis bias defaults:** Allow 1.0/1.0/1.0 defaults. Weapon coefficients already differentiate swing vs thrust; technique bias refines later without blocking progress.
4. **Penetration vs geometry:** Keep both. Add `geometry`/`energy`/`rigidity` as new fields; retain `amount`/`penetration` for backward compatibility. Derive `penetration = geometry × reference_path_length` once downstream consumers migrate.
5. **Non-physical damage:** Zero out axes when `kind.isPhysical() == false`. Downstream guards short-circuit the 3-axis logic on that condition.

### Implications
- Once packets supply real axes, armour/tissue behaviours reflect data changes immediately; placeholder logic can be removed.
- Packet logging/auditing gains meaningful values for validation and balancing.
- Future systems (e.g., weapon durability, conditions) can hook onto axes rather than ad-hoc damage multipliers.

## Tasks / Sequence of Work
1. **Audit data readiness**
   - Re-run `just audit-data` and ensure no weapon/technique physics fields are missing.
   - Update CUE definitions if necessary (e.g., fill in technique axis_bias).
2. **Expose physics constants**
   - Adjust `scripts/cue_to_zig.py` to emit any missing weapon/technique fields, plus comptime validation for axis_bias presence.
3. **Expand `damage.Packet`**
   - Add axis fields and helper methods; update serialization/logging as needed.
4. **Implement axis derivation**
   - Add helper functions in `resolution/damage.zig` for swing/thrust energy and geometry/rigidity allocation.
   - Modify `createDamagePacket` to compute and set the new fields (and keep legacy fields in sync).
5. **Plumb through consumers**
   - Ensure armour/tissue receive the new packet shape (even if tissue still uses placeholders initially).
   - Update `audit_log` and any tests referencing packet fields.
6. **Testing & verification**
   - Add unit tests for the new helper functions and extend existing packet tests to assert axis behaviours.
   - Add/extend integration tests (e.g., `testing/integration/domain/weapon_resolution.zig`) to compare axes for different techniques/weapons.
7. **Docs & status updates**
   - Document formulas/assumptions in the design doc and mark the checklist item as complete.
   - Note any follow-on work (e.g., tissue resolution updates) in the relevant kanban cards.

## Test / Verification Strategy

### Success criteria / ACs
- Packets generated via `createDamagePacket` contain non-zero Geometry/Energy/Rigidity that vary with weapon, technique, stats, and stakes.
- Armour resolution produces identical results before/after field addition (modulo expected differences from real axes once tissue consumes them).
- `just audit-data` reports no missing physics fields for weapons/techniques.
- `event.log` (or future packet events) shows the new axes for manual inspection.

### Unit tests
- New tests for swing/thrust energy helpers (given moment_of_inertia/effective_mass + stat inputs).
- Extend `createDamagePacket` stake-scaling test to assert axis scaling as well as amount.

### Integration tests
- Update or add a combat resolution test verifying that swing vs. thrust on the same weapon produce expected axis splits (e.g., higher geometry for thrust).
- Optional: add a regression test ensuring non-physical damage kinds keep axes at zero.

### User acceptance
- Run `just check` (includes `just generate` and tests).
- Manual smoke: start a combat, capture `event.log`, verify packets show plausible axes.

## Quality Concerns / Risks / Potential Future Improvements
- Axis formulas likely need balancing after tissue resolution consumes them; document calibration knobs.
- Natural weapons and exotic techniques may need bespoke overrides; ensure the design leaves room for per-weapon/per-technique adjustments.
- Consider generating a developer report (e.g., `just audit-data --packets`) summarising axis outputs for each offensive profile to aid balancing.

## Progress Log / Notes
- 2026-01-10: Card scaffolded with context from design review (§4-§6) and data audit. Downstream dependants: T035 Phase 4 (tissue resolution polish). Upstream prerequisites satisfied (armour + body data).- 2026-01-10: Design decisions finalised (see Decisions section). Key choices: reference-energy scaling (not full kinematics), physics on Template, allow technique defaults, keep amount/penetration for compat, zero axes for non-physical.
- 2026-01-10: **Implementation complete.** Changes:
  - `weapon.Template`: added `moment_of_inertia`, `effective_mass`, `reference_energy_j`, `geometry_coeff`, `rigidity_coeff`
  - `weapon_list.zig`: all 9 weapons now have physics values (calculated from weight/length/balance)
  - `damage.Packet`: added `geometry`, `energy`, `rigidity` fields with default 0
  - `resolution/damage.zig`: added `deriveEnergy`, `deriveGeometry`, `deriveRigidity` helpers; `createDamagePacket` populates new fields
  - `cards.Technique`: added `axis_geometry_mult`, `axis_energy_mult`, `axis_rigidity_mult` (default 1.0)
  - `armour.zig`: both resolve functions now use packet axes with legacy fallback
  - `body.zig`: `applyDamage` uses packet axes with legacy fallback
  - `events.zig`: `combat_packet_resolved` extended with axis fields
  - `audit_log.zig`: log format now includes axes
  - Tests: 2 new unit tests for axis derivation; all 296 tests pass
