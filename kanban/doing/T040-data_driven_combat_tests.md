# T040: Data-Driven Combat Tests
Created: 2026-01-10

## Problem statement / value driver
Validating the complex 3-axis damage model via unit tests is brittle. We need a declarative way to assert combat outcomes (e.g., "sword vs plate = glance"). This framework acts as the **Verification Suite** for the recently implemented physics fixes (separation of Geometry/Penetration, quadratic Energy scaling).

### Scope - goals
- Implement CUE schema `#CombatTest`.
- Generate Zig test data.
- Extend `Harness` with `forceResolveAttack`.
- Implement test runner.
- **Verify Fixes:** Confirm that "Sword vs Plate" now correctly results in a glance/bounce (instead of incorrect penetration or zero damage due to unit errors).

## Background
- `doc/designs/data_driven_combat_tests.md`
- `doc/reviews/critical_physics_review.md` (The bugs this suite ensures remain fixed)
- `doc/artefacts/geometry_momentum_rigidity_review.md` (CUE-first data authoring baseline)

## Completed Work (2026-01-10)

### 1. CUE Schema (`data/tests.cue`)
- `#CombatTest`, `#AttackerSpec`, `#DefenderSpec`, `#ExpectedOutcome` schemas
- 4 initial test cases: `sword_slash_vs_plate`, `sword_thrust_vs_plate`, `fist_vs_unarmoured`, `sword_vs_gambeson`

### 2. Generator (`scripts/cue_to_zig.py`)
- `flatten_combat_tests()` extracts tests from CUE
- `emit_combat_tests()` generates `AttackerSpec`, `DefenderSpec`, `ExpectedOutcome`, `CombatTestDefinition` structs
- `GeneratedCombatTests` array emitted to `src/gen/generated_data.zig`
- `Justfile` updated to include `data/tests.cue` in generate/audit commands

### 3. Harness Extensions (`src/testing/integration/harness.zig`)
- `ForceResolveResult` struct: outcome, damage_dealt, armour_deflected, layers_penetrated
- `forceResolveAttack()`: builds AttackContext/DefenseContext, calls `resolveTechniqueVsDefense` directly
- Helper functions: `findTechniqueByName()`, `parseStakes()`
- Runtime body part lookup via hash

### 4. Test Runner (`src/testing/integration/domain/data_driven_combat.zig`)
- Iterates `GeneratedCombatTests`, sets up harness per test
- Weapon lookup via `lookupWeaponById()` mapping table
- Assertions on `damage_dealt_min`, `damage_dealt_max`, `armour_deflected`
- Wired into `mod.zig`, all tests pass

## Limitations & Known Issues

### Critical: Armour Not Wired
`equipArmourById()` is a stub - tests specifying `armour_ids` don't actually equip armour. The "sword vs plate = glance" verification **is not happening**. Tests pass but with wide damage tolerances (0-6) that don't validate physics.

### Non-Deterministic Results
Combat resolution uses RNG for hit/miss. Tests account for this with permissive ranges (`damage_dealt_min: 0`), weakening assertions. Need deterministic mode.

### Incomplete Weapon Mapping
`lookupWeaponById()` only maps 4 CUE weapon IDs to `weapon_list.zig` templates:
- `swords.knights_sword` → `weapon_list.knights_sword`
- `natural.fist` → `weapon_list.fist_stone`
Other IDs silently skip tests.

### Damage Metric is Coarse
Returns `worstSeverity()` (0-5 enum) instead of actual damage amount. CUE schema expects floats.

---

## Follow-Up Tasks

### F1. Wire Armour Equipping (HIGH PRIORITY - Blocks Physics Verification)
**Goal:** `equipArmourById()` should look up armour from `armour_list.getTemplate(id)` and equip to defender.

**Context for implementer:**
- `src/domain/armour_list.zig` has `getTemplate(id)` returning `*const armour.Template`
- `armour.Instance.init(alloc, template)` creates runtime instance
- `armour.Stack.buildFromEquipped(...)` or direct slot assignment needed
- Agent has `armour: armour.Stack` field
- Check `src/testing/integration/domain/damage_resolution.zig` for patterns

**Files:** `data_driven_combat.zig:125` (stub), `harness.zig` (may need helper)

**Verification:** After wiring, `sword_slash_vs_plate` test should show `armour_deflected: true` and low damage. Tighten expected values in `data/tests.cue`.

### F2. Deterministic Test Mode
**Goal:** Force hits (bypass RNG) or seed World's RNG for reproducible results.

**Investigation needed:**
- Check `World` for RNG seed support (user mentioned it exists)
- If insufficient, add `force_hit: bool` parameter to `forceResolveAttack`
- Alternative: mock the roll in `resolveOutcome()` via test hook

**Files:** `src/domain/world.zig` (RNG), `harness.zig`, `outcome.zig`

**Verification:** Same test input always produces same output. Remove `damage_dealt_min: 0` workarounds.

### F3. Outcome Assertion Support
**Goal:** Assert on `expected.outcome: "hit" | "miss" | "glance" | "blocked"`.

**Context:** CUE schema supports this but runner ignores it. `ForceResolveResult.outcome` is `resolution.Outcome` enum.

**Files:** `data_driven_combat.zig:70-80` (add assertion block)

### F4. Weapon/Armour Source of Truth (Design Question)
**Goal:** Resolve whether CUE should be the single source for weapon templates.

**Current state:**
- `weapon_list.zig`: Hand-crafted combat profiles (reach, damage, accuracy)
- `GeneratedWeapons` from CUE: Physics coefficients (geometry_coeff, reference_energy_j)
- Test runner uses mapping table to bridge them

**Options:**
1. Generate `weapon_list.zig` from CUE (single source) - aligns with `doc/artefacts/geometry_momentum_rigidity_review.md` §171 "CUE-first data authoring is the baseline"
2. Merge physics into existing templates manually
3. Keep both, expand mapping table

**Action:** Check if this needs a separate card (may be large scope). Add to design doc open questions if not already tracked.

---

## Open Questions

1. **Short-term armour compromise:** Can F1 be implemented quickly, or does it expose deeper integration gaps requiring design work?

2. **Weapon data unification:** Is generating `weapon_list.zig` from CUE a T040 follow-up or a separate architectural task? Check `doc/artefacts/geometry_momentum_rigidity_review.md` for existing plans.

3. **Defender species:** CUE supports `defender.species` but we hardcode `ser_marcus`. Worth implementing or defer?

4. Should we be generating comptime-known Zig test cases from CUE??
---

## Test / Verification Strategy
- **Current:** Tests pass with permissive ranges, validating infrastructure works
- **After F1:** Tighten assertions to actually verify physics (deflection, penetration depth)
- **After F2:** Remove RNG workarounds, assert exact outcomes