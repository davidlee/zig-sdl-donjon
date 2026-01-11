# Contested Rolls & Stance Triangle

> **Revision**: 2026-01-11. Design doc covering combat randomness overhaul
> (contested rolls replacing single-roll hit chance) and the stance triangle
> (pre-round attack/defense/movement weighting). Includes UI specification.

## Overview

This document covers two interconnected systems:

1. **Contested rolls** — Replace single hit-chance roll with attacker-score vs
   defender-score contest. Margin of success determines hit quality.

2. **Stance triangle** — Pre-round commitment to attack/defense/movement
   weighting. Weights modify contested roll scores.

## Current Random Rolls

### Attack (3 rolls)

**1. Hit/miss roll** — `src/domain/resolution/outcome.zig:155`
```zig
const roll = try w.drawRandom(.combat);
// ...
const outcome: Outcome = if (roll > final_chance) ...
```
`final_chance` is computed by `calculateHitChance()` (lines 67-131) combining:
- base 50%
- technique difficulty
- weapon accuracy
- stakes modifier
- engagement advantage (pressure/control/position)
- attacker balance
- attacker condition modifiers
- defender technique type (parry/block/deflect multipliers)
- defender guard height coverage
- defender weapon defensive stats
- defender balance
- defender condition dodge penalty

**2. Hit location roll** — `src/domain/resolution/height.zig:124`
```zig
const roll = try w.drawRandom(.combat);
// selects from exposure table based on attack height, guard coverage
```
Determines which body part is struck. Influenced by technique target height,
secondary height, and defender's guard position.

**3. Armour gap roll** — `src/domain/armour.zig:441`
```zig
const gap_roll = try w.drawRandom(.combat);
if (gap_roll < layer.totality.gapChance()) { ... }
```
Per-layer check. If roll < gap chance, attack bypasses that armour layer entirely.

### Defense (0 rolls)

Defense is currently **not a contest** — it's purely modifiers applied to the
attacker's hit chance:

- `defense_mult` from `CombatModifiers.forDefender()` (reduced by conditions)
- Guard height coverage (±0.05 to ±0.15)
- Defender weapon's parry stat
- Defender balance (low balance = easier to hit)
- Dodge modifier from conditions

No separate "defense roll" exists. The defender doesn't actively succeed or
fail — they just make the attacker's job harder or easier.

### Movement (1 roll)

**Positioning contest** — `src/domain/apply/effects/positioning.zig:117-118`
```zig
const variance = (rng.float(f32) - 0.5) * 0.2;
const adjusted_diff = differential + variance;
```

**BUG:** This uses `rng.float(f32)` directly from a `std.Random` parameter
rather than `world.drawRandom(.combat)`. Bypasses the world's random streams,
breaking reproducibility and event tracing.

The contest calculates scores from speed (0.3), position (0.4), balance (0.3),
minus standing-still penalty. The ±0.1 variance is then added to the score
differential to determine winner.

## Design Questions

### 1. Should defense be more "active"?

Current: defender modifies attacker's single roll.

Options:
- **Contested roll**: Both roll, compare. Multiple rolls regress toward the
  mean (central limit theorem) — actually *reduces* variance compared to single
  roll. Extremes become rarer; results cluster around expected value.
- **Threshold check**: Defender's "defense score" sets a bar the attack must
  clear by margin. Still one roll, but defense has sharper cliffs.
- **Resource spend**: Defender spends Focus/cards to boost defense. Active
  choice, not RNG.
- **Reactive timing**: Defender's guard/parry declared before attack resolves,
  creating read/counter-read without new rolls.

### 2. Should location & armour gap be in the triangle?

Currently these are pure RNG after hit is determined. Triangle options:

- **Location**: Triangle affects exposure table weights? Attack-weighted stance
  lets you "aim better" (tighter distribution around target zone)?
- **Armour gap**: Triangle affects gap chance? Seems odd thematically — your
  stance shouldn't affect whether armour has holes.
- **Neither**: These are downstream of the hit/miss decision. Triangle only
  affects the primary contest.

### 3. Is the current randomness the right randomness?

Observations:
- Attack has 3 RNG gates (hit, location, gap) — lots of variance stacking
- Defense has 0 RNG — deterministic modifiers only
- Movement has 1 RNG — small variance on score contest

Questions:
- Is 3 attack rolls too swingy? A lucky attacker can crit through armour; an
  unlucky one misses despite good position.
- Should movement contest have more RNG weight? Currently ±0.1 on scores that
  range ~0.3-1.0. Feels almost deterministic.
- The asymmetry (attack=random, defense=deterministic) — intentional? Feels
  like attacker has agency (chose to attack) while defender is reactive.

### 4. Triangle integration points

If the triangle modifies RNG success chances:

| Category | What to modify | How |
|----------|----------------|-----|
| Attack | `final_chance` in `calculateHitChance` | multiply by triangle factor |
| Defense | ??? | no roll exists; would need to create one OR boost `defense_mult` |
| Movement | score differential or variance | multiply differential by factor? |

The defense gap is the core problem. The triangle promises "defense RNG success
chance" but there's nothing to modify.

## Files Referenced

- `src/domain/resolution/outcome.zig` — hit/miss logic, `calculateHitChance`, `resolveOutcome`
- `src/domain/resolution/height.zig` — hit location selection
- `src/domain/armour.zig` — gap roll, absorption
- `src/domain/apply/effects/positioning.zig` — movement contest (has RNG bug)
- `src/domain/resolution/context.zig` — `CombatModifiers` computation
- `src/domain/random.zig` — random stream infrastructure

## Key Decision: Single Roll vs Contested Rolls

Two paths:
1. **Keep single roll** — result is a clean %, easy to present in combat logs
2. **Contested rolls** — both sides roll, reduces variance, but result is no
   longer a simple %. Would need to rebalance all formulas.

This choice has major game feel implications. Single roll = swingy, upsets
possible. Contested = predictable, skill dominates.

If contested, all contests (attack, defense, movement) should probably use the
same structure for consistency.

## Baseline Validation

To evaluate whether current formulas are sensible, test against baseline
scenario:

**Setup:** Equal skill opponents, both with knight's swords (TODO: define stats)

| Scenario | Expected Hit % |
|----------|----------------|
| a) Defender: deflect + sidestep | ~15% |
| b) Defender: sidestep only | ~40% |
| c) Defender: stationary, no active defense | ~75% |

Work backwards from these targets to validate formula weights.

## Current Hit Chance Formula

From `outcome.zig:calculateHitChance`:

```
chance = 0.5 (base)
       - technique.difficulty * 0.1
       + weapon.accuracy * 0.1
       + stakes.hitChanceBonus()
       + engagement_advantage_bonus (±0.15 based on position)
       + (attacker.balance - 0.5) * 0.2
       + attacker_condition_mods.hit_chance
       * defense_technique_mult (parry/block/deflect)
       * defender_condition_mods.defense_mult
       - guard_height_coverage (0.08-0.15 if covered)
       - defender_weapon.defence.parry * 0.1
       + (1.0 - defender.balance) * 0.15
       - defender_condition_mods.dodge_mod

clamped to [0.05, 0.95]
```

Note: some terms are additive, some multiplicative. The defense technique mult
is applied as a multiplier partway through, not at the end.

### Stationary penalty

From `context.zig:129-131`: if defender `is_stationary`, their `dodge_mod -= 0.10`,
making them +10% easier to hit.

### Data issue: sidestep doesn't help defense

From `techniques.cue`:
- **Sidestep**: `overlay_bonus.offensive.to_hit_bonus: 0.05` — helps the sidestepper hit, NOT avoid hits
- **Retreat**: `overlay_bonus.defensive.defense_bonus: 0.10` — actually helps avoid hits

This seems wrong — lateral movement should make you harder to hit.

### Code issue: weapon doesn't defend without active technique

From `outcome.zig:108-109`:
```zig
if (defense.technique) |def_tech| {
    // ... weapon parry only applied inside this block
```

The defender's weapon.defence.parry only applies if they have an active defense
technique. But in reality, holding a sword in front of you provides *passive*
defense — you'll opportunistically deflect even without committing to a parry.

Proposed fix: apply a baseline weapon defense contribution (perhaps at reduced
effectiveness, e.g. 0.5× the parry stat) regardless of active technique. Active
defense then provides *additional* benefit.

## Worked Baseline Calculations

Setup: Equal skill, both with knight's swords, swing attack, committed stakes.

Key values:
- technique.difficulty (swing): 1.0
- weapon.accuracy: 1.0
- stakes (committed): +0.15
- technique.deflect_mult (swing): 1.0
- technique.parry_mult (swing): 1.2
- defender weapon.defence.parry: 1.0
- deflect technique guard_height: mid, covers_adjacent: true
- swing target_height: high, secondary_height: mid

### Scenario C: Stationary, no active defense

```
chance = 0.50  (base)
       - 0.10  (technique difficulty 1.0 × 0.1)
       + 0.10  (weapon accuracy 1.0 × 0.1)
       + 0.15  (committed stakes)
       + 0.00  (equal engagement position)
       + 0.10  (attacker balance 1.0: (1.0-0.5) × 0.2)
       + 0.00  (no attacker condition mods)
       × 1.00  (no defense technique)
       - 0.00  (no guard coverage)
       - 0.00  (weapon parry only applies with active defense)
       + 0.00  (defender balance 1.0: (1-1) × 0.15)
       + 0.10  (stationary: dodge_mod = -0.10, subtracted = +0.10)
       ───────
       = 0.85  (clamped to 0.95)
```

**Result: 85%** — but we wanted ~75%. Currently too high.

### Scenario B: Sidestep only (no active defense)

Under current data, sidestep gives to_hit_bonus to the sidestepper (offensive),
not defense_bonus. If defender sidesteps, they're NOT stationary, so:

```
Same as C but:
       - 0.10  (NOT stationary, loses the +0.10 from dodge penalty)
       ───────
       = 0.75
```

**Result: 75%** — but we wanted ~40%. Way too high. Sidestep should help defense.

### Scenario A: Deflect + sidestep

```
Same as B but with deflect technique:
       × 1.00  (swing's deflect_mult = 1.0)
       - 0.15  (guard covers attack zone: high vs mid guard, mid is adjacent)
               Wait - deflect guard_height is mid, covers_adjacent: true
               swing target_height: high, secondary: mid
               → mid guard covers adjacent high: -0.08
       - 0.10  (defender weapon parry 1.0 × 0.1)
       ───────
       = 0.75 × 1.0 - 0.08 - 0.10 = 0.57
```

**Result: ~57%** — but we wanted ~15%. Way too high.

### Summary

| Scenario | Current | Target | Delta |
|----------|---------|--------|-------|
| C: Stationary, no defense | 85% | 75% | -10% |
| B: Sidestep only | 75% | 40% | -35% |
| A: Deflect + sidestep | 57% | 15% | -42% |

Active defense and movement currently have far too little impact.

## Recalculated with Proposed Fixes

Fixes applied:
1. Passive weapon defense at 0.5× parry stat (always, even without technique)
2. Sidestep gives defense_bonus: 0.15
3. Active defense multiplier applied more aggressively

### Scenario C: Stationary, no active defense (with passive weapon)

```
chance = 0.50  (base)
       - 0.10  (technique difficulty)
       + 0.10  (weapon accuracy)
       + 0.15  (committed stakes)
       + 0.10  (attacker balance)
       - 0.05  (passive weapon defense: 1.0 × 0.1 × 0.5)
       + 0.10  (stationary penalty)
       ───────
       = 0.80
```

Still too high (want 75%). Could lower base to 0.45 or increase passive weapon.

### Scenario B: Sidestep only (with defense_bonus fix)

```
       = 0.80 - 0.10 (not stationary) - 0.15 (sidestep defense_bonus)
       = 0.55
```

Closer but still too high (want 40%). Need sidestep ~0.30 or lower baseline.

### Scenario A: Deflect + sidestep

For deflect to matter, the multiplier needs to actually reduce:
- Current swing deflect_mult = 1.0 (no effect)
- Need swing deflect_mult ~0.5 to meaningfully reduce

```
If deflect_mult = 0.5:
       = 0.55 × 0.5 - 0.08 (guard) - 0.10 (active parry)
       = 0.275 - 0.18
       = 0.095
```

That's too low (want 15%). The multiplier is sensitive.

### Proposed tuning direction

| Parameter | Current | Proposed |
|-----------|---------|----------|
| Base chance | 0.50 | 0.45 |
| Passive weapon (no technique) | 0 | 0.5× parry stat |
| Sidestep defense_bonus | 0 | 0.15 |
| Swing deflect_mult | 1.0 | 0.6-0.7 |

This gets us in the right ballpark but needs iteration with actual tests.

## Current Movement Contest Formula

From `positioning.zig:calculateManoeuvreScore`:

```
score = (speed * 0.3) + (position * 0.4) + (balance * 0.3)
      - standing_still_penalty (0.3 if holding)

differential = aggressor_score - defender_score
variance = (random - 0.5) * 0.2  // ±0.1
adjusted_diff = differential + variance

outcome = aggressor_succeeds if adjusted_diff > 0.05
        = defender_succeeds if adjusted_diff < -0.05
        = stalemate otherwise
```

## Contested Rolls Design

### Why contested rolls

1. **Defender stats matter** — defending with a rapier, your speed/agility should
   count. Currently they don't unless you have an active defense technique.
2. **Richer combat logs** — distinguish "attack thwarted" (defender outrolled)
   vs "attack whiffed" (attacker failed)
3. **Degree of success** — margin feeds into lethality (see `partial_hits.md`).
   A scraped hit vs a solid connection should differ in damage.
4. **Natural distribution** — two rolls regress to mean. Most outcomes cluster
   around expected; outliers (devastating hits, miraculous saves) are rare but
   possible.
5. **Easier tuning** — compare two scores directly rather than tuning many
   additive/multiplicative coefficients.

### Basic structure

```
attacker_score = attack_base + (attack_roll × variance)
defender_score = defense_base + (defense_roll × variance)
margin = attacker_score - defender_score

if margin > 0: hit, margin determines quality
if margin ≤ 0: miss, |margin| determines how badly
```

Where:
- `attack_base` = technique + weapon accuracy + stance + conditions
- `defense_base` = technique + weapon parry + stance + movement + conditions
- `variance` = how much randomness swings the result (tunable)

### Outcome bands

| Margin | Outcome | Effect |
|--------|---------|--------|
| > +0.3 | Solid hit | Full damage, possible critical |
| +0.1 to +0.3 | Partial hit | Reduced damage (glancing, scraped) |
| -0.1 to +0.1 | Contested | Near-miss or minor contact |
| -0.3 to -0.1 | Evaded | Clean miss, defender in control |
| < -0.3 | Whiff | Attacker overextended, possible counter |

The bands turn continuous margin into discrete outcomes for game logic while
preserving the degree-of-success information.

### Score composition

**Attack score** (what helps you hit):
- Technique accuracy/difficulty
- Weapon offensive stats (accuracy, speed)
- Agent stats (skill, speed, perception?)
- Stance/triangle attack weighting
- Stakes commitment
- Engagement advantage (pressure, position)
- Conditions (adrenaline, focus)

**Defense score** (what helps you avoid):
- Defense technique (if any) — parry/deflect/block effectiveness
- Weapon defensive stats (parry, reach)
- Agent stats (speed, agility, perception?)
- Stance/triangle defense weighting
- Movement (sidestep, retreat bonuses)
- Conditions (not winded, not stunned)
- Passive "holding a weapon" baseline

### Combat log presentation

Instead of "72% chance to hit", show the contest:

```
Dwarf swings at Goblin
  Attack: 0.65 (swing +0.2, sword +0.1, committed +0.15, balanced +0.1)
  Defense: 0.48 (deflect +0.2, sword +0.1, sidestep +0.1)
  Roll: 0.71 vs 0.52 → margin +0.19
  Result: Partial hit (glancing blow)
```

The % isn't gone — you could still compute expected win rate from the score
differential — but the log shows the actual contest.

### Triangle integration

Triangle weights directly multiply the variance or base scores:

```
attack_score = attack_base × triangle.attack_weight + (roll × variance)
defense_score = defense_base × triangle.defense_weight + (roll × variance)
```

A pure-attack stance (triangle corner) might give:
- attack_weight: 1.3
- defense_weight: 0.7
- movement_weight: 0.7

Balanced (center) gives 1.0/1.0/1.0.

This makes the triangle's effect direct and visible: "I'm +30% attack, -30%
defense this round."

### Movement contest

Same structure applies to positioning:

```
aggressor_score = move_base × triangle.movement_weight + (roll × variance)
defender_score = move_base × triangle.movement_weight + (roll × variance)
margin = aggressor_score - defender_score
```

Movement base includes speed, balance, footwork technique, conditions.

### Design principle: visible tuning

All magic numbers (base values, variance magnitude, thresholds, weights) must be:
- Hoisted to a central config location
- Well-documented with expected effects
- Tunable in one place, not buried in calculation code

This applies to contested roll parameters AND all existing combat coefficients.

### Location: margin-of-success spending (future)

Hit location stays as a separate roll for now. Future goal: let attacker *spend*
margin-of-success to redirect the hit after resolution.

```
Example:
  Margin: +0.25 (partial hit to torso)
  Attacker elects to spend 0.15 MoS to move hit to neck
  Result: +0.10 margin (weaker hit, but to neck)
```

Cost weighted by proximity on the exposure chart — moving to an adjacent zone
is cheap, moving across the body is expensive. This creates meaningful choices:
"Do I take a solid torso hit, or gamble on a weaker neck hit?"

Deferred: needs exposure chart distance metrics and UI for post-resolution
election.

### Open questions

1. **Which stats contribute to each score?** — need to audit agent stats
2. **Partial hit damage scaling** — linear with margin? Stepped thresholds?
3. **Counter-attack on whiff** — how much advantage does defender gain?
4. **Armour interaction** — does margin affect armour penetration, or just
   damage after armour resolves?

## Stance Selection UI

### New TurnPhase

Add `stance_selection` before `draw_hand` in `src/domain/combat/types.zig`:

```zig
pub const TurnPhase = enum {
    stance_selection,      // NEW: choose attack/defense/movement weighting
    draw_hand,
    player_card_selection,
    commit_phase,
    tick_resolution,
    player_reaction,
    animating,
};
```

Turn flow becomes:
```
stance_selection → draw_hand → player_card_selection → commit_phase → ...
```

### Visual design

Replace timeline/card carousel area with stance selector.

Visual reference: the alchemical "Squaring the Circle" / Philosopher's Stone
symbol — triangle inscribed in circle inscribed in square. Fits the fantasy
aesthetic and provides natural visual hierarchy.

```
┌─────────────────────────────────────────────────────┐
│              "Choose Your Stance"                   │
│          ATK: 45%   DEF: 30%   POS: 25%             │
│         ┌─────────────────────────────┐             │
│         │         ╭───────╮           │             │
│         │        ╱ ⚔️      ╲          │             │
│         │       ╱ ATTACK   ╲         │             │
│         │      ╱     ╱╲     ╲        │             │
│         │     │     ╱  ╲     │       │             │
│         │     │    ╱ ●  ╲    │  ← cursor           │
│         │     │   ╱      ╲   │       │             │
│         │      ╲ ╱────────╲ ╱        │             │
│         │       🛡️         🦵         │             │
│         │    DEFENCE    POSITION     │             │
│         │        ╰────────╯          │             │
│         └─────────────────────────────┘             │
│                                                     │
│              [ Confirm Stance ]  ← greyed until locked
│                  (Space)                            │
└─────────────────────────────────────────────────────┘
```

Weights displayed as percentages, updating live as cursor moves.

Layers (back to front):
1. Square frame (outer boundary)
2. Circle (inscribed in square)
3. Triangle (inscribed in circle)
4. Cursor dot (inside triangle)
5. Vertex labels/icons (at triangle corners)

Icons at vertices:
- ⚔️ Sword (attack) — top
- 🛡️ Shield (defence) — bottom-left
- 🦵 Leg/boot (positioning) — bottom-right

### Cursor behaviour

Cursor **follows** mouse by default (no drag required — less fiddly).

Starts at centroid (balanced: 33%/33%/34%) but will move as soon as mouse
enters the triangle area.

1. **Mouse inside triangle**: cursor tracks mouse position exactly
2. **Mouse outside triangle**: cursor snaps to nearest point on triangle edge
3. **Click to lock**:
   - Cursor changes from hollow circle → filled circle
   - "Confirm Stance" button becomes visually active (no longer greyed)
   - Play a soft "lock" sound
   - Cursor stops following mouse
4. **Click again**: unlocks cursor, resumes following mouse, button greys out
5. **Space or button click**: confirms stance, transitions to `draw_hand`

### State stored

```zig
// In Agent or EncounterState
stance: struct {
    attack_weight: f32,    // 0.0-1.0, barycentric
    defense_weight: f32,
    movement_weight: f32,
    // Invariant: attack + defense + movement = 1.0
} = .{ .attack_weight = 0.33, .defense_weight = 0.33, .movement_weight = 0.34 },
```

Weights derived from cursor position using barycentric coordinates.

**Barycentric coordinates**: express a point inside a triangle as three weights
(λ₁, λ₂, λ₃) where λ₁ + λ₂ + λ₃ = 1. Each weight is the ratio of the sub-triangle
area (point + opposite edge) to the total triangle area.

- Vertex = (1, 0, 0) — 100% that axis
- Centroid = (⅓, ⅓, ⅓) — balanced
- Edge = one weight is 0, other two sum to 1

This gives us the stance weights directly: cursor position → barycentric → weights.

### UI state

Add to `CombatUIState` in `view_state.zig`:

```zig
stance_cursor: struct {
    position: ?[2]f32,  // null = centered, else normalized triangle coords
    locked: bool,
} = .{ .position = null, .locked = false },
```

### Implementation files

| File | Change |
|------|--------|
| `src/domain/combat/types.zig` | Add `stance_selection` to TurnPhase |
| `src/domain/combat/encounter.zig` | Initialize phase to `stance_selection` |
| `src/presentation/view_state.zig` | Add `stance_cursor` to CombatUIState |
| `src/presentation/views/combat/stance.zig` | NEW: stance triangle view |
| `src/presentation/views/combat/mod.zig` | Dispatch to stance view in phase |
| `src/domain/apply/phase_transitions.zig` | Handle stance → draw transition |

## Related Documents

- `doc/artefacts/geometry_momentum_rigidity_review.md` — the 3-axis physics
  rebalance. Weapon/armour definitions in cue are interactive with hit rolls;
  contested roll changes will need to consider how margin affects damage packet
  construction.

- `doc/ideas/stance_design.md` — compositional stance model for hit *location*
  (exposure, facing, height). Orthogonal to this doc: stance_design determines
  *where* you get hit, this doc determines *whether* you hit and with what
  quality. They interact at resolution time.

## Out of Scope (but related)

**High/Low modifier cards**: Currently can apply to some movement cards
simultaneous with the opposite on an attack, which is strange. These should be
able to apply to defensive moves too. Needs review, but not part of this work.

**Draw pile influence**: Does the triangle affect what you draw? Deferred until
we have more/richer options for draw cards. Leave as open question.

## Code Quality Actions

1. **Audit magic numbers**: Find constants buried in combat calculations that
   need hoisting to a central config with documentation. Examples:
   - Base hit chance (0.5)
   - Stat multipliers (0.1, 0.2, etc.)
   - Threshold values (stalemate_threshold, clamp bounds)
   - Variance magnitudes

2. **Audit random stream usage**: Find any direct `rng.float()` or `std.Random`
   calls that bypass `world.drawRandom()`. Known issue in `positioning.zig`.
   All combat randomness must go through world's random streams for
   reproducibility and event tracing.

3. **Update coding standards**: Add to agent documentation / CLAUDE.md:
   - All magic numbers must be named constants with doc comments
   - All combat RNG must use `world.drawRandom(stream_id)`
   - New constants should be grouped in a tuning config, not scattered

## Next Steps

1. [x] (T049) Fix `positioning.zig` to use `world.drawRandom(.combat)` instead of raw `rng`
2. [x] (T049) Audit codebase for magic numbers needing extraction
3. [x] (T049) Audit codebase for random stream bypasses
4. [x] (T050) Add `stance_selection` TurnPhase + provide mechanism for AI to randomly choose stance
5. [x] (T050) Implement stance triangle UI
6. Wire stance weights into contested roll formula
7. Prototype in tests: do baseline scenarios produce expected win rates?
8. Design partial hit damage scaling
9. Update combat log presentation