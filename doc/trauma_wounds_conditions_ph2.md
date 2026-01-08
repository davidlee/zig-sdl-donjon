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

### Increment 2 Progress: ✓ Complete

**DONE:**
- `agent.zig`: Extended `ConditionIterator` with phases 4-5 for sensory conditions
  - Phase 4: `.blinded` when `body.visionScore() < 0.3`
  - Phase 5: `.deafened` when `body.hearingScore() < 0.3`
  - Shifted engagement phases to 6-7
  - Changed `computed_phase` from `u3` to `u4` to accommodate 8 phases
- `damage.zig`: Added `.deafened` penalty (`defense_mult = 0.9`)
- `agent.zig`: Added tests for computed sensory conditions (~line 435-489)
- Build passes, all tests pass

**Notes:**
- `.blinded` retains special-case handling in `forAttacker()` for attack-mode-specific penalties
- Sensory thresholds (< 0.3) match design doc specification

### Increment 3 Progress: ✓ Complete

**DONE:**
- `context.zig`: Extended `forAttacker()` with grasp strength penalty
  - Uses `body.graspingPartBySide(dominant_side)` to find weapon hand
  - Applies `(1-grasp)*-0.25` hit_chance and `0.5 + grasp*0.5` damage_mult
- `context.zig`: Extended `forDefender()` with mobility penalty
  - Uses `body.mobilityScore()` to assess leg damage
  - Applies `(1-mobility)*-0.30` dodge_mod
- `context.zig`: Added tests for wound penalties (~line 545-610)
- Build passes, all tests pass

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

---

## Addendum: Revised Increment 4 (Pain & Trauma Model)

**Supersedes original Increment 4 above.**

### Conceptual Model

Three orthogonal damage axes, each a `stats.Resource`:

| Resource | Represents | Primary Inputs | Effects |
|----------|-----------|----------------|---------|
| **Blood** | Circulatory capacity | Wound bleeding | Shock, syncope, death |
| **Pain** | Sensory overload | Wound severity × sensitivity | Attention capture, guarding |
| **Trauma** | Neurological stress | Sudden wounds, head hits | Motor/cognitive impairment |
| **Morale** | Psychological state | (Future: witnessing, odds, reputation) | Fear, flight, surrender |

**Key distinction**: Pain is about *hurting*. Trauma is about *system disruption*. Fear is about *will to fight*.

### Resource Definitions

```zig
// Agent struct additions
pain: stats.Resource,      // init(0.0, 10.0, 0.0) - accumulates, no natural recovery in combat
trauma: stats.Resource,    // init(0.0, 10.0, 0.0) - accumulates, no natural recovery in combat
morale: stats.Resource,    // init(10.0, 10.0, 0.0) - starts full, drains (stub for future)
```

### Wound → Resource Mapping

```zig
fn painFromWound(wound: Wound, part: PartDef) f32 {
    const base: f32 = switch (wound.worstSeverity()) {
        .none => 0,
        .minor => 0.3,
        .inhibited => 1.0,
        .disabled => 2.5,
        .broken => 4.0,
        .missing => 5.0,
    };
    return base * part.trauma_mult;  // reuse existing sensitivity field
}

fn traumaFromWound(wound: Wound, part: PartDef, hit_artery: bool) f32 {
    const base: f32 = switch (wound.worstSeverity()) {
        .none => 0,
        .minor => 0.2,
        .inhibited => 0.5,
        .disabled => 1.5,
        .broken => 3.0,
        .missing => 4.0,
    };
    var t = base * part.trauma_mult;
    if (hit_artery) t += 1.5;
    return t;
}
```

**Note**: Using `trauma_mult` for both is a simplification. Could split into `pain_sensitivity` / `neurological_sensitivity` later.

### Incapacitation

When pain OR trauma reaches 95%, agent collapses:

```zig
// ConditionIterator, highest priority check:
if (pain.ratio() >= 0.95 or trauma.ratio() >= 0.95) {
    return .incapacitated;
}
```

Three ways to lose a fight:
- **Death**: blood depleted
- **Incapacitation**: pain or trauma overwhelms
- **Surrender**: morale breaks (future)

### Conditions (Thresholds)

**Pain conditions** (attention/focus effects):

| Threshold | Condition | Primary Effect |
|-----------|-----------|----------------|
| 30% | `.distracted` | Initiative penalty, injects `Wince` |
| 60% | `.suffering` | Global penalties, injects `Retch` |
| 85% | `.agonized` | Severe penalties, collapse risk |

**Trauma conditions** (motor/cognitive effects):

| Threshold | Condition | Primary Effect |
|-----------|-----------|----------------|
| 30% | `.dazed` | Mild cognitive penalty |
| 50% | `.unsteady` | Footwork degraded, injects `Stagger` |
| 70% | `.trembling` | Fine motor degraded, injects `Tremor` |
| 90% | `.reeling` | Near-collapse, injects `Blackout` |

### Penalty Table Additions

```zig
// Pain conditions
.distracted => .{ .defense_mult = 0.95, .hit_chance = -0.05 },
.suffering => .{ .defense_mult = 0.85, .hit_chance = -0.15, .damage_mult = 0.9 },
.agonized => .{ .defense_mult = 0.70, .hit_chance = -0.30, .damage_mult = 0.7, .dodge_mod = -0.2 },

// Trauma conditions
.dazed => .{ .hit_chance = -0.10, .defense_mult = 0.95 },
.unsteady => .{ .footwork_mult = 0.7, .dodge_mod = -0.15 },
.trembling => .{ .hit_chance = -0.10, .damage_mult = 0.8 },
.reeling => .{ .footwork_mult = 0.4, .hit_chance = -0.25, .defense_mult = 0.7, .dodge_mod = -0.25 },
```

### Adrenaline (Condition Sequence)

Applied on first significant wound:

```zig
// When first wound of severity >= .inhibited:
if (!agent.hasCondition(.adrenaline_surge) and !agent.hasCondition(.adrenaline_crash)) {
    agent.addCondition(.adrenaline_surge, .{ .ticks = 8 });
}

// When .adrenaline_surge expires:
agent.addCondition(.adrenaline_crash, .{ .ticks = 12 });
```

```zig
.adrenaline_surge => .{ .hit_chance = 0.05 },  // + suppresses pain conditions
.adrenaline_crash => .{ .hit_chance = -0.10, .defense_mult = 0.85, .footwork_mult = 0.85 },
```

**Pain suppression**: While `.adrenaline_surge` active, skip pain condition phases in iterator. Pain still accumulates; just doesn't manifest until surge ends.

---

## Addendum: Dud Cards Mechanic

### Concept

Conditions inject "dud" cards into the hand rather than (or in addition to) applying numeric penalties. This:
- Makes impairment visible and tactical
- Uses existing card/tag systems
- Creates emergent hand-clogging under multiple conditions

### New Trigger Types

```zig
pub const Trigger = enum {
    on_play,
    on_discard,
    start_of_turn,
    end_of_turn,
    while_in_hand,  // continuous effect while held
    forced,         // must play before voluntary cards
};
```

### Card Blocking

```zig
pub const Card = struct {
    // ... existing fields ...
    blocks_tags: []const Tag = &.{},  // prevents playing cards with these tags while in hand
};
```

### Dud Card Definitions

| Card | Injected By | Behavior |
|------|-------------|----------|
| `Wince` | `.distracted` | Occupies slot. Exhaust on play (wastes action). |
| `Retch` | `.suffering` | Forced (must play before others). Exhaust. |
| `Stagger` | `.unsteady` | Occupies slot. Exhaust on play. |
| `Tremor` | `.trembling` | `blocks_tags: {.precision, .finesse}`. Exhaust on play. |
| `Blackout` | `.reeling` | Forced. Ends turn immediately. Exhaust. |

### Lifecycle

1. **Injection**: On condition gain, inject corresponding dud card into hand
2. **Persistence**: Duds cycle through hand/discard like normal cards until played
3. **Removal**: Exhaust on play (removed from game), OR discarded via another card effect
4. **Stacking**: Each condition gain injects one card (can accumulate multiple)

### Example: Tremor Card

```zig
const tremor = Card{
    .name = "Tremor",
    .tags = &.{.involuntary, .status},
    .blocks_tags = &.{.precision, .finesse},
    .trigger = .while_in_hand,  // blocking effect active while held
    .exhaust = true,
    .effects = &.{},  // playing it does nothing except remove it
};
```

### Design Decisions

- **Injection timing**: On condition gain (may revisit after playtesting)
- **Forced cards**: Must play before voluntary cards, not "immediately loses turn"
- **Blocking**: Only while in hand; discarding clears the block
- **No special cases**: All behavior defined via existing card/effect/trigger systems

---

## Files Summary (Revised)

| Increment | Files Modified |
|-----------|----------------|
| 1 | `body.zig`, `positioning.zig` |
| 2 | `combat/agent.zig`, `damage.zig` |
| 3 | `resolution/context.zig` |
| 4 | `combat/agent.zig` (pain/trauma/morale resources, ConditionIterator), `damage.zig` (conditions + penalties), damage path, card definitions (dud cards), `Trigger` enum |

---

## Tactical Implications

| Wound Type | Blood | Pain | Trauma | Tactical Meaning |
|------------|-------|------|--------|------------------|
| Arterial neck | High | Med | High | Rapid collapse, disoriented |
| Joint hyperextension | Low | High | Low | Functional but hand full of Winces |
| Pommel to temple | Low | Low | High | Tremor blocks precision, Stagger clogs hand |
| Shallow cuts × 5 | Low | Med | Med | Gradual hand degradation |
| Clean amputation | Med | High→Low | High | Adrenaline delays pain cards |

**Targeting choices**:
- Head → trauma (motor impairment, blocking cards)
- Hands/joints → pain (attention capture, forced plays)
- Limbs → mobility + blood
- Torso → blood (kill)

---

## Increment 4: Implementation Phases

### Phase 4.1: Resource Scaffolding

**Goal**: Add pain, trauma, morale Resources to Agent; not wired up yet.

**Changes**:
- `combat/agent.zig`: Add `pain`, `trauma`, `morale` fields to Agent struct
- Initialize: `pain/trauma = init(0.0, 10.0, 0.0)`, `morale = init(10.0, 10.0, 0.0)`
- Add `painRatio()`, `traumaRatio()`, `moraleRatio()` helpers

**Tests**: Resources exist, can be damaged, ratios compute correctly.

**Kanban**: T010

---

### Phase 4.2: Wound → Resource Wiring

**Goal**: Wounds generate pain and trauma based on severity and body part.

**Changes**:
- Add `painFromWound()`, `traumaFromWound()` functions (location TBD - likely `damage.zig` or `body.zig`)
- Wire into damage application path (where wounds are created)
- Use `part.trauma_mult` for sensitivity

**Tests**: Wound to hand generates more pain than wound to torso; arterial hit adds trauma.

**Kanban**: T011

---

### Phase 4.3: Pain & Trauma Conditions

**Goal**: ConditionIterator yields pain/trauma conditions at thresholds.

**Changes**:
- `damage.zig`: Add conditions to enum: `.distracted`, `.suffering`, `.agonized`, `.dazed`, `.unsteady`, `.trembling`, `.reeling`, `.incapacitated`
- `damage.zig`: Add penalties to `condition_penalties` table
- `combat/agent.zig`: Extend ConditionIterator with pain phases (8-10) and trauma phases (11-14)
- Incapacitation check: `pain.ratio() >= 0.95 or trauma.ratio() >= 0.95`

**Tests**: Pain at 35% yields `.distracted`; trauma at 75% yields `.trembling`; 95% either → `.incapacitated`.

**Kanban**: T012

---

### Phase 4.4: Adrenaline

**Goal**: First significant wound triggers adrenaline surge → crash sequence.

**Changes**:
- `damage.zig`: Add `.adrenaline_surge`, `.adrenaline_crash` conditions + penalties
- Damage application: On first wound ≥ `.inhibited`, add `.adrenaline_surge` (8 ticks)
- Condition expiry handling: When surge expires, add `.adrenaline_crash` (12 ticks)
- ConditionIterator: Skip pain condition phases while `.adrenaline_surge` active

**Tests**: First significant wound triggers surge; surge expiry triggers crash; pain suppressed during surge.

**Kanban**: T013

---

### Phase 4.5: Dud Cards Foundation

**Goal**: Card system supports blocking and forced-play mechanics.

**Changes**:
- Add `Trigger.while_in_hand`, `Trigger.forced` to trigger enum
- Add `blocks_tags: []const Tag` field to Card struct
- Hand management: Forced cards must be played before voluntary cards
- Hand management: Cards with `blocks_tags` prevent playing matching cards

**Tests**: Forced card blocks voluntary play; blocking card prevents tagged techniques.

**Kanban**: T014

---

### Phase 4.6: Dud Card Definitions & Injection

**Goal**: Conditions inject dud cards into hand.

**Changes**:
- Define dud cards: `Wince`, `Retch`, `Stagger`, `Tremor`, `Blackout`
- Condition gain triggers card injection (where conditions are added)
- Cards exhaust on play

**Tests**: Gaining `.distracted` injects Wince; Tremor blocks `.precision` cards; playing dud exhausts it.

**Kanban**: T015

---

## Dependencies

```
T010 (resources)
  → T011 (wound wiring)
    → T012 (conditions)
      → T013 (adrenaline)

T014 (dud foundation) → T015 (dud cards)

T012 + T015 can be integrated once both complete
```
