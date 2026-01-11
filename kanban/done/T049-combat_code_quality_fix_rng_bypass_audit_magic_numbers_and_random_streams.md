# T049: Combat Code Quality - Fix RNG Bypass, Audit Magic Numbers & Random Streams
Created: 2026-01-11

## Problem statement / value driver

Combat code has grown organically with magic numbers scattered throughout and at
least one known case of bypassing the world's random streams. This breaks
reproducibility, makes tuning difficult, and violates coding standards.

### Scope - goals

1. Fix known RNG bypass in `positioning.zig`
2. Audit codebase for magic numbers needing extraction to named constants
3. Audit codebase for any other random stream bypasses
4. Coding standards already updated in CLAUDE.md (done in prior session)

### Scope - non-goals

- Implementing contested rolls (separate task, depends on this cleanup)
- Implementing stance triangle UI (separate task)
- Changing balance/tuning values (just extract and document them)

## Background

### Relevant documents

- `doc/artefacts/contested_rolls_and_stance_triangle.md` — parent design doc,
  see "Code Quality Actions" and "Current Random Rolls" sections
- `doc/artefacts/geometry_momentum_rigidity_review.md` — related physics tuning

### Key files

**Known RNG bypass:**
- `src/domain/apply/effects/positioning.zig:117-118` — uses `rng.float(f32)`
  directly instead of `world.drawRandom(.combat)`

**Files with magic numbers to audit:**
- `src/domain/resolution/outcome.zig` — base hit chance (0.5), stat multipliers
- `src/domain/resolution/context.zig` — condition modifiers, flanking penalties
- `src/domain/apply/effects/positioning.zig` — score weights, thresholds
- `src/domain/armour.zig` — may have thresholds

**Random stream infrastructure:**
- `src/domain/random.zig` — defines `RandomStreamID` enum and `drawRandom`
- `src/domain/world.zig` — provides `world.drawRandom(stream_id)`

### Existing systems, memories, research, design intent

All combat randomness MUST go through `world.drawRandom(stream_id)` for:
- Reproducibility (seeded runs for testing/replay)
- Event tracing (random draws can be logged)
- Future triangle integration (stance weights will modify draws)

## Tasks / Sequence of Work

### 1. Fix positioning.zig RNG bypass

The function `resolveManoeuvreConflict` takes `rng: std.Random` as a parameter
and calls `rng.float(f32)` directly. This needs to:
- Take `*World` instead of `std.Random`
- Call `world.drawRandom(.combat)` for the variance roll
- Update all call sites

**Location:** `src/domain/apply/effects/positioning.zig:86-130`

### 2. Audit for other random stream bypasses

Search for:
- `std.Random` usage in `src/domain/` (excluding random.zig itself)
- `.float(f32)` or `.float(f64)` calls
- Any `random()` or `rng.` patterns

Known acceptable uses:
- `src/domain/random.zig` — infrastructure itself
- `src/domain/combat/state.zig:143` — deck shuffle, takes RandomSource correctly
- `src/domain/ai.zig` — AI card selection, uses `world.drawRandom` correctly

### 3. Audit for magic numbers

For each file, identify numeric literals that:
- Affect game balance (hit chances, multipliers, thresholds)
- Are used in calculations (not array indices or loop bounds)
- Would benefit from naming and documentation

Extract to named constants with doc comments explaining their effect.
Group related constants together (e.g., all hit chance modifiers).

**Priority files:**
1. `outcome.zig` — most critical, determines hit/miss
2. `context.zig` — combat modifiers
3. `positioning.zig` — movement contest
4. `armour.zig` — damage resolution

## Test / Verification Strategy

### success criteria / ACs

- [x] No direct `std.Random` usage in combat code (except random.zig)
- [x] All magic numbers in key files extracted to named constants
- [x] Constants have doc comments explaining their effect
- [x] All tests still pass
- [x] `just check` passes

### unit tests

Existing tests should continue to pass. The positioning tests may need updating
if function signatures change.

## Progress Log / Notes

- CLAUDE.md already updated with "Magic Numbers & Randomness" coding standards

### Completed (T049)

**RNG bypass fix:**
- `resolveManoeuvreConflict` now takes `*World` instead of `std.Random`
- Uses `world.drawRandom(.combat)` for contest variance
- Updated caller `resolvePositioningContests` and all tests
- Tests use `ScriptedRandomProvider` via new `TestWorld` helper

**Magic numbers extracted:**

*positioning.zig:*
- `manoeuvre_variance_magnitude` (0.2) — variance in contests
- (existing: speed/position/balance weights, stalemate_threshold)

*outcome.zig (12 constants):*
- `base_hit_chance`, `technique_difficulty_mult`, `weapon_accuracy_mult`
- `engagement_advantage_mult`, `attacker_balance_mult`, `defender_imbalance_mult`
- `guard_direct_cover_penalty`, `guard_adjacent_cover_penalty`, `guard_opening_bonus`
- `weapon_parry_mult`, `hit_chance_min`, `hit_chance_max`

*context.zig (13 constants):*
- Blinded attacker: `blinded_thrust/swing/ranged/other_penalty`
- Winded: `winded_power_attack_damage_mult`
- Grasp: `grasp_hit_penalty_max`, `grasp_damage_mult_min`
- Flanking: `stationary/partial_flanking/surrounded_dodge_penalty`, `surrounded_defense_mult`
- Blinded defender: `blinded_defense_mult`, `blinded_dodge_penalty`
- Mobility: `mobility_dodge_penalty_max`

**New documentation module:**
- `src/domain/resolution/tuning.zig` — central re-export of all combat tuning constants

**Audit notes:**
- `armour.zig:resolveThroughArmour` takes `rng: *std.Random` but is intentionally
  for testing only; production code uses `resolveThroughArmourWithEvents` which
  correctly uses `world.drawRandom(.combat)`. No change needed.
- Magic strings audit: codebase uses comptime string lookups (e.g., `byName`)
  which catch mismatches at compile time. No runtime brittleness found.
