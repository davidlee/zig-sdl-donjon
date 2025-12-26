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
- `tick.zig` created with full resolution loop
- All 64 tests passing (body + resolution + weapon_list + tick + armour + damage)
- Armor resolution complete with events
- Body/wound system complete with events
- Card playing and event system working
- Agent/Engagement structures in place
- Resolution events: `technique_resolved`, `advantage_changed` (Step 1 complete)
- Integration tests verifying full resolution flow (Step 2 complete)
- Weapon templates: 8 melee weapons in `weapon_list.zig` with realistic stats
- Technique-specific advantage profiles (Step 3 complete)
- Hit location weighting with height targeting (Step 4 complete)

### Stubbed/TODO
- Not wired into game loop
- Compositional stance system (see `doc/stance_design.md`) — deferred, MVP uses static exposure tables

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

### Step 3: Technique-Specific Advantage Profiles ✓ COMPLETE

Implemented Option A with types in `combat.zig`:

```zig
// combat.zig
pub const AdvantageEffect = struct {
    pressure: f32 = 0,
    control: f32 = 0,
    position: f32 = 0,
    self_balance: f32 = 0,
    target_balance: f32 = 0,
    // apply(), scale() methods
};

pub const TechniqueAdvantage = struct {
    on_hit: ?AdvantageEffect = null,
    on_miss: ?AdvantageEffect = null,
    on_blocked: ?AdvantageEffect = null,
    on_parried: ?AdvantageEffect = null,
    on_deflected: ?AdvantageEffect = null,
    on_dodged: ?AdvantageEffect = null,
    on_countered: ?AdvantageEffect = null,
};

// cards.zig - Technique now has:
advantage: ?combat.TechniqueAdvantage = null,
```

`getAdvantageEffect(technique, outcome, stakes)` now:
1. Checks technique-specific override first
2. Falls back to defaults per-outcome if no override
3. Scales result by stakes

Example technique with override (feint in `card_list.zig`):
```zig
.advantage = .{
    .on_hit = .{ .pressure = 0.05, .control = 0.25 },  // high control, low pressure
    .on_miss = .{ .control = -0.05, .self_balance = -0.02 },  // minimal penalty
},
```

Bug fix: `deflect` technique had wrong id (`.swing` → `.deflect`).

### Step 4: Hit Location Weighting ✓ COMPLETE

MVP height-based targeting system implemented:

**Added to `body.zig`:**
- `Height` enum `{ low, mid, high }` with `adjacent()` method
- `Exposure` struct with tag, side, base_chance, height
- `humanoid_exposures` static table (31 entries across all heights)

**Added to `cards.zig` Technique:**
- `target_height: Height = .mid` — primary attack zone
- `secondary_height: ?Height = null` — for attacks spanning zones (e.g., swing high→mid)
- `guard_height: ?Height = null` — defense guard position
- `covers_adjacent: bool = false` — whether guard covers adjacent heights

**Updated `resolution.zig`:**
- `selectHitLocationFromExposures()` — pure function with height weighting
- `getHeightMultiplier()` — primary (2x), secondary (1x), adjacent (0.5x), off-target (0.1x)
- Defense coverage reduces guarded zone hit chance (0.3x direct, 0.6x adjacent)
- `calculateHitChance()` now includes height coverage in hit chance calculation

**Updated techniques in `card_list.zig`:**
- `thrust`: targets mid
- `swing`: targets high, secondary mid
- `feint`: targets high
- `deflect`: guards mid, covers adjacent
- `parry`: guards high
- `block`: guards mid, covers adjacent

5 new tests for height targeting logic.

**Deferred:**
- Compositional stance synthesis (grip + arm + body contributions) — see `doc/stance_design.md`
- Relative angle / flanking
- Attack arc (overhead/level/rising)
- L/R side preference

### Step 5: Simultaneous Resolution Loop ✓ COMPLETE

**Implementation in `src/tick.zig`:**

```zig
// Core types
pub const CommittedAction = struct {
    actor: *Agent,
    card: ?*cards.Instance,  // null for pool-based mobs
    technique: *const Technique,
    stakes: Stakes,
    time_start: f32,  // 0.0-1.0 within tick
    time_end: f32,
};

pub const TickResolver = struct {
    // Methods:
    commitPlayerCards()   // extract from deck.in_play
    commitMobActions()    // use TechniquePool.selectNext()
    resolve()             // pair attacks with defenses, call resolution
    cleanup()             // deduct costs, move cards, apply cooldowns
    resetForNextTick()    // reset agent resources
};
```

**Key additions:**
- `TechniquePool.selectNext()` — round-robin selection with cooldown check
- `apply.evaluateTargets()` — resolve TargetQuery to agent list
- `World.processTick()` — orchestrates full tick cycle
- FSM: `player_card_selection` → `tick_resolution` → `player_reaction`
- Event: `tick_ended`

**Resolution flow:**
1. Offensive actions identified by `card.template.tags.offensive`
2. Targets resolved via `TargetQuery` (`.all_enemies`, `.self`, etc.)
3. Defender's active defense found by time window overlap
4. `resolution.resolveTechniqueVsDefense()` called for each pair

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

- Created: `src/tick.zig` (TickResolver, CommittedAction, resolution loop)
- Created: `doc/step5_plan.md` (full implementation plan for tick resolution loop)
- Created: `src/resolution.zig`
- Modified: `src/world.zig` (added tickResolver, processTick(), FSM states)
- Modified: `src/combat.zig` (added TechniquePool.selectNext())
- Modified: `src/apply.zig` (added evaluateTargets())
- Modified: `src/events.zig` (added tick_ended event)
- Created: `src/weapon_list.zig` (8 weapon templates: horseman's mace, footman's axe, greataxe, knight's sword, falchion, dirk, spear, buckler)
- Created: `doc/stance_design.md` (full stance system design, compositional model)
- Modified: `src/main.zig` (added resolution, weapon_list imports)
- Modified: `src/events.zig` (added `technique_resolved`, `advantage_changed` events)
- Modified: `src/resolution.zig` (added `applyWithEvents`, integration tests, height-weighted `selectHitLocation`)
- Modified: `src/combat.zig` (pub Director, fixed Agent.init armour, Agent.deinit cleanup, added AdvantageEffect+TechniqueAdvantage)
- Modified: `src/body.zig` (pub applyDamageToPart, added Height enum, Exposure struct, humanoid_exposures table)
- Modified: `src/cards.zig` (added target_height, secondary_height, guard_height, covers_adjacent to Technique)
- Modified: `src/card_list.zig` (added height targeting to all techniques)
- Modified: `src/random.zig` (pub RandomStreamDict.get)
- Modified: `src/world.zig` (fixed double-deinit bug in World.deinit)
- Modified: `src/armour.zig` ([]const for Material/Pattern slices)
- Modified: `src/weapon.zig` ([]const for damage_types, categories)
- Modified: `src/cards.zig` (inline for, @tagName for compileError, added advantage field to Technique)
- Modified: `src/card_list.zig` (added feint technique with advantage override, fixed deflect id)
- Modified: `build.zig` (added resolution.zig, weapon_list.zig, tick.zig test modules)

### Refactoring Session: tick/apply separation
- Modified: `src/combat.zig` - TechniquePool now creates card instances with init/deinit, applyCooldown(), tickCooldowns()
- Modified: `src/tick.zig` - Uses card instances uniformly; removed hardcoded technique ID switch; removed duplicate moveCardToZone; cleanup logic moved out
- Modified: `src/apply.zig` - Added applyCommittedCosts() as the authority for stamina deduction, card movement, and cooldowns
- Modified: `src/events.zig` - Added stamina_deducted and cooldown_applied events
- Modified: `build.zig` - Fixed test duplication (was running tests 2-3x due to transitive imports); single entry point via main.zig
- Modified: `src/main.zig` - Added test block to force discovery of all test modules

## Known Limitations & Shortcuts

Items to revisit when extending the system:

### Weapon Handling
- **Default weapon:** `tick.zig:getWeaponTemplate()` returns `knights_sword` for all agents. Need to read from `Agent.armament` once equipped weapons are wired up.
- **No weapon on Agent:** The `Armament` type exists but agents don't have equipped weapons tracked yet.

### Stakes / Commitment
- **Hardcoded stakes:** All committed actions use `.guarded` stakes. Need UI/AI to select commitment level.
- **No overcommit logic:** Players can commit >1s of actions, but interrupt penalties aren't implemented (per design doc: queued actions past interrupt point should be lost).

### Mob AI
- **Round-robin only:** `TechniquePool.selectNext()` cycles through techniques. No state-based selection, weighted options, or situational awareness.
- **Fixed cooldown:** Pool-based mobs get 2-tick cooldown (defined in `apply.zig:DEFAULT_COOLDOWN_TICKS`).
- **No defensive selection:** Mobs don't actively choose to defend; they only attack. Step 6 addresses this.

### Targeting
- **1v1 assumption:** Many places assume player vs single mob engagement. Multi-mob targeting works but engagement lookup may need refinement.
- **Partial TargetQuery:** `apply.evaluateTargets()` handles `.all_enemies`, `.self`, `.single` but stubs out `.body_part` and `.event_source`.

### Stamina & Resources
- **No stamina=0 blocking:** Design doc says stamina exhaustion should block commitment, but this isn't enforced.
- **Stamina can go negative:** `applyCommittedCosts()` clamps to 0 but doesn't prevent over-spending.

### Resolution
- **No reactions during resolution:** The FSM has `player_reaction` state but reactions aren't integrated into `TickResolver.resolve()`.
- **Single defense per window:** `findDefensiveAction()` returns first overlapping defense; doesn't handle multiple or prioritize.
- **No simultaneous death handling:** Both combatants can land lethal blows (correct per design) but no special game-over logic.

### FSM / Game Loop
- **processTick() not called automatically:** `World.processTick()` exists but nothing triggers the FSM transition yet. UI/harness must drive it.
- **No draw phase:** Card draw at tick start isn't implemented. 


## Open Design Questions

1. Should footwork techniques be "overlays" that combine with arm techniques? A- yes, this is what cards.Exclusivity is for
2. How does commitment get chosen — per-card or per-tick? - A: let's call it "per-move": per-card, but applies across all overlays. If overlays have different durations, choose once to apply for the longest-running card and everything else in parallel with it.
3. Reaction timing — can you react to reactions? - A: intent is yes, with the right meta-progression card(s) (not yet defined).
4. Stance as continuous value vs discrete states? - A: not sure, might need to unpack. 
5. Range model — per-engagement or global positioning? A: per-engagement

See `doc/combat_design.md` section "Open Questions" for more.