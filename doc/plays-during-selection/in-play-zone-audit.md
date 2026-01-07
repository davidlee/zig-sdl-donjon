# in_play Zone Audit

> **Research for**: Plays During Selection refactor
> **Date**: 2026-01-07

## Summary

The `in_play` zone is a transient combat zone (`CombatState.in_play`) that holds card IDs during the selection and commit phases. It serves as an intermediate container between source zones (hand, always_available) and destination zones (discard, exhaust).

**Total source file usages**: 14 distinct files, ~60 direct references to `.in_play`

If Play objects are created during selection phase, `in_play` could potentially become:
- **Derived**: computed as `timeline.actionCardIds()`
- **Retained**: for backwards compatibility with zone-based operations
- **Hybrid**: primary source moves to Timeline, zone kept in sync

---

## 1. Writes to in_play Zone

### 1.1 Adding Cards to in_play

| File | Line(s) | Function | Source | Notes |
|------|---------|----------|--------|-------|
| `src/domain/apply/command_handler.zig` | 104 | `playValidCardReservingCosts()` | `.hand` | `moveCard(.hand, .in_play)` for deck cards |
| `src/domain/combat/state.zig` | 162, 170 | `addToInPlayFrom()` | `.always_available`, `.spells_known` | Creates clone for pool cards, appends to in_play |

**Classification**: Game Logic (card playing)

**Impact if derived from Timeline**:
- `playValidCardReservingCosts()` would need to create a Play instead of moving to zone
- `addToInPlayFrom()` clone creation could stay, but append to Timeline not zone
- Would need new API: `timeline.addPlay(card_id, timing, source)`

### 1.2 Removing Cards from in_play

| File | Line(s) | Function | Destination | Notes |
|------|---------|----------|-------------|-------|
| `src/domain/apply/command_handler.zig` | 203, 210, 299 | `cancelActionCard()`, `commitWithdraw()` | `.hand` | Returns card to hand on cancel/withdraw |
| `src/domain/apply/costs.zig` | 51, 64 | `applyCommittedCosts()` | `.discard`, `.exhaust` | Post-resolution cleanup |
| `src/domain/apply/effects/resolve.zig` | 128 | `executeResolvePhaseRules()` | `.exhaust` | Cards with `exhausts=true` after on_resolve |
| `src/domain/combat/state.zig` | 194-195 | `removeFromInPlay()` | N/A | Removes from zone, destroys clones |
| `src/domain/apply/event_processor.zig` | 63-69 | `agentEndTurnCleanup()` | `.discard` | Cleanup at turn end |

**Classification**: Game Logic (cancel, withdraw, resolution, cleanup)

**Impact if derived from Timeline**:
- Cancel/withdraw would remove Play from Timeline
- Cost application would need to iterate Timeline plays, not zone
- `removeFromInPlay()` stays for clone destruction, but triggered differently
- End-turn cleanup iterates Timeline, not zone

---

## 2. Reads from in_play Zone

### 2.1 Iteration for Game Logic

| File | Line(s) | Function | Purpose |
|------|---------|----------|---------|
| `src/domain/apply/command_handler.zig` | 50 | `wouldConflictWithInPlay()` | Channel conflict detection |
| `src/domain/apply/validation.zig` | 197 | `wouldConflictWithInPlay()` | Same - duplicated function |
| `src/domain/apply/effects/commit.zig` | 45 | `executeCommitPhaseRules()` | Execute on_commit rules for in_play cards |
| `src/domain/apply/effects/resolve.zig` | 82 | `executeResolvePhaseRules()` | Execute on_resolve rules for in_play cards |
| `src/domain/apply/event_processor.zig` | 138 | `buildPlaysForAgent()` | Create Play objects from in_play cards |
| `src/domain/apply/event_processor.zig` | 284 | Debug logging | Log cards in play for mobs |
| `src/domain/tick/resolver.zig` | 109 | `commitSingleMob()` | Build CommittedActions from mob's in_play |
| `src/domain/query/combat_snapshot.zig` | 133 | `validateCards()` | Validate in_play cards for stacking |

**Classification**: Validation, Game Logic, Snapshot

**Impact if derived from Timeline**:
- `wouldConflictWithInPlay()` could query Timeline plays instead
- `executeCommitPhaseRules()` / `executeResolvePhaseRules()` iterate Timeline
- `buildPlaysForAgent()` becomes no-op (Plays exist already)
- `commitSingleMob()` iterates mob's Timeline
- `validateCards()` validates Timeline plays

### 2.2 Zone State Checks

| File | Line(s) | Function | Purpose |
|------|---------|----------|---------|
| `src/domain/apply/command_handler.zig` | 183 | `cancelActionCard()` | Verify card is in in_play before cancel |
| `src/domain/combat/state.zig` | 91-103 | `isInZone()` | Generic zone membership check |
| `src/domain/combat/state.zig` | 84, 95 | `zoneList()` | Get zone ArrayList by enum |

**Classification**: Validation

**Impact if derived from Timeline**:
- `isInZone(.in_play)` would query Timeline instead
- Could add `timeline.containsCard(card_id)` helper
- Zone enum still has `.in_play` value for `moveCard()` destination semantics

### 2.3 Presentation Layer Reads

| File | Line(s) | Function | Purpose |
|------|---------|----------|---------|
| `src/presentation/views/combat/view.zig` | 512 | `inPlayCards()` | Get player's in_play cards for rendering |
| `src/presentation/views/combat/view.zig` | 525 | `enemyInPlayCards()` | Get enemy's in_play cards for rendering |
| `src/presentation/views/combat/view.zig` | 561-572 | `playerPlays()` | Synthesize PlayViewData from in_play during selection |
| `src/presentation/views/combat/view.zig` | 1035 | `inPlayZone()` | Create CardZoneView for in_play rendering |
| `src/presentation/effects.zig` | 196-210 | `finalizeCardAnimation()` | Find card position in in_play for animation destination |

**Classification**: Rendering

**Impact if derived from Timeline**:
- `inPlayCards()` would query `timeline.actionCardIds()`
- `playerPlays()` during selection would use real Timeline (currently synthesizes)
- Animation destination lookup could use Timeline positions
- This is a **simplification** - view code currently works around missing Play objects

---

## 3. in_play_sources HashMap

The `CombatState.in_play_sources` HashMap tracks where in_play cards came from:

| File | Line(s) | Usage |
|------|---------|-------|
| `src/domain/combat/state.zig` | 31, 54, 65, 75, 163, 171, 197-198 | Definition, init, deinit, clear, put, get, remove |
| `src/domain/apply/command_handler.zig` | 190 | Check if card is a pool clone (for cancel handling) |

**Purpose**: Track card source for:
1. Returning cards to correct zone on cancel
2. Knowing which cards are clones (have `master_id`)
3. Applying cooldowns to master, not clone

**Impact if derived from Timeline**:
- Source tracking could move to Play: `play.source: CardSource`
- Clone master_id stays on Play for cooldown purposes
- `in_play_sources` HashMap becomes redundant

---

## 4. Zone Enum Values

Three separate zone enums exist:

1. **`cards.Zone`** (`src/domain/cards.zig:42-53`) - Includes `.in_play`, used for card location semantics
2. **`combat.CombatZone`** (`src/domain/combat/state.zig:12-18`) - Combat-specific subset, includes `.in_play`
3. **`hit.Zone`** (`src/presentation/views/combat/hit.zig:11-18`) - View-specific, includes `.in_play`

**Impact if derived from Timeline**:
- Enum values stay - they describe conceptual zones
- `moveCard()` semantics change: `.hand → .in_play` creates Play instead
- View zone enum unchanged (describes layout, not storage)

---

## 5. Implicit Ordering Assumptions

### 5.1 in_play Order

| File | Line(s) | Assumption |
|------|---------|------------|
| `src/presentation/views/combat/view.zig` | 561-572 | Iterates in_play sequentially, assigns time based on order |
| `src/presentation/effects.zig` | 196-210 | Finds card index in in_play for animation positioning |
| `src/domain/apply/event_processor.zig` | 138 | Iterates in_play, adds Plays (order preserved) |
| `src/domain/tick/resolver.zig` | 109 | Iterates in_play for mobs, builds actions in order |

**Current semantics**: Cards are added to in_play in the order they're played. This order is:
- Used for sequential time assignment in synthesized PlayViewData
- Used for animation destination calculation
- Preserved when building actual Plays

**Impact if derived from Timeline**:
- Timeline has explicit timing, no need to infer from order
- Animation can use Timeline slot position instead
- Mob card ordering determined by AI director's timing assignment

### 5.2 Iteration Order Dependence

The code uses `orderedRemove()` to preserve ordering, suggesting some dependence:
- `src/domain/combat/state.zig:195` - `removeFromInPlay()` uses orderedRemove

**Risk**: If ordering matters for determinism, Timeline ordering (by time_start, then insertion) must be stable.

---

## 6. Usage Categories Summary

### Must Change (blocking)

| Category | Count | Files |
|----------|-------|-------|
| Build Plays from in_play | 1 | event_processor.zig |
| Synthesize timing from in_play | 1 | view.zig |

These are the core workarounds that the refactor eliminates.

### Should Change (natural fit)

| Category | Count | Files |
|----------|-------|-------|
| Rule execution iteration | 2 | commit.zig, resolve.zig |
| Conflict detection | 2 | command_handler.zig, validation.zig |
| Mob action building | 1 | resolver.zig |
| Snapshot validation | 1 | combat_snapshot.zig |

These iterate in_play and would naturally iterate Timeline instead.

### May Change (optimization)

| Category | Count | Files |
|----------|-------|-------|
| Zone membership checks | 3 | command_handler.zig, state.zig |
| Presentation queries | 3 | view.zig, effects.zig |
| Source tracking | 2 | command_handler.zig, state.zig |

These could query Timeline or keep zone as derived cache.

### Stays (cleanup operations)

| Category | Count | Files |
|----------|-------|-------|
| Move to discard/exhaust | 3 | costs.zig, resolve.zig, event_processor.zig |
| Clone destruction | 1 | state.zig |
| Zone clearing | 1 | state.zig |

Post-resolution cleanup still needs to move cards to destination zones.

---

## 7. Recommendations

### Option A: in_play Becomes Derived

1. Primary storage moves to `Timeline.slots`
2. `CombatState.in_play` computed on demand: `timeline.cardIds()`
3. All reads switch to Timeline queries
4. Writes create/remove Plays
5. `in_play_sources` data moves to `Play.source`

**Pros**: Clean model, no duplication
**Cons**: Larger refactor, need Timeline on all agents

### Option B: Dual Storage (Hybrid)

1. Plays created during selection (new)
2. `in_play` zone kept in sync (existing)
3. Reads can use either (gradual migration)
4. Writes update both

**Pros**: Incremental migration
**Cons**: Duplication risk, complexity

### Option C: in_play for Cards, Timeline for Plays

1. `in_play` stays as card container
2. Timeline references cards in `in_play`
3. `in_play` ordering matches Timeline order

**Pros**: Minimal disruption
**Cons**: Still have bridge at commit phase, ordering coupling

---

## 8. Files to Modify (by approach)

If adopting **Option A** (in_play derived):

**Domain Layer**:
- `src/domain/combat/state.zig` - Add Timeline, remove in_play writes
- `src/domain/apply/command_handler.zig` - Create Plays directly
- `src/domain/apply/event_processor.zig` - Remove `buildPlaysFromInPlayCards()`
- `src/domain/apply/validation.zig` - Query Timeline for conflicts
- `src/domain/apply/effects/commit.zig` - Iterate Timeline
- `src/domain/apply/effects/resolve.zig` - Iterate Timeline
- `src/domain/apply/costs.zig` - Iterate Timeline plays
- `src/domain/tick/resolver.zig` - Use mob's Timeline

**Query Layer**:
- `src/domain/query/combat_snapshot.zig` - Validate from Timeline

**Presentation Layer**:
- `src/presentation/views/combat/view.zig` - Remove synthesized plays
- `src/presentation/effects.zig` - Use Timeline for animation positions

---

## 9. Test Coverage

Files with tests touching in_play:
- None directly (tests use high-level fixtures)

Tests that may need updates:
- Any integration tests that check zone membership
- Tests that verify card lifecycle (play → resolve → discard)

---

## 10. Open Questions

1. **Mob Timeline**: Do mobs need a full Timeline, or is AI card selection simpler?
2. **Cooldowns**: Currently on `CombatState.cooldowns` keyed by master_id. Stays?
3. **Events**: `card_moved` events reference `.in_play` zone. Keep enum value?
4. **AI Director**: Does AI director populate Timeline, or is it simpler?
5. **PendingTarget**: Separate audit needed for this struct
