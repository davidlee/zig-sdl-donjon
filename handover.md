# Handover: Combat Resolution System

## Project Overview

**Sodul** is a card-based tactical combat game in Zig, inspired by Slay the Spire but with a focus on realistic wound mechanics and simultaneous commitment resolution (both sides declare actions, then resolve together).

Key design principles:
- **Not HP grinding** — combat is about creating openings for decisive strikes
- **Simultaneous commitment** — 1-second ticks, both sides commit, both resolve
- **Severe wound system** — landing clean is nearly fight-ending
- **Advantage accumulation** — pressure, control, position, balance

## Recommended Reading

### Core Files (read in order)

1. **`doc/combat_design.md`** — Design document with core loop, stamina economy, card lifecycle, mob model
2. **`src/combat.zig`** — `Agent`, `Engagement`, `Encounter`, `Reach` definitions
3. **`src/resolution.zig`** — NEW: outcome determination, advantage effects, damage creation (just created)
4. **`src/cards.zig`** — `Technique`, `Stakes`, `Predicate`, card structures
5. **`src/weapon.zig`** — `Offensive`/`Defensive` profiles, weapon templates
6. **`src/armour.zig`** — Layer-based armor resolution with gap/deflection/penetration
7. **`src/damage.zig`** — `Packet`, damage types, resistance/vulnerability
8. **`src/apply.zig`** — `CommandHandler`, `EventProcessor` (command/event separation)
9. **`src/events.zig`** — Event types and double-buffered event system

### Skip (too large, already working)
- `src/body.zig` — Wound system, body parts, severing. Works. Emits its own events.

## Key Design Decisions Made

### Advantage Model

Advantage is split into **relational** (per-engagement) and **intrinsic** (per-agent):

```zig
// Per-engagement (stored on mob, relative to player)
pub const Engagement = struct {
    pressure: f32 = 0.5,  // who's pushing whom
    control: f32 = 0.5,   // blade position/initiative
    position: f32 = 0.5,  // spatial advantage
    range: Reach = .far,
};

// Per-agent (intrinsic)
Agent.balance: f32  // 0-1, physical stability
```

- Values are 0-1, where 0.5 = neutral
- >0.5 = player advantage, <0.5 = mob advantage
- Balance affects ALL engagements (it's intrinsic)
- Engagement is per-opponent (can be winning vs A, losing vs B)

### Stakes (Commitment)

```zig
pub const Stakes = enum {
    probing,    // Low risk, low reward
    guarded,    // Standard
    committed,  // Higher damage, higher penalty on miss
    reckless,   // Maximum damage, severe penalty on miss
};
```

Stakes scale both advantage effects and damage.

### Resolution Flow

```
1. calculateHitChance(attack, defense) → f32
   - technique difficulty
   - weapon accuracy
   - stakes modifier
   - engagement advantage
   - attacker/defender balance

2. resolveOutcome(world, attack, defense) → Outcome
   - hit, miss, blocked, parried, deflected, dodged, countered

3. getAdvantageEffect(outcome, stakes) → AdvantageEffect
   - pressure/control/position/balance deltas
   - scaled by stakes

4. createDamagePacket(technique, weapon, attacker, stakes) → damage.Packet
   - base from technique
   - scaled by stats
   - scaled by weapon
   - scaled by stakes

5. armour.resolveThroughArmourWithEvents(...) → AbsorptionResult
   - gap chance, hardness deflection, resistance thresholds
   - emits events

6. body.applyDamageToPart(...) → DamageResult
   - creates wounds, handles severing
   - emits events for bleeding, severing, etc.
```

### Weapon Modifiers

Weapons have `Offensive` profiles (for swing/thrust) with:
- accuracy, speed, damage, penetration
- `defender_modifiers: Defensive` — how hard to parry/block/deflect

And `Defensive` profile with parry/deflect/block multipliers.

These feed into `calculateHitChance`.

## Current State

### Working
- `resolution.zig` created and compiling
- All 71 tests passing (23 body + 48 resolution)
- Armor resolution complete with events
- Body/wound system complete with events
- Card playing and event system working
- Agent/Engagement structures in place
- Resolution events: `technique_resolved`, `advantage_changed` (Step 1 complete)
- Integration tests verifying full resolution flow (Step 2 complete)

### Stubbed/TODO in resolution.zig
- `selectHitLocation` — simple random, needs technique/engagement weighting
- No technique-specific advantage overrides yet
- Not wired into game loop

## Implementation Plan

### Step 1: Add Resolution Events ✓ COMPLETE

Added to `src/events.zig`:

```zig
technique_resolved: struct {
    attacker_id: entity.ID,
    defender_id: entity.ID,
    technique_id: cards.TechniqueID,
    outcome: resolution.Outcome,
},

advantage_changed: struct {
    agent_id: entity.ID,
    engagement_with: ?entity.ID, // null for intrinsic (balance)
    axis: combat.AdvantageAxis,
    old_value: f32,
    new_value: f32,
},
```

- Added `engagement_with` field to distinguish relational vs intrinsic changes
- `AdvantageEffect.applyWithEvents()` emits per-axis events
- `resolveTechniqueVsDefense()` emits `technique_resolved` after resolution

### Step 2: Wire Resolution into Harness ✓ COMPLETE

Added integration tests in `src/resolution.zig`:
- `test "resolveTechniqueVsDefense emits technique_resolved event"`
- `test "resolveTechniqueVsDefense emits advantage_changed events on hit"`
- `test "resolveTechniqueVsDefense applies damage on hit"`
- `test "AdvantageEffect.apply modifies engagement and balance"`
- `test "createDamagePacket scales by stakes"`

Test fixtures:
- `TestWeapons.sword` - longsword template with swing/thrust/defence profiles
- `makeTestWorld()` - creates World with events, player, agents
- `makeTestAgent()` - creates AI/player agent with deck, body, armour

Build system updated (`build.zig`) to run both `body.zig` and `resolution.zig` test modules.

Bug fixes required:
- `Agent.init` - armour was `undefined`, now properly initialized
- `Agent.deinit` - now deinits body, armour, and destroys self
- `World.deinit` - removed redundant `player.deinit()` (player in agents list)
- Various type visibility (`Director`, `applyDamageToPart`, `RandomStreamDict.get`)
- Slice types fixed to `[]const` for comptime array coercion

### Step 3: Technique-Specific Advantage Profiles

Option A: Add to `cards.Technique`:
```zig
pub const Technique = struct {
    // existing fields...

    advantage: ?TechniqueAdvantage = null,  // override defaults
};

pub const TechniqueAdvantage = struct {
    on_hit: ?AdvantageEffect = null,
    on_miss: ?AdvantageEffect = null,
    on_blocked: ?AdvantageEffect = null,
    // etc.
};
```

Option B: Lookup table by `TechniqueID` in resolution.zig.

Update `getAdvantageEffect` to check for technique-specific overrides.

### Step 4: Hit Location Weighting

Enhance `selectHitLocation`:

1. Technique weighting (thrust → torso/head, swing → arms/torso)
2. Engagement weighting (flanking → back, position advantage → gaps)
3. Weapon reach interaction (inside spear range → different targets)

Consider adding to `Technique`:
```zig
hit_weights: ?[]const struct { tag: body.PartTag, weight: f32 } = null,
```

### Step 5: Simultaneous Resolution Loop

The core game loop needs to:

1. **Commit phase**: Collect player cards + mob actions for this tick
2. **Sort by time**: Actions happen in 0.1s increments within the tick
3. **Resolve in order**: For each 0.1s slice:
   - Determine interactions (RPS: strike vs block, etc.)
   - Call `resolveTechniqueVsDefense` for each
   - Handle interrupts/reactions
4. **Apply costs**: Stamina, time, card exhaustion
5. **Emit summary events**

This is the most complex step. Consider:
- A `TickResolver` struct that accumulates committed actions
- Sorting by `card.template.cost.time`
- Processing in time slices

### Step 6: Defense Technique Selection

Currently `DefenseContext.technique` is null (passive defense). Need:

1. Mob AI to select defensive technique based on behavior pattern
2. Player reaction system (if they have reaction cards)
3. Default passive defense if no active defense

### Step 7: Threshold Effects

When advantage crosses thresholds, trigger qualitative changes:

```zig
pub fn checkThresholds(engagement: *Engagement, attacker: *Agent, defender: *Agent) void {
    if (engagement.pressure > 0.8) {
        defender.addState(.pressured);
    }
    if (engagement.control < 0.2) {
        attacker.addState(.blade_bound);
    }
    if (defender.balance < 0.2) {
        defender.addState(.staggered);
    }
}
```

This likely needs a `CombatState` system added to `Agent`.

## Testing Strategy

1. **Unit tests in resolution.zig**: Advantage scaling, hit chance bounds
2. **Integration tests in harness.zig**: Full resolution flow with mock agents
3. **Armor/body tests**: Already exist and passing

Run tests with:
```bash
zig build test --summary all
```

## Notes for Next Agent

- The user prefers compact, professional communication
- Quality over speed; obsess over coupling/cohesion
- TDD/BDD approach; lint after compile
- 2-space indentation
- Update kanban task cards per `kanban/CLAUDE.md` conventions
- Check `~/.claude/CLAUDE.md` for global instructions

## Files Modified This Session

- Created: `src/resolution.zig`
- Modified: `src/main.zig` (added resolution import)
- Modified: `src/events.zig` (added `technique_resolved`, `advantage_changed` events)
- Modified: `src/resolution.zig` (added `applyWithEvents`, integration tests, test fixtures)
- Modified: `src/combat.zig` (pub Director, fixed Agent.init armour, Agent.deinit cleanup)
- Modified: `src/body.zig` (pub applyDamageToPart)
- Modified: `src/random.zig` (pub RandomStreamDict.get)
- Modified: `src/world.zig` (fixed double-deinit bug in World.deinit)
- Modified: `src/armour.zig` ([]const for Material/Pattern slices)
- Modified: `src/weapon.zig` ([]const for damage_types, categories)
- Modified: `src/cards.zig` (inline for, @tagName for compileError)
- Modified: `build.zig` (added resolution.zig test module)

## Open Design Questions

1. Should footwork techniques be "overlays" that combine with arm techniques?
2. How does commitment get chosen — per-card or per-tick?
3. Reaction timing — can you react to reactions?
4. Stance as continuous value vs discrete states?
5. Range model — per-engagement or global positioning?

See `doc/combat_design.md` section "Open Questions" for more.
