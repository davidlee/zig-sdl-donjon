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

## Changes Required

### 1. CUE Schema (`data/tests.cue`)
```cue
#CombatTest: {
    id: string
    description: string
    attacker: { ... }
    defender: { ... }
    expected: {
        outcome?: "hit" | "miss" | ...
        damage_dealt_max?: float
    }
}
```

### 2. Generator (`scripts/cue_to_zig.py`)
- Emit `GeneratedCombatTests`.

### 3. Harness Extensions
- `forceResolveAttack(...)`: Direct resolution bypassing UI state.

### 4. Test Runner (`src/testing/data_driven_runner.zig`)
- Execute generated tests.

## Tasks / Sequence of Work
1.  [ ] Create `data/tests.cue` with "Sword vs Plate" (Glance) and "Pick vs Plate" (Penetrate) cases.
2.  [ ] Update `scripts/cue_to_zig.py`.
3.  [ ] Implement `src/testing/data_driven_runner.zig` and Harness extensions.
4.  [ ] Run tests and **Expect Success** (verifying the physics math fixes).

## Test / Verification Strategy
- **Success Criteria:** The suite passes, confirming that the code correctly distinguishes between Weapon Geometry (sharpness) and Penetration (depth budget).