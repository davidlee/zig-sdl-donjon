# Damage & Lethality Analysis

**Related**:
- `doc/issues/lethality.md`
- `doc/issues/impulse_penetration_bite.md` (three-axis damage model supersedes much of this)
- `doc/issues/combat_modifiers_redesign.md` (stakes, height, modifiers)

---

## Progress

- [x] **Phase 1**: Natural weapons fixed (T030, 2026-01-09)
- [x] **Phase 2**: Foundation work complete - stat constants, ×10 rescale (T030, 2026-01-09)
- [x] **Phase 3a**: Additive stat scaling (T031, 2026-01-09)
- [x] **Phase 3b**: Stakes numbers retuned (hit ±0.3, damage 0.85-1.2) → see `doc/issues/combat_modifiers_redesign.md` for further work

---

## Summary

Combat damage is tuned for instant lethality. A single hit from even improvised weapons can produce catastrophic wounds (disabled/broken/missing tissue layers). This leaves no headroom for armour mitigation and prevents the gradual attrition that historical combat exhibits.

---

## Current Damage Pipeline

### Formula

```
final_damage = technique_base × stat_multiplier × weapon_damage × stakes_mult

where:
  stat_multiplier = stat_value × scaling_ratio
```

### Data Flow

```
TechniqueEntries (card_list.zig)
    └── damage.Base { instances: []Instance, scaling: Scaling }
            │
            ▼
    technique_base = sum(instances[*].amount)     // always 1.0 for attacks
    stat_mult = stat × scaling.ratio              // e.g., 5.0 × 1.2 = 6.0
            │
            ▼
Weapon Offensive Profile (weapon_list.zig)
    └── damage: f32                               // 0.4 - 1.0 range
            │
            ▼
Stakes (cards.zig)
    └── damageMultiplier()                        // 0.4 - 2.0
            │
            ▼
damage.Packet { amount, kind, penetration }
            │
            ▼
body.applyDamage() → Wound with LayerDamage[]
```

### Key Files

| File | Role |
|------|------|
| `src/domain/card_list.zig:49-310` | `TechniqueEntries` - technique definitions with damage |
| `src/domain/weapon_list.zig` | Weapon templates with offensive profiles |
| `src/domain/resolution/damage.zig:33-85` | `createDamagePacket()` - assembles final damage |
| `src/domain/body.zig:810-855` | `applyDamage()` - tissue layer processing |
| `src/domain/body.zig:759-796` | `layerResistance()` - absorption per layer/type |
| `src/domain/body.zig:800-807` | `severityFromDamage()` - damage→severity thresholds |

---

## Current Values (Post-T030)

> **Note**: Values below updated to reflect T030 changes. See git history for pre-fix values.

### Technique Damage (card_list.zig)

All offensive techniques use `amount = 1.0`:

| Technique | Base | Scaling Ratio | Scaling Stats |
|-----------|------|---------------|---------------|
| thrust | 1.0 | 0.5 | avg(speed, power) |
| swing | 1.0 | 1.2 | avg(speed, power) |
| throw | 1.0 | 0.8 | avg(speed, speed) |
| riposte | 1.2 | 0.6 | avg(speed, power) |

### Weapon Damage (weapon_list.zig)

| Weapon | Profile | Damage | Penetration |
|--------|---------|--------|-------------|
| fist_stone_swing | bludgeon | 4.0 | 0.1 |
| fist_stone_throw | bludgeon | 6.0 | 0.2 |
| knights_sword_swing | slash | 10.0 | 0.5 + 4.0×0.5 |
| knights_sword_thrust | pierce | 8.0 | 1.0 + 6.0×0.5 |
| dirk_thrust | pierce | 7.0 | 1.2 + 5.0×0.5 |

### Natural Weapons (species.zig)

| Weapon | Damage | Notes |
|--------|--------|-------|
| FIST | 2.0 | ~20% of sword |
| BITE | 4.0 | ~40% of sword |
| HEADBUTT | 3.0 | ~30% of sword |

Natural weapons are now appropriately weaker than steel.

### Stats

Agents typically use `stats.Block.splat(5)` - all stats at 5.0.

### Stakes Multipliers (cards.zig)

| Stakes | Damage Mult |
|--------|-------------|
| probing | 0.4 |
| guarded | 1.0 |
| committed | 1.4 |
| reckless | 2.0 |

### Severity Thresholds (body.zig)

```zig
fn severityFromDamage(amount: f32) Severity {
    if (amount < 0.5) return .none;
    if (amount < 1.5) return .minor;
    if (amount < 3.0) return .inhibited;
    if (amount < 5.0) return .disabled;
    if (amount < 8.0) return .broken;
    return .missing;  // >= 8.0
}
```

### Tissue Absorption (body.zig:759-796)

Each layer absorbs a fraction of remaining damage:

**Slash:**
| Layer | Absorb | Pen Cost |
|-------|--------|----------|
| skin | 0.40 | 0.3 |
| fat | 0.25 | 0.2 |
| muscle | 0.20 | 0.3 |
| bone | 0.10 | 1.0 |

**Bludgeon:**
| Layer | Absorb | Pen Cost |
|-------|--------|----------|
| skin | 0.05 | 0.0 |
| fat | 0.10 | 0.0 |
| muscle | 0.30 | 0.0 |
| bone | 0.50 | 0.0 |

---

## Worked Examples

> **Note (historical)**: These examples show the pre-T031 multiplicative scaling that caused instant lethality. Post-T031, baseline stats produce ×1.0 multiplier instead of ×4-6×. Actual damage is now:
> - Thrown rock: 6.0 (was 24.0) → minor wounds
> - Sword swing: 10.0 (was 60.0) → disabled skin, survivable

### Example 1: Thrown Rock (guarded stakes, stats=5)

```
technique_base = 1.0
stat_mult = 5.0 × 0.8 = 4.0
weapon_damage = 0.6
stakes = 1.0

final = 1.0 × 4.0 × 0.6 × 1.0 = 2.4 bludgeon
```

Tissue cascade (limb template: skin→fat→muscle→tendon→bone):

| Layer | Calculation | Absorbed | Severity |
|-------|-------------|----------|----------|
| skin | 2.40 × 0.05 | 0.12 | minor |
| fat | 2.28 × 0.10 | 0.23 | inhibited |
| muscle | 2.05 × 0.30 | 0.62 | **disabled** |
| tendon | 1.43 × 0.10 | 0.14 | minor |
| bone | 1.29 × 0.50 | 0.65 | **disabled** |

**Result**: A thrown rock disables muscle AND bone. Historically implausible.

### Example 2: Sword Swing (guarded stakes, stats=5)

```
technique_base = 1.0
stat_mult = 5.0 × 1.2 = 6.0
weapon_damage = 1.0
stakes = 1.0

final = 1.0 × 6.0 × 1.0 × 1.0 = 6.0 slash
penetration = 0.5 + 4.0 × 0.5 = 2.5
```

Tissue cascade:

| Layer | Calculation | Absorbed | Severity | Pen Remaining |
|-------|-------------|----------|----------|---------------|
| skin | 6.0 × 0.40 | 2.40 | **missing** | 2.2 |
| fat | 3.6 × 0.25 | 0.90 | **missing** | 2.0 |
| muscle | 2.7 × 0.20 | 0.54 | disabled | 1.7 |
| tendon | 2.16 × 0.30 | 0.65 | disabled | 1.5 |
| bone | 1.51 × 0.10 | 0.15 | inhibited | 0.5 |

**Result**: Skin and fat completely destroyed. Would likely sever limb.

### Example 3: Headbutt (guarded stakes, stats=5)

```
technique_base = 1.0 (swing technique)
stat_mult = 5.0 × 1.2 = 6.0
weapon_damage = 4.0  // HEADBUTT natural weapon
stakes = 1.0

final = 1.0 × 6.0 × 4.0 × 1.0 = 24.0 bludgeon
```

This is absurd - a headbutt deals 4× the damage of a sword swing.

---

## Root Cause Analysis

### Primary Issue: Stat Scaling is Multiplicative

The formula `stat × ratio` produces enormous multipliers:

| Stats | Ratio | Multiplier |
|-------|-------|------------|
| 5.0 | 0.5 | 2.5× |
| 5.0 | 0.8 | 4.0× |
| 5.0 | 1.2 | 6.0× |

With stats=5 being the baseline, damage is amplified 2.5-6× before other factors.

### Secondary Issue: No Differentiation at Technique Level

All offensive techniques use `amount = 1.0`. The technique's role in damage is solely through scaling ratio, which compounds the stat problem.

### Tertiary Issue: Natural Weapons Inverted

Natural weapons have damage values 2-4× higher than steel weapons. This is backwards - an unarmed punch should do far less damage than a sword.

### Quaternary Issue: Tight Severity Thresholds

The gap between "minor" (0.05-0.15) and "disabled" (0.30-0.50) is narrow. With damage amounts routinely exceeding 1.0, most hits skip intermediate states entirely.

---

## Design Considerations for Armour

For historical plate armour to function correctly:

1. **Unarmoured baseline must be survivable** - multiple hits to incapacitate
2. **Damage must accumulate gradually** - wounds compound over time
3. **Armour needs reduction headroom** - if unarmoured = instant death, armour can only reduce to "slightly less instant death"

Target state: An unarmoured combatant should sustain 3-5 solid hits before incapacitation. This gives plate armour room to multiply that to 10-20+ hits.

---

## Stakes Balance Problem

Stakes currently affects damage far more than hit chance:

| Stakes | Hit Bonus | Damage Mult | Ratio |
|--------|-----------|-------------|-------|
| probing | -0.1 | 0.4 | — |
| guarded | 0.0 | 1.0 | — |
| committed | +0.1 | 1.4 | — |
| reckless | +0.2 | 2.0 | — |

**Hit chance**: ±0.2 range (tiny)
**Damage**: 5× range (probing→reckless)

Escalating stakes should make attacks **more likely to connect** and **more likely to hit vital locations**, not just "bigger numbers". A reckless swing to the head should be risky because it's telegraphed and leaves you open, not because it magically does 2× damage.

### Height Targeting (current)

The height system affects **hit location selection**, not hit probability:

```zig
// height.zig
pub const height_weight = struct {
    pub const primary: f32 = 2.0;    // target height
    pub const secondary: f32 = 1.0;  // secondary (if set)
    pub const adjacent: f32 = 0.5;   // adjacent to target
    pub const off_target: f32 = 0.1; // opposite height
};
```

Guard coverage:
- Guarded zone: ×0.3 weight
- Adjacent to guard: ×0.6 weight

This is reasonable but disconnected from stakes. Stakes should interact with targeting:
- Probing: safer target selection (torso/limbs)
- Reckless: can target head/vitals but easier to defend against

---

## Stat Normalization (Existing Infrastructure)

`stats.zig` already has normalization that **isn't being used**:

```zig
pub fn normalize(value: f32) f32 {
    const baseline: f32 = 10.0;
    return std.math.clamp(value / baseline, 0.0, 1.0);
}
// stat 5 → 0.5, stat 10 → 1.0
```

This suggests the intended design was:
- Stats range: 1-10 (baseline 5)
- Normalized range: 0.1-1.0 (baseline 0.5)
- Average character: all stats at 5

The damage formula should use `normalize()` rather than raw stat values.

---

## Weapon Damage Scale

Current weapon damage values (0.4-1.0) are too compressed. For design clarity:

| Current | Proposed | Weapon |
|---------|----------|--------|
| 0.4 | 4.0 | thrown rock |
| 0.6 | 6.0 | thrown rock (with momentum) |
| 1.0 | 10.0 | sword |
| 0.8 | 8.0 | thrust |

Benefits of ×10 scale:
- Intuitive ("sword does 10 damage")
- Room for fine-grained differentiation
- Natural weapons can be 1-3 (clearly weaker than steel)

Requires adjusting severity thresholds proportionally.

---

## Multiplicative vs Additive Scaling

**Current (multiplicative)**:
```
damage = base × (stat × ratio) × weapon × stakes
```

Problem: Power becomes disproportionately valuable. A character with Power 7 vs Power 3 gets ~2.3× damage, overwhelming all other factors.

**Proposed (additive bonuses)**:
```
damage = (base × weapon × stakes) × (1 + stat_bonus)

where:
  stat_bonus = (normalized_stat - 0.5) × ratio
```

With baseline stat 5 (normalized 0.5):
- stat_bonus = 0 at baseline
- stat 7 → +0.1 to +0.2 bonus (ratio dependent)
- stat 3 → -0.1 to -0.2 penalty

Stats still matter but don't dominate. A strong character hits ~20% harder, not 200% harder.

---

## Options

### Option 1: Reduce Scaling Ratios

Change technique scaling ratios from 0.5-1.2 to 0.05-0.15.

**Pros**: Simple change, isolated to `card_list.zig`
**Cons**: Stats feel flat, minimal differentiation between high/low stat characters

```zig
// Before
.scaling = .{ .ratio = 1.2, .stats = ... }

// After
.scaling = .{ .ratio = 0.15, .stats = ... }
```

### Option 2: Additive Scaling Formula

Change from `stat × ratio` to `1.0 + (stat - baseline) × ratio / factor`:

```zig
// In resolution/damage.zig createDamagePacket()
// Before:
amount *= stat_mult * technique.damage.scaling.ratio;

// After (with baseline=5, factor=20):
const stat_bonus = (stat_mult - 5.0) * technique.damage.scaling.ratio / 20.0;
amount *= 1.0 + stat_bonus;
```

With stats=5, ratio=1.2: multiplier = 1.0 (no bonus at baseline)
With stats=7, ratio=1.2: multiplier = 1.0 + (2 × 1.2 / 20) = 1.12

**Pros**: Stats still matter, baseline is calibrated
**Cons**: More complex formula, requires tuning baseline/factor

### Option 3: Lower Technique Base Amounts

Reduce `amount` in technique instances from 1.0 to 0.1-0.3:

```zig
// Before
.damage = .{ .instances = &.{.{ .amount = 1.0, .types = &.{.slash} }}, ... }

// After
.damage = .{ .instances = &.{.{ .amount = 0.2, .types = &.{.slash} }}, ... }
```

**Pros**: Preserves stat differentiation, technique-specific tuning
**Cons**: Counterintuitive (base amount feels like it should be ~1.0)

### Option 4: Raise Severity Thresholds

Multiply all thresholds by 3-4×:

```zig
fn severityFromDamage(amount: f32) Severity {
    if (amount < 0.20) return .none;    // was 0.05
    if (amount < 0.60) return .minor;   // was 0.15
    if (amount < 1.20) return .inhibited; // was 0.30
    if (amount < 2.00) return .disabled;  // was 0.50
    if (amount < 3.20) return .broken;    // was 0.80
    return .missing;
}
```

**Pros**: Simple, makes all damage more survivable
**Cons**: Doesn't address the underlying stat scaling issue

### Option 5: Fix Natural Weapons (Independent)

Reduce natural weapon damage regardless of other changes:

```zig
pub const FIST = weapon.Template{
    .swing = .{ .damage = 0.3, ... },  // was 2.0
    ...
};

pub const BITE = weapon.Template{
    .thrust = .{ .damage = 0.5, ... },  // was 3.0
    ...
};

pub const HEADBUTT = weapon.Template{
    .thrust = .{ .damage = 0.4, ... },  // was 4.0
    ...
};
```

---

## Recommended Approach

### Phase 1: Immediate Fixes ✓

> Completed in T030 (2026-01-09)

1. ~~**Fix natural weapon damage** - clearly wrong, no design debate needed~~
   - FIST: 2.0 → 0.2 → 2.0 (after ×10)
   - BITE: 3.0 → 0.4 → 4.0 (after ×10)
   - HEADBUTT: 4.0 → 0.3 → 3.0 (after ×10)

### Phase 2: Foundation Work ✓

> Completed in T030 (2026-01-09)

1. ~~**Define stat constants in stats.zig**~~
   ```zig
   pub const STAT_BASELINE: f32 = 5.0;
   pub const STAT_MAX: f32 = 10.0;
   ```

2. ~~**Rescale weapon damage ×10** for clarity~~
   - Rock: 0.6 → 6.0
   - Sword: 1.0 → 10.0
   - Natural: 2.0-4.0

3. ~~**Adjust severity thresholds ×10** to match~~
   ```zig
   if (amount < 0.5) return .none;
   if (amount < 1.5) return .minor;
   if (amount < 3.0) return .inhibited;
   if (amount < 5.0) return .disabled;
   if (amount < 8.0) return .broken;
   return .missing;
   ```

### Phase 3a: Additive Stat Scaling ✓

> Completed in T031 (2026-01-09)

1. ~~**Switch to additive stat scaling**~~
   ```zig
   // stats.zig
   pub fn scalingMultiplier(stat_value: f32, ratio: f32) f32 {
       const baseline_norm = STAT_BASELINE / STAT_MAX;
       const stat_norm = Block.normalize(stat_value);
       return 1.0 + (stat_norm - baseline_norm) * ratio;
   }
   ```

### Phase 3b: Stakes Rebalance

2. **Rebalance stakes** - more hit/targeting, less raw damage
   ```zig
   // Old: hit ±0.2, damage 0.4-2.0
   // New: hit ±0.3, damage 0.7-1.3
   pub fn hitChanceBonus(self: Stakes) f32 {
       return switch (self) {
           .probing => -0.15,
           .guarded => 0.0,
           .committed => 0.15,
           .reckless => 0.30,
       };
   }

   pub fn damageMultiplier(self: Stakes) f32 {
       return switch (self) {
           .probing => 0.7,
           .guarded => 1.0,
           .committed => 1.15,
           .reckless => 1.3,
       };
   }
   ```

3. **Add stakes→targeting interaction**
   - Probing: cannot target high (head)
   - Reckless: can target any height, but defender gets coverage bonus

### Rationale

The goal is a system where:
- Weapons define the damage envelope (sword ~10, rock ~6, fist ~2)
- Stats provide modest differentiation (±20% at extremes)
- Stakes affects risk/reward (hit chance, targeting, openings) not raw damage
- Armour has room to matter when implemented

This creates space for tactical decisions rather than "always go reckless for 2× damage".

---

## Test Cases for Validation

After changes, verify:

### Damage Outcomes
1. Thrown rock (guarded, stats=5) produces minor/inhibited wounds, not disabled
2. Sword swing (guarded, stats=5) produces inhibited/disabled outer layers, not missing
3. Natural weapons deal less than half the damage of equivalent steel weapons
4. 3-5 solid sword hits required to incapacitate unarmoured target

### Stat Differentiation
5. High-stat character (power=7) deals ~20% more than baseline (power=5)
6. Low-stat character (power=3) deals ~20% less than baseline
7. Stat difference is noticeable but not dominant

### Stakes Balance
8. Reckless attacks ~30% more likely to hit than probing
9. Reckless attacks ~30% more damaging than probing (was 5×)
10. Probing attacks safer but less decisive
11. Stakes affects targeting options (phase 3)

### Scale Clarity
12. Sword damage reads as ~10.0 in data
13. Fist damage reads as ~2.0 in data
14. Severity thresholds are in similar numeric range

---

## Open Questions

1. **Technique base amounts**: Should techniques differentiate via base amount (swing=1.0, thrust=0.8) or just via scaling? Currently all use 1.0.

2. **Stakes→defense interaction**: Should reckless attacks be easier to defend against? Current advantageMultiplier partially addresses this but only affects advantage accumulation.

3. **Penetration scaling**: Does penetration need similar rebalancing? Currently weapons have penetration 0.1-1.5 with max 0-6.

4. **Tissue absorption model**: Is the cascading absorption (each layer takes % of remaining) the right model? Alternative: fixed absorption per layer.

5. **Armour integration point**: Where does armour reduction fit in the formula? Before tissue processing seems natural.

---

## References

- `src/domain/card_list.zig` - TechniqueEntries
- `src/domain/weapon_list.zig` - weapon templates
- `src/domain/species.zig` - natural weapons (FIST, BITE, HEADBUTT)
- `src/domain/resolution/damage.zig` - createDamagePacket()
- `src/domain/resolution/height.zig` - height targeting and weights
- `src/domain/body.zig` - applyDamage(), severityFromDamage(), layerResistance()
- `src/domain/cards.zig` - Stakes enum, Technique struct
- `src/domain/stats.zig` - Block struct, normalize()
