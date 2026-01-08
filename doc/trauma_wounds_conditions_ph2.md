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

**Goal**: ConditionIterator yields pain/trauma conditions at thresholds via data table.

**Architectural approach**: Use a table-driven structure instead of if-chains so future resources (morale, fatigue) hook in by adding rows.

**Changes**:

1. `damage.zig`: Add conditions to enum + penalties table (as before)

2. `damage.zig`: Add resource→condition threshold table:
```zig
pub const ResourceAccessor = enum { pain, trauma, blood, morale };

pub const ResourceConditionThreshold = struct {
    resource: ResourceAccessor,
    min_ratio: f32,      // condition active when ratio >= this
    condition: Condition,
};

/// Computed conditions from resource levels. Ordered worst-first per resource
/// so iterator yields only the most severe applicable condition.
pub const resource_condition_thresholds = [_]ResourceConditionThreshold{
    // Incapacitation (highest priority)
    .{ .resource = .pain, .min_ratio = 0.95, .condition = .incapacitated },
    .{ .resource = .trauma, .min_ratio = 0.95, .condition = .incapacitated },
    // Pain conditions (check worst first)
    .{ .resource = .pain, .min_ratio = 0.85, .condition = .agonized },
    .{ .resource = .pain, .min_ratio = 0.60, .condition = .suffering },
    .{ .resource = .pain, .min_ratio = 0.30, .condition = .distracted },
    // Trauma conditions (check worst first)
    .{ .resource = .trauma, .min_ratio = 0.90, .condition = .reeling },
    .{ .resource = .trauma, .min_ratio = 0.70, .condition = .trembling },
    .{ .resource = .trauma, .min_ratio = 0.50, .condition = .unsteady },
    .{ .resource = .trauma, .min_ratio = 0.30, .condition = .dazed },
};
```

3. `combat/agent.zig`: ConditionIterator loops over table instead of switch cases:
```zig
// In computed condition phase:
fn yieldResourceConditions(self: *ConditionIterator) ?ActiveCondition {
    var yielded_pain = false;
    var yielded_trauma = false;
    for (damage.resource_condition_thresholds) |rc| {
        // Skip if already yielded a condition for this resource
        if (rc.resource == .pain and yielded_pain) continue;
        if (rc.resource == .trauma and yielded_trauma) continue;

        const ratio = self.agent.getResourceRatio(rc.resource);
        if (ratio >= rc.min_ratio) {
            if (rc.resource == .pain) yielded_pain = true;
            if (rc.resource == .trauma) yielded_trauma = true;
            return .{ .condition = rc.condition, .expiration = .dynamic };
        }
    }
    return null;
}
```

**Tests**: Pain at 35% yields `.distracted`; trauma at 75% yields `.trembling`; 95% either → `.incapacitated`.

**Kanban**: T012

---

### Phase 4.4: Adrenaline

**Goal**: First significant wound triggers adrenaline surge → crash sequence.

**Architectural approach**: Model condition transitions as data; add "suppresses" field to condition effects.

**Changes**:

1. `damage.zig`: Add conditions + penalties:
```zig
.adrenaline_surge => .{ .hit_chance = 0.05 },
.adrenaline_crash => .{ .hit_chance = -0.10, .defense_mult = 0.85, .footwork_mult = 0.85 },
```

2. `damage.zig`: Add condition metadata table for transitions and suppression:
```zig
pub const ConditionMeta = struct {
    on_expire: ?Condition = null,      // condition to apply when this expires
    on_expire_duration: ?f32 = null,   // duration for successor condition
    suppresses: []const ResourceAccessor = &.{}, // resources whose conditions are suppressed
};

pub const condition_meta = init: {
    var table: [@typeInfo(Condition).@"enum".fields.len]ConditionMeta = .{.{}} ** ...;
    table[@intFromEnum(Condition.adrenaline_surge)] = .{
        .on_expire = .adrenaline_crash,
        .on_expire_duration = 12.0,
        .suppresses = &.{.pain},  // pain conditions suppressed while active
    };
    break :init table;
};
```

3. Condition expiry processing checks `on_expire` field and adds successor condition.

4. ConditionIterator checks if any active condition suppresses resource before yielding resource conditions.

**Tests**: First significant wound triggers surge; surge expiry triggers crash; pain suppressed during surge.

**Kanban**: T013

---

### Phase 4.5: Dud Cards Foundation

**Goal**: Card system supports blocking and forced-play mechanics via Rule/Effect pipeline.

**Architectural approach**: Extend existing Trigger union (don't replace with plain enum). Use existing TagSet bitmask. Model blocking via Rule/Predicate/Expression, not bespoke fields.

**Changes**:

1. `cards.zig`: Extend `Trigger` union with new cases:
```zig
pub const Trigger = union(enum) {
    on_play,
    on_draw,
    on_tick,
    on_event: EventTag,
    on_commit,
    on_resolve,
    while_in_hand,     // NEW: continuous effect while card is in hand
    on_play_attempt,   // NEW: fires when any card play is attempted
};
```

2. `cards.zig`: Extend `TagSet` with precision/finesse tags:
```zig
pub const TagSet = packed struct {
    // ... existing tags ...
    precision: bool = false,  // NEW: fine motor techniques
    finesse: bool = false,    // NEW: dexterous techniques
    involuntary: bool = false, // NEW: status/dud cards
};
```

3. `cards.zig`: Add `Effect.cancel_play` variant:
```zig
pub const Effect = union(enum) {
    // ... existing effects ...
    cancel_play,  // NEW: prevents the triggering play from resolving
};
```

4. Model blocking via Rule, not bespoke field:
```zig
// Tremor card blocks precision techniques while in hand:
const tremor_blocking_rule = Rule{
    .trigger = .on_play_attempt,
    .predicate = .{ .card_has_tag = .{ .precision = true } },
    .expressions = &.{.{ .effect = .cancel_play }},
};
```

5. Hand management: Check for `on_play_attempt` rules in hand before allowing play.

**Tests**: Forced card blocks voluntary play; blocking card prevents tagged techniques.

**Kanban**: T014

---

### Phase 4.6: Dud Card Definitions & Injection

**Goal**: Conditions inject dud cards into hand via event system.

**Architectural approach**: Condition gain emits event; dud cards subscribe via `Trigger.on_event`. This keeps injection declarative in card definitions.

**Changes**:

1. `events.zig`: Add condition gain event:
```zig
pub const EventTag = enum {
    // ... existing events ...
    condition_gained,
};
```

2. Define dud cards as Templates with appropriate rules:
```zig
pub const wince = Template{
    .id = .wince,
    .kind = .status,
    .tags = .{ .involuntary = true },
    .rules = &.{
        // Inject into hand when distracted condition gained
        Rule{
            .trigger = .{ .on_event = .condition_gained },
            .predicate = .{ .event_condition = .distracted },
            .expressions = &.{.{ .effect = .{ .move_card = .{ .to = .hand } } }},
        },
        // Exhaust on play
        Rule{
            .trigger = .on_play,
            .predicate = .always,
            .expressions = &.{.{ .effect = .exhaust_card }},
        },
    },
};

pub const tremor = Template{
    .id = .tremor,
    .kind = .status,
    .tags = .{ .involuntary = true },
    .rules = &.{
        // Inject on trembling condition
        Rule{
            .trigger = .{ .on_event = .condition_gained },
            .predicate = .{ .event_condition = .trembling },
            .expressions = &.{.{ .effect = .{ .move_card = .{ .to = .hand } } }},
        },
        // Block precision cards while in hand
        Rule{
            .trigger = .on_play_attempt,
            .predicate = .{ .card_has_tag = .{ .precision = true } },
            .expressions = &.{.{ .effect = .cancel_play }},
        },
        // Exhaust on play
        Rule{
            .trigger = .on_play,
            .predicate = .always,
            .expressions = &.{.{ .effect = .exhaust_card }},
        },
    },
};
```

3. Condition gain path emits `condition_gained` event; card system processes subscribed rules.

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

## Architectural Alignment Review

cards.zig already gives you a clean, data-first pipeline: a Template owns rules: []const
  Rule; each Rule couples a Trigger with a Predicate and one or more Expression { effect,
  filter, target }, and every gameplay mutation is supposed to flow through an Effect
  variant (combat_technique, move_card, add_condition, emit_event, etc.) (src/domain/
  cards.zig:71-420). With that in mind, here’s how the current phase‑2 plan and kanban
  tickets line up with the architecture goal of “logic as data”:

  - Keep the rule graph composable. Increment 4’s cards work (T014–T015) currently sketches
    new Trigger values and a bespoke blocks_tags array on your Card struct (doc/
    trauma_wounds_conditions_ph2.md, Dud Cards Addendum). The implementation needs to stay
    compatible with the existing Trigger union that can carry payload (on_event: EventTag)
    so rules can still subscribe to arbitrary combat events (src/domain/cards.zig:71-78).
    Add new cases like .while_in_hand or .forced, but don’t collapse the type to a plain
    enum as suggested in T014, or you’ll lose the ability to express future data-driven
    reactions to events. Likewise, instead of introducing a []const Tag member (which
    ignores the packed TagSet bitmask already in cards.zig:80-118 and even references tags
    such as .precision/.finesse that do not exist), prefer to model “this card blocks
    finesse attacks while held” using more of the existing data language: e.g. a Rule that
    fires .while_in_hand → Expression { effect = .cancel_play, target = .my_play, filter =
    Predicate.has_tag(...) } or a new Effect variant that marks restricted tags. That keeps
    the mechanic declarative and lets future cards reuse the same building blocks.
  - Push resource thresholds into data tables. The plan for pain/trauma conditions (doc
    Increment 4.3, T012) relies on hard-coded if chains inside ConditionIterator for each
    threshold, and adds more bespoke branches for adrenaline suppression (T013). That
    mirrors today’s sensory checks but scales poorly. Consider a small table of
    { resource_accessor, threshold, condition } rows and loop over it so the iterator stays
    data driven; the penalties already live in damage.condition_penalties, so hoist the
    thresholds too. You can also reuse Predicate.has_condition (src/domain/cards.zig:141-
    159) to expose these computed states to cards without writing one-off hooks later.
  - Let effects do the work. The Dud Cards plan injects special behavior directly into hand
    management (forced play ordering, blocking checks) and wires injections in
    Agent.addCondition. Those can be expressed via existing Effects so other systems can
    reuse them: e.g. condition gain emits an Event, and cards subscribe via a Rule with
    Trigger.on_event to Effect.move_card (inject), Effect.exhaust_card, or
    Effect.cancel_play to enforce forced sequencing. That keeps “conditions inject dud
    cards” in declarative card definitions rather than imperative if condition
    == .distracted ladders. Where a capability is missing (e.g. a true “forced priority” or
    “hand-level aura”), add a general-purpose effect and predicate so any future mechanic—
    not just pain—can reuse it.
  - Mind composability when extending stats/resources. T010/T011 correctly piggyback on
    stats.Resource (src/domain/stats.zig:10-69), but you’ll want helpers that match the
    existing API style instead of bespoke ratio math per caller (consider Resource.ratio()
    instead of adding three Agent methods). When you wire wounds to resources, prefer
    pluggable functions or data describing severity → delta rather than embedding exact
    switch tables inline; that way a future wound type or condition can reuse the same
    resource hooks without copy/paste.
  - Integrate with existing tags and targeting plans. T009 is already redefining targeting/
    primary focus. When Dud Cards plan to “block .precision cards,” make sure those tags
    exist (they currently don’t) or extend TagSet consistently so validators, predicates,
    and card templates all understand the new categories (src/domain/cards.zig:80-118).
    Otherwise you end up with another parallel tagging scheme living only in the hand
    validator.
  - Event/UX tickets (T016–T017) should consume the data graph, not reopen cases. Once pain/
    trauma/adrenaline are emitted as events through Effect.emit_event (src/domain/
    cards.zig:326) or equivalent, both the combat log and UI can stay thin layers that
    subscribe to events and query ConditionIterator. Avoid duplicating condition logic in
    presentation code; instead expose descriptive data (condition name, duration, associated
    card injections) so the UI doesn’t have to guess.

  If you reshape the Increment 4 work so that new behaviors are described via Rule/
  Predicate/Effect nodes (with small, reusable extensions where absolutely necessary) rather
  than bespoke if blocks, the whole trauma/pain/dud pipeline will plug straight into the
  existing composable architecture and keep the “logic as data” promise. Natural next steps:
  1) revise T014/T015 acceptance criteria so they explicitly require using the rule/effect
  pipeline (and update the doc snippets accordingly), and 2) sketch a table-driven structure
  for computed conditions before implementing T012/T013 so future resources (morale,
  fatigue, etc.) can hook in by just adding rows.