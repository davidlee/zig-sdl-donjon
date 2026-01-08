# T031: Additive Stat Damage Scaling
Created: 2026-01-09

## Problem statement / value driver

Stat scaling is multiplicative, causing baseline stats (5) to multiply damage by ~6×. This produces instant lethality even from improvised weapons, leaving no headroom for armour or tactical attrition.

**Design doc**: `doc/artefacts/damage_lethality_analysis.md` (Phase 3, part 1)

### Scope - goals

- Convert stat scaling from multiplicative to additive
- Baseline stats (5) produce ×1.0 multiplier (neutral)
- Stat differences provide modest differentiation (±20-30% at typical variance)

### Scope - non-goals

- Stakes rebalancing (separate task)
- Stakes→targeting interaction
- Armour integration

## Background

### Key files

- `src/domain/resolution/damage.zig:33-85` - `createDamagePacket()`
- `src/domain/stats.zig` - `STAT_BASELINE`, `STAT_MAX`, `normalize()`

### Current behaviour

```zig
// damage.zig:48-56
const stat_mult: f32 = switch (technique.damage.scaling.stats) {
    .stat => |accessor| attacker.stats.get(accessor),
    .average => |arr| blk: {
        const a = attacker.stats.get(arr[0]);
        const b = attacker.stats.get(arr[1]);
        break :blk (a + b) / 2.0;
    },
};
amount *= stat_mult * technique.damage.scaling.ratio;
```

With stats=5, ratio=1.2: `amount *= 5.0 * 1.2 = 6.0` (600% of base!)

## Changes Required

Replace multiplicative scaling with additive bonus:

```zig
const stat_value: f32 = switch (technique.damage.scaling.stats) {
    .stat => |accessor| attacker.stats.get(accessor),
    .average => |arr| blk: {
        const a = attacker.stats.get(arr[0]);
        const b = attacker.stats.get(arr[1]);
        break :blk (a + b) / 2.0;
    },
};

const baseline_norm = stats.STAT_BASELINE / stats.STAT_MAX; // 0.5
const stat_norm = stats.Block.normalize(stat_value);
const stat_bonus = (stat_norm - baseline_norm) * technique.damage.scaling.ratio;
amount *= 1.0 + stat_bonus;
```

### Expected outcomes

| Stat | Normalized | Bonus (ratio=1.2) | Multiplier |
|------|------------|-------------------|------------|
| 1 | 0.1 | -0.48 | ×0.52 |
| 3 | 0.3 | -0.24 | ×0.76 |
| 5 | 0.5 | 0.00 | ×1.00 |
| 7 | 0.7 | +0.24 | ×1.24 |
| 10 | 1.0 | +0.60 | ×1.60 |

### Challenges / Open Questions

1. **Ratio values**: Current ratios (0.5-1.2) were tuned for multiplicative. May need adjustment, but start with existing values and assess.

2. **Damage baseline**: With ×1.0 at baseline, raw damage drops significantly. Worked example:
   - Sword swing: `1.0 (tech) × 10.0 (weapon) × 1.0 (stakes) × 1.0 (stat) = 10.0`
   - Current: `1.0 × 10.0 × 1.0 × 6.0 = 60.0`

   This is intentional - we want survivability. But verify severity outcomes make sense.

## Tasks / Sequence of Work

1. [x] Implement additive scaling in `createDamagePacket()`
2. [x] Update/add unit tests for new scaling behaviour
3. [x] Run full test suite, fix breakages
4. [x] Manual verification of damage outcomes
5. [x] Update analysis doc with results

## Test / Verification Strategy

### success criteria

- Baseline stats (5) produce ×1.0 multiplier
- High stats (+2 from baseline) produce ~+24% damage (ratio=1.2)
- Low stats (-2 from baseline) produce ~-24% damage (ratio=1.2)
- Combat is no longer instantly lethal (multiple hits to incapacitate)

### unit tests

- Test `createDamagePacket()` with various stat values
- Verify multiplier calculations at baseline, high, low stats
- Verify different technique ratios scale appropriately

### manual verification

After implementation, recalculate worked examples from analysis doc:
- Thrown rock (guarded, stats=5) should produce minor wounds, not disabled
- Sword swing (guarded, stats=5) should produce inhibited/disabled, not missing

## Progress Log / Notes

### 2026-01-09

**Implementation complete.**

Refactored to put scaling logic in `stats.zig` (reusable for non-damage contexts):

```zig
// stats.zig
pub fn scalingMultiplier(stat_value: f32, ratio: f32) f32 {
    const baseline_norm = STAT_BASELINE / STAT_MAX;
    const stat_norm = Block.normalize(stat_value);
    return 1.0 + (stat_norm - baseline_norm) * ratio;
}
```

`damage.zig` now calls `stats.scalingMultiplier(stat_value, ratio)`.

**Files changed:**
- `src/domain/stats.zig` - added `scalingMultiplier()` + 2 tests
- `src/domain/resolution/damage.zig` - simplified stat scaling to single function call

**Verification - damage outcomes:**

| Attack | Before | After | Outcome |
|--------|--------|-------|---------|
| Thrown rock | 24.0 | 6.0 | muscle/bone: disabled → minor |
| Sword swing | 60.0 | 10.0 | skin: missing → disabled |

All tests pass (`just check` clean).
