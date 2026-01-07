# Phase 2: Condition Penalties - Implementation Plan

## Handover Notes (2026-01-08)

### Increment 1 Progress: ✓ Complete

**DONE:**
- `body.zig`: Added `visionScore()`, `hearingScore()`, `graspingPartBySide()` after `mobilityScore()` (~line 459-507)
- `positioning.zig`: Added `damage` import, `footworkMultForAgent()` helper (~line 52-61)
- `positioning.zig`: Updated `calculateManoeuvreScore()` to take `footwork_mult` param and apply it
- `positioning.zig`: Updated `resolveManoeuvreConflict()` to compute and pass footwork_mult
- `positioning.zig`: Updated existing tests to pass `1.0` for footwork_mult param
- `body.zig`: Added tests for `visionScore()`, `hearingScore()`, `graspingPartBySide()` (line ~1642-1715)
- Ran `zig fmt` on modified files
- Build passes, all tests pass

**Notes:**
- `footworkMultForAgent()` test deferred: private helper, penalty table/combine tested in damage.zig
- Sensory score tests use `.broken` severity (0.1 integrity) to reliably trigger < 0.3 threshold

---

## Current State Summary

### Existing Infrastructure

**Body capability system** (`body.zig`):
- `PartDef.Flags`: `can_grasp`, `can_stand`, `can_see`, `can_hear`
- `graspStrength(part_idx)` - integrity × (functional children / total)
- `mobilityScore()` - average effective integrity of `can_stand` parts
- Missing: `visionScore()`, `hearingScore()`

**Condition system** (`combat/agent.zig`):
- `ConditionIterator` yields stored + computed conditions (6 phases currently)
- Computed phases: balance → blood loss (3 thresholds) → engagement pressure (2)
- `Condition` enum includes `.blinded`, `.deafened` (exist but not computed)

**Penalty system** (`damage.zig`, `resolution/context.zig`):
- `CombatPenalties` struct: `hit_chance`, `damage_mult`, `defense_mult`, `dodge_mod`, `footwork_mult`
- `condition_penalties` comptime table
- `forAttacker`/`forDefender` iterate conditions, combine penalties
- Special cases inline: `blinded` (uses `attack.technique.attack_mode`), `winded` (stakes)

**Footwork system** (`apply/effects/positioning.zig`):
- `calculateManoeuvreScore()` = speed×0.3 + position×0.4 + balance×0.3
- `footwork_mult` in `CombatPenalties` is defined but **not applied** here

**Resource system** (`stats.zig`):
- `Resource` struct: `current`, `available`, `max`, `per_turn`
- Blood: `init(5.0, 5.0, 0.0)` - starts full, drains per-tick, no recovery

---

## Incremental Delivery Plan

### Increment 1: Sensory Score Methods + `footwork_mult` Wiring

**Goal**: Add `visionScore()`, `hearingScore()` to Body; wire up `footwork_mult` to manoeuvre scoring.

**Files**:
- `src/domain/body.zig` - add methods + tests
- `src/domain/apply/effects/positioning.zig` - apply `footwork_mult` in `calculateManoeuvreScore()`

**Changes**:

```zig
// body.zig - following mobilityScore() pattern
pub fn visionScore(self: *const Body) f32 {
    var buf: [256]f32 = undefined;
    const eff = buf[0..self.parts.items.len];
    self.computeEffectiveIntegrities(eff);

    var total: f32 = 0;
    var count: f32 = 0;
    for (self.parts.items, 0..) |p, i| {
        if (p.flags.can_see) {
            total += eff[i];
            count += 1;
        }
    }
    return if (count > 0) total / count else 0;
}

pub fn hearingScore(self: *const Body) f32 {
    // Same pattern with can_hear
}
```

```zig
// positioning.zig - calculateManoeuvreScore needs footwork_mult
// Problem: function takes Agent but doesn't have access to condition penalties
// Solution: Pass footwork_mult as parameter, caller aggregates from conditions
pub fn calculateManoeuvreScore(
    agent: *const combat.Agent,
    move: ManoeuvreType,
    position: f32,
    footwork_mult: f32,  // NEW
) f32 {
    var score = (speed * speed_weight) + (position * position_weight) + (balance * balance_weight);
    if (move == .hold) score -= standing_still_penalty;
    return score * footwork_mult;  // Apply mobility penalty
}
```

**Tests**: Unit tests for scores; update positioning tests for new signature.

---

### Increment 2: Computed Sensory Conditions

**Goal**: `ConditionIterator` yields `.blinded`/`.deafened` based on body scores; add `.deafened` penalty.

**Files**:
- `src/domain/combat/agent.zig` - extend `ConditionIterator`
- `src/domain/damage.zig` - add `.deafened` to penalty table

**Changes**:

```zig
// ConditionIterator - extend computed_phase
// After blood loss (1-3), before engagement (4-5):
// New phases 4, 5 for sensory; shift engagement to 6, 7

switch (self.computed_phase) {
    // ... existing 0-3 ...
    4 => {
        if (self.agent.body.visionScore() < 0.3) {
            return .{ .condition = .blinded, .expiration = .dynamic };
        }
    },
    5 => {
        if (self.agent.body.hearingScore() < 0.3) {
            return .{ .condition = .deafened, .expiration = .dynamic };
        }
    },
    6, 7 => { /* existing engagement phases */ },
}
```

```zig
// damage.zig - add to condition_penalties table
table[@intFromEnum(Condition.deafened)] = .{
    .defense_mult = 0.9,  // -10% defense: can't hear opponent's footwork
};
```

**Design note**: `blinded` keeps special-case handling in `forAttacker()` for attack-mode penalties. Computed condition just triggers the switch case.

**Tests**: Test that damaged eyes yield `.blinded`, damaged ears yield `.deafened`; verify penalties applied.

---

### Increment 3: Wound Penalties in Combat Resolution

**Goal**: Grasp strength affects attack accuracy/damage; mobility affects dodge/footwork.

**Files**:
- `src/domain/resolution/context.zig` - extend `forAttacker()`, `forDefender()`
- `src/domain/combat/agent.zig` - may need weapon hand accessor

**Changes**:

```zig
// forAttacker() - after condition loop
// Use dominant hand for weapon grasp
const weapon_hand = attack.attacker.body.graspingPartBySide(attack.attacker.dominant_side);
if (weapon_hand) |hand_idx| {
    const grasp = attack.attacker.body.graspStrength(hand_idx);
    if (grasp < 1.0) {
        mods.hit_chance += (1.0 - grasp) * -0.25;  // up to -25% hit
        mods.damage_mult *= 0.5 + (grasp * 0.5);   // 50-100% damage
    }
}

// forDefender() - after condition loop
const mobility = defense.defender.body.mobilityScore();
if (mobility < 1.0) {
    mods.dodge_mod += (1.0 - mobility) * -0.30;  // up to -30% dodge
}
```

**Tests**: Verify wounded arm reduces hit chance; verify wounded legs reduce dodge.

---

### Increment 4: Trauma Resource

**Goal**: Psychological shock accumulates from wounds, triggers mental conditions.

**Files**:
- `src/domain/combat/agent.zig` - add `trauma: stats.Resource`
- `src/domain/body.zig` or damage application path - `traumaFromWound()`
- `src/domain/damage.zig` - add `panicked` condition + penalties
- `src/domain/events.zig` - `trauma_accumulated` event (optional)

**Changes**:

```zig
// Agent
trauma: stats.Resource,  // init(0.0, 10.0, 0.0) - starts empty

// traumaFromWound - called from damage application
fn traumaFromWound(wound: Wound, hit_artery: bool) f32 {
    var t: f32 = switch (wound.worstSeverity()) {
        .minor => 0.5,
        .inhibited => 1.0,
        .disabled => 2.0,
        .broken => 3.0,
        .missing => 5.0,
        .none => 0,
    };
    if (hit_artery) t += 2.0;
    return t;
}

// ConditionIterator - computed trauma conditions
// trauma.current / trauma.max thresholds:
// > 0.3 → shaken (exists)
// > 0.6 → fearful (exists)
// > 0.8 → panicked (new)
```

**Tests**: Verify wounds accumulate trauma; verify thresholds trigger conditions.

---

## Files Summary

| Increment | Files Modified |
|-----------|----------------|
| 1 | `body.zig` (visionScore, hearingScore, graspingPartBySide), `apply/effects/positioning.zig` |
| 2 | `combat/agent.zig` (ConditionIterator), `damage.zig` (deafened penalty) |
| 3 | `resolution/context.zig` (forAttacker, forDefender) |
| 4 | `combat/agent.zig` (trauma resource), `damage.zig` (panicked condition), damage path, `events.zig` |

---

## Design Decisions (Confirmed)

1. **Sensory threshold**: `< 0.3` (30% vision/hearing remaining) triggers condition
2. **`deafened` penalty**: Minor defense penalty (-10% defense_mult) - can't hear opponent's footwork
3. **Grasp selection**: Use `agent.dominant_side` (already exists on Agent) to find weapon hand
4. **Trauma thresholds**: 30%/60%/80% of max (per doc)

---

## Implementation Detail: Weapon Hand Lookup

Agent already has `dominant_side: body.Side`. Need to add helper to find matching grasping part:

```zig
// body.zig - add to Body
pub fn graspingPartBySide(self: *const Body, side: Side) ?PartIndex {
    for (self.parts.items, 0..) |p, i| {
        if (p.flags.can_grasp and p.side == side) {
            return @intCast(i);
        }
    }
    return null;
}
```

Then in resolution:
```zig
const weapon_hand = attack.attacker.body.graspingPartBySide(attack.attacker.dominant_side);
if (weapon_hand) |hand_idx| {
    const grasp = attack.attacker.body.graspStrength(hand_idx);
    // ... apply penalties
}
```
