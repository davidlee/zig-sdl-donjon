# Handover Notes

## 2026-01-02: Focus System Phase 3 Complete

### Implemented

**3.1: FSM Fix**
- Fixed typo `.begin_commit_phask` → `.begin_commit_phase` in world.zig

**3.2: Commit Phase Handler**
- `buildPlaysFromInPlayCards()` creates Play structs from in_play cards on entering commit_phase
- Executes `on_commit` rules for player and mobs during commit phase
- Auto-transitions to tick_resolution after commit phase processing

**3.3: New Trigger**
- Added `on_commit` to Trigger enum for cards that fire during commit phase (e.g., Feint)

**3.4: Play Targeting**
- Added `my_play: Predicate` and `opponent_play: Predicate` to TargetQuery
- Added `evaluatePlayTargets()` to find plays matching predicate
- Added `playMatchesPredicate()` for tag-based play filtering

**3.5: Play Effects**
- Added `modify_play` effect: cost_mult, damage_mult, replace_advantage
- Added `cancel_play` effect: removes target play
- Added `applyCommitPhaseEffect()` to apply effects to Play structs

**3.6: TurnState Methods**
- Added `TurnState.removePlay(index)` - removes play, shifts array
- Added `TurnState.findPlayByCard(card_id)` - returns play index

**3.7: Focus Spending Commands**
- `commit_withdraw`: 1F, remove card from play, refund stamina
- `commit_add`: 1F, add card from hand as new play (marked `added_in_commit`)
- `commit_stack`: 1F, reinforce existing play (same template required)
- `commit_done`: finish commit phase, transition to tick_resolution

**3.8: Tick Resolution Updates**
- `CommittedAction` now carries `damage_mult` and `advantage_override`
- `commitPlayerCards()` reads from `AgentEncounterState.current.plays`
- Uses Play's `cost_mult` for time, `effectiveStakes()` for stakes

**3.9: Focus Validation**
- `validateCardSelection()` checks `agent.focus.available >= template.cost.focus`
- Added `InsufficientFocus` error to ValidationError

### Key Files Changed
- `world.zig` - FSM typo fix, processTick passes encounter
- `cards.zig` - on_commit trigger, my_play/opponent_play targeting, modify_play/cancel_play effects
- `combat.zig` - TurnState.removePlay(), TurnState.findPlayByCard()
- `apply.zig` - buildPlaysFromInPlayCards, executeCommitPhaseRules, evaluatePlayTargets, commit commands, Focus validation
- `tick.zig` - CommittedAction damage_mult/advantage_override, commitPlayerCards uses plays
- `commands.zig` - commit_withdraw, commit_add, commit_stack, commit_done

### Tests Added
- `TurnState.removePlay` shifts remaining plays
- `TurnState.removePlay` handles out of bounds
- `TurnState.findPlayByCard` returns correct index

### Remaining (per design doc)
- Phase 4: Draw decision mechanics
- Phase 5: Transform cards (Feint)

---

## 2026-01-02: Test Coverage Backfill

- `stats.Resource`: 5 tests covering commit/finalize, uncommit, spend, tick, reset
- `AgentPair.canonical`: assertion for self-engagement (a==b), test for order invariance
- `Play.addReinforcement`, `TurnState.addPlay`: overflow error tests

---

## 2026-01-02: Focus System Phase 1.5 Complete

### Implemented

**1.5: Turn State Structs**
- Added `Play` struct with reinforcements buffer, stakes escalation, modifiers
- Added `TurnState` struct tracking plays and focus_spent
- Added `TurnHistory` ring buffer (4 turns) with push/lastTurn/turnsAgo
- Added `AgentEncounterState` wrapping current turn + history
- Added `Encounter.agent_state` hashmap with `stateFor()` accessor
- Player and enemy states auto-initialized in `Encounter.init()`/`addEnemy()`
- Note: BoundedArray removed in Zig 0.15, replaced with buffer+len pattern

### Key Files Changed
- `combat.zig` - Play, TurnState, TurnHistory, AgentEncounterState, Encounter.agent_state

---

## 2026-01-02: Focus System Phase 2 Complete

### Implemented

**2.1: TagSet Extension**
- Added `manoeuvre` tag to `TagSet` packed struct
- Updated bitcast size from `u12` to `u13`

**2.2: Draw Filtering**
- Added `TagIterator` struct for iterating cards by tag
- Added `Deck.countByTag()` - count cards in draw pile matching tag mask
- Added `Deck.drawableByTag()` - iterate draw pile by tag mask
- Added 4 tests for tag filtering functionality

### Key Files Changed
- `cards.zig` - TagSet.manoeuvre, updated bitcasts
- `deck.zig` - TagIterator, countByTag(), drawableByTag(), tests

### Remaining (per design doc)
- Phase 3: Commit phase mechanics
- Phase 4: Draw decision mechanics
- Phase 5: Transform cards (Feint)

---

## 2026-01-02: Focus System Phase 1 Complete

### Implemented

**1.1-1.3: Resource System**
- Added `stats.Resource` struct with commit/spend/finalize semantics
- Replaced `Agent.stamina`/`stamina_available` with `stamina: Resource`
- Added `Agent.focus: Resource`
- Added `Cost.focus: f32 = 0`

**1.4: Encounter State Migration**
- Added `AgentPair` for canonical agent pair keys
- Added `Encounter.engagements: AutoHashMap(AgentPair, Engagement)`
- Added `Encounter.player_id`, `getEngagement()`, `setEngagement()`, `addEnemy()`
- Removed `Agent.engagement` field
- Updated `ConditionIterator` to take optional engagement parameter
- Migrated all engagement lookups to use Encounter

### Remaining (Phase 1.5 per design doc)
- `TurnState`, `TurnHistory`, `Play` structs not yet added
- `AgentEncounterState` not yet wired up

### Default Resource Values
```zig
stamina: Resource.init(10.0, 10.0, 2.0)  // default, max, per_turn
focus: Resource.init(3.0, 5.0, 3.0)
```

### Key Files Changed
- `stats.zig` - Resource struct
- `combat.zig` - Agent, Encounter, AgentPair, ConditionIterator
- `cards.zig` - Cost.focus
- `apply.zig`, `tick.zig`, `resolution.zig` - engagement lookups
- `world.zig` - Encounter init ordering
- `harness.zig` - uses `addEnemy()`
