# T030: Lethality Retune Step 1
Created: 2026-01-09

## Problem statement / value driver

Combat is tuned for instant lethality. A thrown rock disables muscle and bone; a sword swing destroys skin and fat completely. No headroom for armour or tactical attrition.

**Design doc**: `doc/artefacts/damage_lethality_analysis.md`

### Scope - goals

- Fix natural weapon damage (clearly wrong)
- Add stat baseline constants
- Rescale weapon damage ×10 for clarity
- Adjust severity thresholds to match

### Scope - non-goals

- Formula changes (Phase 3 - separate task)
- Stakes rebalancing (Phase 3)
- Armour system integration

## Background

### Key files

- `src/domain/species.zig` - FIST, BITE, HEADBUTT natural weapons
- `src/domain/weapon_list.zig` - weapon damage values
- `src/domain/stats.zig` - Block, normalize()
- `src/domain/body.zig` - severityFromDamage()

### Current state

Natural weapons have damage 2-4× higher than steel weapons:
- FIST: 2.0 (should be ~0.2)
- BITE: 3.0 (should be ~0.4)
- HEADBUTT: 4.0 (should be ~0.3)

Weapon damage scale is 0.4-1.0, too compressed for clarity.

## Changes Required

### 1. Fix natural weapons (species.zig)

```zig
FIST.swing.damage = 0.2       // was 2.0
BITE.thrust.damage = 0.4      // was 3.0
HEADBUTT.thrust.damage = 0.3  // was 4.0
```

### 2. Add stat constants (stats.zig)

```zig
pub const STAT_BASELINE: f32 = 5.0;
pub const STAT_MAX: f32 = 10.0;
```

### 3. Rescale weapon damage ×10 (weapon_list.zig)

All offensive profiles: multiply `.damage` by 10.

| Weapon | Current | New |
|--------|---------|-----|
| fist_stone_swing | 0.4 | 4.0 |
| fist_stone_throw | 0.6 | 6.0 |
| knights_sword_swing | 1.0 | 10.0 |
| knights_sword_thrust | 0.8 | 8.0 |
| etc. | | |

Natural weapons (after fix): ×10 as well:
- FIST: 0.2 → 2.0
- BITE: 0.4 → 4.0
- HEADBUTT: 0.3 → 3.0

### 4. Rescale severity thresholds ×10 (body.zig)

```zig
fn severityFromDamage(amount: f32) Severity {
    if (amount < 0.5) return .none;     // was 0.05
    if (amount < 1.5) return .minor;    // was 0.15
    if (amount < 3.0) return .inhibited; // was 0.30
    if (amount < 5.0) return .disabled;  // was 0.50
    if (amount < 8.0) return .broken;    // was 0.80
    return .missing;
}
```

## Tasks / Sequence of Work

1. [x] Fix natural weapon damage values
2. [x] Add STAT_BASELINE/STAT_MAX constants
3. [x] Rescale all weapon offensive profile damage ×10
4. [x] Rescale severityFromDamage thresholds ×10
5. [x] Run tests, fix any breakage
6. [x] Verify damage outcomes are unchanged (just rescaled)

## Test / Verification Strategy

### success criteria

- All existing tests pass (values scale together, ratios unchanged)
- Natural weapons deal less damage than steel equivalents
- Sword damage reads as 10.0, fist as 2.0 in data

### unit tests

- Existing body.zig damage tests should pass after threshold adjustment
- May need to update test assertions if they check specific damage values

## Progress Log / Notes

### 2026-01-09

**Completed all tasks.**

Changes made:
- `species.zig`: Natural weapons fixed (FIST=2.0, BITE=4.0, HEADBUTT=3.0)
- `stats.zig`: Added `STAT_BASELINE` (5.0) and `STAT_MAX` (10.0) constants, updated `normalize()` to use them
- `weapon_list.zig`: All 13 offensive profile damage values ×10 (sword=10.0, etc.)
- `body.zig`: `severityFromDamage()` thresholds ×10

Tests updated:
- `body.zig`: 7 test packets updated (1.0→10.0, 0.6→6.0, etc.)
- `armour.zig`: 1 test packet updated with adjusted expected calculation

All tests pass (`just check` clean).
