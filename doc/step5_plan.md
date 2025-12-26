# Step 5: Simultaneous Resolution Loop — Implementation Plan

## Overview

Wire the resolution pipeline into a proper game loop with simultaneous commitment and time-ordered resolution within 1-second ticks.

## Current State

**Ready:**
- Card costs (time/stamina) defined in `cards.Cost`
- Agent tracks `time_available`, `stamina_available`
- Deck has `.in_play` zone for committed cards
- `resolution.resolveTechniqueVsDefense()` resolves single attacks
- Events for `technique_resolved`, `advantage_changed`
- Height-weighted hit location selection

**Missing:**
- Tick structure to orchestrate resolution
- Mob action selection (AI)
- Simultaneous commitment phase
- Time-slice ordering within tick
- Interaction pairing (attack vs defense)

## Architecture

### New Module: `src/tick.zig`

Central coordinator for a single tick of combat.

```zig
pub const TickResolver = struct {
    alloc: std.mem.Allocator,
    committed: std.ArrayList(CommittedAction),

    pub fn init(alloc: std.mem.Allocator) TickResolver;
    pub fn deinit(self: *TickResolver) void;

    pub fn commitPlayerCards(self: *TickResolver, player: *Agent) !void;
    pub fn commitMobActions(self: *TickResolver, mobs: []*Agent) !void;
    pub fn resolve(self: *TickResolver, w: *World) !TickResult;
};

pub const CommittedAction = struct {
    actor: *Agent,
    card: *cards.Instance,
    technique: *const cards.Technique,
    stakes: cards.Stakes,
    time_start: f32,  // 0.0-1.0 within tick
    time_end: f32,    // time_start + cost.time
};

pub const TickResult = struct {
    resolutions: []ResolutionEntry,
    // summary for UI
};

pub const ResolutionEntry = struct {
    attacker: entity.ID,
    defender: entity.ID,
    outcome: resolution.Outcome,
    // etc
};
```

### Phase 1: Commitment

Collect all actions for this tick before any resolve.

**Player commitment** (already works via `CommandHandler.playActionCard`):
- Cards move from `.hand` to `.in_play`
- Costs reserved from `_available` fields

**Mob commitment** (new):
- Each mob selects action(s) based on behavior pattern
- Cards/techniques move to their `.in_play` equivalent
- For `TechniquePool` mobs: pick from available techniques, apply cooldowns

### Phase 2: Time Ordering

Actions happen in 0.1s slices within the tick. Sort by `time_start`:

```zig
fn compareByTimeStart(a: CommittedAction, b: CommittedAction) bool {
    return a.time_start < b.time_start;
}
```

Actions accumulate time: if player plays 3 cards (0.3s each), they happen at t=0.0, t=0.3, t=0.6.

### Phase 3: Interaction Pairing

For each time slice, determine RPS interactions:

| Attacker | Defender | Result |
|----------|----------|--------|
| Strike   | Strike   | Both resolve (simultaneous) |
| Strike   | Block    | Attacker vs Block defense |
| Strike   | Feint    | Strike likely hits |
| Feint    | Block    | Feint erodes stance |
| Feint    | Strike   | Both resolve |

**Key insight:** When both commit to attack, both attacks resolve independently (both can land).

```zig
const Interaction = struct {
    attacker: *CommittedAction,
    defender_action: ?*CommittedAction,  // null = passive defense
    defender: *Agent,
};

fn pairInteractions(actions: []CommittedAction) []Interaction;
```

### Phase 4: Resolution

For each interaction, call `resolution.resolveTechniqueVsDefense()`:

1. Select hit location (already implemented)
2. Calculate hit chance with defense technique
3. Determine outcome
4. Apply advantage effects
5. Apply damage through armor → body

### Phase 5: Costs & Cleanup

After all resolutions:
- Deduct stamina from `agent.stamina` (not just `_available`)
- Move cards to exhaust or discard
- Apply cooldowns to mob techniques
- Emit summary event

## Mob AI

### Strategy Types

Mobs use `Agent.cards: Strat` (already in `combat.zig`):

```zig
pub const Strat = union(enum) {
    deck: deck.Deck,          // Full deck like players (own card pool)
    pool: TechniquePool,      // Simplified: available techniques + cooldowns
};
```

**Recommendation:** Start with `TechniquePool` — simplest to implement.

### TechniquePool Selection

`TechniquePool` already has:
- `available: []const *cards.Template` — what the mob can do
- `cooldowns: AutoHashMap(cards.ID, u8)` — tracks per-technique cooldown
- `canUse(t)` — checks cooldown = 0

Need to add: **selection logic** (which available technique to pick).

Options for selection (pick one to start):

1. **Round-robin** — cycle through available techniques
2. **Random weighted** — each technique has a weight
3. **State-reactive** — check engagement/HP, pick appropriate

```zig
// Simplest: round-robin index on TechniquePool
pub const TechniquePool = struct {
    available: []const *cards.Template,
    in_play: std.ArrayList(*cards.Instance),
    cooldowns: std.AutoHashMap(cards.ID, u8),
    next_index: usize = 0,  // NEW: for round-robin

    pub fn selectNext(self: *TechniquePool) ?*const cards.Template {
        var attempts: usize = 0;
        while (attempts < self.available.len) : (attempts += 1) {
            const tech = self.available[self.next_index];
            self.next_index = (self.next_index + 1) % self.available.len;
            if (self.canUse(tech)) return tech;
        }
        return null;  // all on cooldown
    }
};
```

### Behavior Scripts (Deferred)

For smarter mobs, add a `Behavior` layer on top of `Strat`:

```zig
pub const Behavior = union(enum) {
    simple,                   // just use Strat selection
    fixed_loop: []const TechniqueID,  // forced sequence
    state_based: []const StateThreshold,
    // etc
};
```

This is additive — start without it, add when needed for specific mob types.

## FSM Updates

New states in `world.GameState`:

```zig
pub const GameState = enum {
    menu,
    player_card_selection,   // existing
    mob_commitment,          // NEW: AI selects actions
    tick_resolution,         // NEW: resolve all committed actions
    player_reaction,         // existing (reactions during resolution)
    animating,               // existing
    tick_cleanup,            // NEW: apply costs, move cards
};
```

## Event Flow

1. `tick_started` — new tick begins
2. `player_committed` — player done selecting
3. `mob_committed` — each mob action
4. `resolution_phase_started`
5. Multiple `technique_resolved`, `advantage_changed`, damage events
6. `tick_ended` — summary

## Implementation Order

### 5.1: CommittedAction & TickResolver skeleton
- Create `src/tick.zig`
- Define types
- Stub methods
- Unit tests for sorting

### 5.2: Player commitment extraction
- `TickResolver.commitPlayerCards()` reads from deck `.in_play`
- Creates `CommittedAction` for each
- Test with harness

### 5.3: TechniquePool selection
- Add `selectNext()` to `TechniquePool` (round-robin)
- Test with mock pool
- Respects cooldowns

### 5.4: Mob commitment
- `TickResolver.commitMobActions()`
- Uses `Strat.pool.selectNext()` for pool-based mobs
- (Deck-based mobs: defer or mirror player logic)

### 5.5: Interaction pairing
- Simultaneous attack handling
- Attack vs defense matching
- Time slice grouping

### 5.6: Resolution loop
- Call `resolveTechniqueVsDefense` for each pair
- Handle no-defense case (passive)
- Emit all events

### 5.7: Tick cleanup
- Deduct actual costs
- Move cards to exhaust/discard
- Apply cooldowns
- Reset `_available` for next tick

### 5.8: FSM integration
- New states
- Transitions between phases
- Wire into `World.step()`

### 5.9: Integration tests
- Full tick with player + mob
- Multiple mobs
- Simultaneous attacks
- Interrupt scenarios (deferred)

## Open Questions for Step 5 & working assumptions

1. **Overcommit penalty:** What happens if player commits >1s of actions and gets interrupted? Current thinking: queued actions past the interrupt point are lost (cards wasted).

2. **Passive defense baseline:** When no defense card is played, what's the default? Suggestion: use agent's equipped weapon's defensive profile at reduced effectiveness (0.5x).

3. **Stamina exhaustion:** At stamina=0, can agent still commit probing attacks? Let's say no for now.

4. **Simultaneous death:** If both combatants land lethal blows, what happens? Both resolve, both die (historical realism).

5. **Reaction timing:** Reactions happen during resolution, not commitment. How to integrate without making this phase unbounded? Suggestion: defer to Step 6.

## Dependencies

- `resolution.zig` — ready
- `cards.zig` — ready
- `combat.Agent` — ready (already has `Strat`)
- `combat.TechniquePool` — needs `selectNext()` method
- `world.zig` — needs FSM updates
- `events.zig` — may need new event types

## Estimated Complexity

- 5.1-5.2: Small (structures, extraction)
- 5.3-5.4: Medium (AI behavior system)
- 5.5-5.6: Medium (pairing logic)
- 5.7-5.8: Small (cleanup, FSM)
- 5.9: Medium (integration tests)

Total: ~400-600 lines new code in `tick.zig`, ~100 lines modifications elsewhere.
