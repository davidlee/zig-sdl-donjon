# Card Lifecycle and Timeline Integration Design

> **Status**: ✅ **COMPLETE**. All phases (1-5) finished. 2026-01-07.
>
> This document explores how card lifecycle management interacts with the
> proposed change to create Play objects during selection phase.

## Current Implementation State

**All phases complete. Timeline is now the single source of truth for in-play cards.**

**Completed (Phases 1-4)**:
- `Play` struct has `source: ?PlaySource` and `added_in_phase: Phase` fields
- Plays are created during selection phase (not just at commit)
- `cancelActionCard` uses `play.source` for lifecycle decisions
- `applyCommittedCosts` uses `action.source` for cleanup
- Mobs use timeline plays instead of iterating `in_play` directly
- Modifier source tracking via `ModifierEntry` struct (card_id + source)
- `commitStack` populates modifier source from `in_play_sources`

**Completed (Phase 5a-5g)**:
- View layer uses timeline for both selection and commit phases
- Channel conflict checking uses `validation.wouldConflictWithTimeline()`
- Removed dead code: `inPlayCards`, `enemyInPlayCards`, duplicate validators
- Rule execution (`executeCommitPhaseRules`, `executeResolvePhaseRules`) uses timeline
- AI directors create Plays immediately via `createPlayForInPlayCard` helper
- End-of-turn cleanup (`agentEndTurnCleanup`) iterates timeline, handles modifiers
- Snapshot validation (`validateCards`) uses timeline for in-play card status
- Debug logging uses timeline for mob card display

**Completed (Phase 5h-5i)**:
- Removed `CombatState.in_play` ArrayList field
- Removed `CombatState.in_play_sources` HashMap field
- Removed `InPlayInfo` struct, `CardSource` enum (no longer needed)
- `.in_play` is now a virtual zone: `moveCard(.hand, .in_play)` removes from hand only,
  `moveCard(.in_play, .discard)` adds to discard only
- `isInZone(_, .in_play)` returns false (check timeline for in-play status)
- Renamed `addToInPlayFrom` → `createPoolClone` returning `PoolCloneResult`
- Removed `removeFromInPlay` - callers use `registry.destroy()` directly
- `playValidCardReservingCosts` returns `PlayResult` with `{in_play_id, source}`
- Animation positioning uses timeline instead of `in_play.items`

**Key architectural result**: Timeline is the single source of truth for in-play cards.
`CombatState` manages deck zones (draw, hand, discard, exhaust) while timeline manages
plays during the turn.

---

## Context

We're considering deriving `in_play` zone from Timeline rather than maintaining
it as a separate data structure. Before committing to this, we need to verify
it handles all card lifecycle scenarios correctly.

**The stakes are high**: hand cards represent the player's deck. Losing cards
due to lifecycle bugs would break the core deckbuilding loop.

---

## Card Types and Their Lifecycles

### 1. Hand Cards (deck-based)

**Source**: Player's deck (draw pile)
**Lifecycle**:
```
draw → hand → [played] → in_play → [resolved] → discard
                                              → exhaust (if exhausts=true)
           → [not played] → discard (end of turn)
           → [cancelled] → hand (returned)
```

**Key invariants**:
- Card instance persists across zones
- Must end up in discard or exhaust, never destroyed
- Cancellation returns to hand (recoverable)

**Current tracking**:
- `in_play_sources.get(card_id)` returns `null` for hand cards
- This signals "return to hand on cancel, discard after resolution"

### 2. Pool Cards (always_available, spells_known)

**Source**: Agent's always_available or spells_known pool
**Lifecycle**:
```
pool (master) → [played] → clone created → in_play → [resolved] → destroyed
                         → cooldown set on master
             → [cancelled] → clone destroyed, cooldown refunded
```

**Key invariants**:
- Master card stays in pool (never moved)
- Clone is ephemeral (created on play, destroyed after use)
- Cooldown tracks master, not clone
- Playable again after cooldown expires

**Current tracking**:
- `in_play_sources.get(clone_id)` returns `CardSource{ .master_id, .source_zone }`
- Clone has `master_id` field pointing to original

### 3. Exhaust-on-Trigger Cards

**Trigger**: Card effect with `exhausts = true` in cost, or rule effect
**Lifecycle**:
```
hand → in_play → [trigger fires] → exhaust (during resolution)
```

**Key invariants**:
- Exhaust happens during resolution, not immediately
- Card may still be referenced by Play during resolution
- Play must remain valid even after card exhausted

**Open question**: If a card exhausts mid-resolution, does its Play persist?
Current code suggests yes - Play references card by ID, resolution iterates Plays.

### 4. Cards Removed by Effects

**Examples**: Disarm (remove weapon card), Counter (cancel opponent's play)
**Lifecycle varies by source**:
```
Hand card removed → discard (not lost from deck)
Pool clone removed → destroyed
```

**Key invariant**: Removal respects source-based lifecycle rules.

**Current handling**: `removeFromInPlay()` checks `in_play_sources`:
- If source exists (pool card): destroy clone, refund cooldown
- If no source (hand card): caller moves to discard

---

## Current Data Model

### CombatState (per-agent card zones)
```zig
in_play: ArrayList(entity.ID),           // Cards currently committed
in_play_sources: HashMap(ID, CardSource), // Where each in_play card came from
```

### CardSource
```zig
pub const CardSource = struct {
    master_id: entity.ID,    // Original pool card (for cooldown)
    source_zone: SourceZone, // .always_available or .spells_known
};
```

### TurnState (per-agent per-turn)
```zig
timeline: Timeline,                       // TimeSlots with Plays
pending_targets: [max_slots]?PendingTarget, // Targets before Plays exist
```

---

## Proposed Data Model

### Option A: Derive in_play from Timeline

**Changes**:
1. Remove `CombatState.in_play` ArrayList
2. Add source tracking to Play: `source: ?CardSource`
3. Compute in_play on demand via `timeline.actionCardIterator()`

**Play struct changes**:
```zig
pub const Play = struct {
    action: entity.ID,
    target: ?entity.ID = null,
    source: ?CardSource = null,  // NEW: null = hand card, Some = pool clone
    added_in_phase: Phase = .selection,  // NEW: replaces added_in_commit
    // ... rest unchanged
};

pub const Phase = enum { selection, commit };
```

**Derived in_play**:
```zig
// Iterator-based API (see Design Decisions section)
pub fn actionCardIterator(self: *const Timeline) ActionCardIterator {
    return .{ .timeline = self, .index = 0 };
}
```

**Lifecycle operations**:

| Operation | Current | Proposed |
|-----------|---------|----------|
| Play card | Add to in_play zone | Create Play in Timeline |
| Cancel card | Remove from in_play, check source | Remove Play from Timeline, check play.source |
| End resolution | Iterate in_play, move to discard/exhaust | Iterate Timeline plays, move to discard/exhaust |
| End turn cleanup | Clear in_play zone | Clear Timeline |

### Option B: Keep in_play, Sync with Timeline

**Changes**:
1. Keep `CombatState.in_play` ArrayList
2. Create Play AND add to in_play in same operation
3. Remove Play AND remove from in_play in same operation

**Risk**: Desync between in_play and Timeline if operations don't pair correctly.

---

## Scenario Analysis

### Scenario 1: Normal Play and Resolution

**Hand card played, resolved, discarded**

```
Selection phase:
  1. playActionCard(card_id, target)
  2. → Create Play in Timeline with source=null
  3. → (in_play derived: [card_id])

Commit phase:
  4. Rules execute against plays

Resolution phase:
  5. Tick processes plays
  6. applyCommittedCosts() iterates timeline plays
  7. For play with source=null: move card_id to discard
  8. → (in_play derived: [])
```

**Works**: Source tracking on Play tells us it's a hand card → discard.

### Scenario 2: Pool Card Played and Resolved

**Always_available card cloned, played, destroyed**

```
Selection phase:
  1. playActionCard(master_id, target)
  2. → Clone created (clone_id)
  3. → Create Play in Timeline with source={master_id, .always_available}
  4. → Cooldown set on master
  5. → (in_play derived: [clone_id])

Resolution phase:
  6. applyCommittedCosts() iterates timeline plays
  7. For play with source=Some: destroy clone (registry.remove)
  8. → (in_play derived: [])
```

**Works**: Source tracking on Play tells us it's a clone → destroy.

### Scenario 3: Card Cancelled During Selection

**Hand card cancelled, returned to hand**

```
Selection phase:
  1. playActionCard(card_id, target)
  2. → Create Play in Timeline with source=null
  3. cancelActionCard(card_id)
  4. → Find play by card_id in Timeline
  5. → play.source == null → move card_id to hand
  6. → Remove play from Timeline
  7. → (in_play derived: [])
```

**Works**: Source=null means hand card → return to hand.

### Scenario 4: Pool Card Cancelled

**Clone cancelled, destroyed, cooldown refunded**

```
Selection phase:
  1. playActionCard(master_id, target)
  2. → Clone created, Play with source={master_id, .always_available}
  3. cancelActionCard(clone_id)
  4. → Find play by card_id in Timeline
  5. → play.source == Some → destroy clone, refund cooldown on master
  6. → Remove play from Timeline
```

**Works**: Source tells us master_id for cooldown refund.

### Scenario 5: Card Exhausts on Trigger

**Card with exhausts=true resolved**

```
Resolution phase:
  1. Play exists in Timeline
  2. on_resolve rule fires with exhausts effect
  3. → Move card from in_play to exhaust
  4. Play still valid (references card_id, card still in registry)
  5. Resolution continues
  6. applyCommittedCosts() sees card already in exhaust, skips
```

**Question**: How do we know card was already exhausted?

**Current code** (resolve.zig:124-129):
```zig
if (card.template.cost.exhausts) {
    cs.moveCard(card.id, .in_play, .exhaust) catch {};
    // Event emitted
}
```

**With derived in_play**: We need to track "already exhausted" state.

**Options**:
a. Check if card is in exhaust zone before moving
b. Add `exhausted: bool` flag to Play
c. Remove Play from Timeline when exhausted (breaks iteration?)

**Recommendation**: Option (a) - check destination zone before move:
```zig
if (card.template.cost.exhausts and !cs.isInZone(card.id, .exhaust)) {
    // Exhaust card - need to remove from timeline too
}
```

But wait - if in_play is derived from Timeline, we can't just move the card to
exhaust without also removing the Play. The Play references the card.

**Revised approach**: Exhausting a card mid-resolution should:
1. Mark Play as exhausted (new field)
2. Skip card in future resolution steps
3. Move card to exhaust at end of resolution (with other post-resolution moves)

Or simpler: **Don't exhaust mid-resolution**. Queue exhausts, apply at end.
Current code already does this in `applyCommittedCosts()`.

### Scenario 6: Effect Removes Opponent's Card

**Disarm effect removes weapon card from opponent's play**

```
Resolution phase:
  1. Player's Disarm resolves
  2. Effect targets opponent's weapon play
  3. → Find opponent's play in their Timeline
  4. → Check play.source
  5. → If hand card: move to discard
  6. → If clone: destroy, refund cooldown
  7. → Remove play from opponent's Timeline
```

**Works**: Same source-based logic, just operating on opponent's Timeline.

### Scenario 7: Modifier Cards in Play

**Modifier stacked on action card**

```
Commit phase:
  1. commitStack(modifier_id, play_index)
  2. → Move modifier to in_play (or clone if pool)
  3. → Add modifier_id to play.modifier_stack

Resolution phase:
  4. Modifier effects applied via play.modifiers()
  5. After resolution: move modifier to discard/destroy clone
```

**Question**: Where does modifier source tracking live?

**Current**: Modifier cards are in `in_play` zone, tracked by `in_play_sources`.

**Proposed**: Need separate tracking for modifiers, OR:
- Store `ModifierEntry = { card_id, source: ?CardSource }` in modifier stack
- This ensures modifiers respect lifecycle rules

**Play struct with modifier sources**:
```zig
pub const ModifierEntry = struct {
    card_id: entity.ID,
    source: ?CardSource,  // null = hand, Some = clone
};

modifier_stack_buf: [max_modifiers]ModifierEntry = undefined,
```

This is a larger change but ensures correctness.

---

## Edge Cases to Verify

### 1. Card played, then same card's clone played
- Different IDs (clone vs original)
- Should work: each Play tracks its own source

### 2. All cards cancelled, timeline empty
- Derived in_play returns empty slice
- No issues

### 3. Card in play when combat ends
- End-of-combat cleanup clears Timeline
- Cards should return to deck (hand cards) or be destroyed (clones)
- Need explicit cleanup path

### 4. Card moved by effect while in play
- E.g., "shuffle target card into deck"
- Need to remove Play from Timeline when card moves
- Source tracking tells us how to handle the card

### 5. Clone master destroyed while clone in play
- Shouldn't happen (masters are in agent.always_available, not registry)
- But worth defensive check

---

## Data Migration Path

### Phase 1: Add source to Play ✓ COMPLETE

Added to `src/domain/combat/plays.zig`:
```zig
pub const Phase = enum { selection, commit };

pub const PlaySource = struct {
    master_id: entity.ID,
    source_zone: SourceZone,
    pub const SourceZone = enum { always_available, spells_known };
};

// On Play struct:
source: ?PlaySource = null,  // null = hand card, Some = pool clone
added_in_phase: Phase = .selection,
```

Also exported `Phase` and `PlaySource` via `combat/mod.zig` and `combat.zig`.

### Phase 2: Populate source during play creation ✓ COMPLETE

**Key change**: Plays are now created during selection phase, not just at commit.

- `playActionCard` (`command_handler.zig`): Now creates Play immediately after
  `playValidCardReservingCosts`, with source derived from `in_play_sources`
- `commitAdd` (`command_handler.zig`): Sets source when creating commit-phase Play
- `buildPlaysForAgent` (`event_processor.zig`): Skips cards that already have plays
  (selection-phase plays exist before commit)

### Phase 3: Update lifecycle operations to use play.source ✓ COMPLETE

- `cancelActionCard` (`command_handler.zig`): Now finds play via `findPlayByCard`,
  uses `play.source` to determine handling (destroy clone vs return to hand),
  removes play from timeline
- `CommittedAction` (`tick/committed_action.zig`): Added `source: ?PlaySource` field
- `commitPlayerCards` / `commitSingleMob` (`tick/resolver.zig`): Propagate
  `play.source` to `CommittedAction`. Mobs now use plays (via timeline slots)
  instead of iterating `in_play` directly.
- `applyCommittedCosts` (`apply/costs.zig`): Uses `action.source` for lifecycle:
  - `null` → hand card → move to discard/exhaust
  - `Some` → pool clone → destroy via `removeFromInPlay`

### Phase 4: Add modifier source tracking ✓ COMPLETE

- Changed `modifier_stack_buf` from `[max_modifiers]entity.ID` to `[max_modifiers]ModifierEntry`
- `ModifierEntry = struct { card_id: entity.ID, source: ?PlaySource }`
- Updated `addModifier(card_id, source)`, `modifiers()` returns `[]const ModifierEntry`
- Updated callers in `plays.zig`, `view.zig` to use `entry.card_id`
- Updated `commitStack`/`applyStack` to populate modifier source from `in_play_sources`
- Exported `ModifierEntry` from `combat/mod.zig` and `combat.zig`

### Phase 5: Remove in_play zone — PENDING

**Sub-tasks by category:**

#### 5a. View layer ✓ COMPLETE
- `playerPlays()` now always uses timeline (removed phase check)
- Removed dead code: `inPlayCards()`, `inPlayZone()`, `buildPlayViewDataFromCard()`, `enemyInPlayCards()`
- Remaining `.in_play` usages are `CombatZone` enum values for UI display (fine to keep)

#### 5b. Channel conflict checking ✓ COMPLETE
- Created `validation.wouldConflictWithTimeline()` - iterates timeline plays
- Removed duplicate `wouldConflictWithInPlay()` from both files
- Updated `playActionCard` and `commitAdd` to use new function
- Note: `TurnState.wouldConflictOnChannel` now only used by tests (potential cleanup)

#### 5c. Rule execution ✓ COMPLETE
- `executeCommitPhaseRules()` iterates timeline slots, processes action + modifier cards
- `executeResolvePhaseRules()` iterates timeline slots, processes action + modifier cards
- Extracted helper functions `executeCardCommitRules` and `executeCardResolveRules`

#### 5d. Play building for mobs ✓ COMPLETE
- AI directors (`SimpleDeckDirector`, `PoolDirector`) now create Plays immediately
- Added `createPlayForInPlayCard` helper in `ai.zig` (shared by AI directors)
- `buildPlaysForAgent()` now acts as safety net (should be no-op for AI-controlled mobs)

#### 5e. Cleanup paths ✓ COMPLETE
- `agentEndTurnCleanup` now iterates timeline slots (not `in_play.items`)
- Added `cleanupCardBySource` helper for source-based cleanup (discard vs destroy)
- Handles both action cards and modifiers from `play.modifiers()`
- Legacy: still clears `in_play` as safety net (removed in 5i)
- `applyCommittedCosts` already uses `action.source` for lifecycle (Phase 3)

#### 5f. Snapshot/validation ✓ COMPLETE
- `validateCards` in `combat_snapshot.zig` now iterates timeline slots
- Includes both action cards and modifiers from `play.modifiers()`

#### 5g. Debug logging ✓ COMPLETE
- `event_processor.zig` debug logging now iterates timeline instead of `in_play`

#### 5h. Zone transition rethink
- `command_handler.zig:104` - `moveCard(.hand, .in_play)` when playing
- `command_handler.zig:204,307` - `moveCard(.in_play, .hand)` on cancel/withdraw
- `costs.zig:59` - `moveCard(.in_play, .discard/exhaust)` after resolution

**Investigation findings:**
- Two zone enums: `cards.Zone` (events) and `combat.CombatZone` (CombatState)
- Effects mapper ignores `card_moved` to `.in_play` - uses `played_action_card` instead
- Only meaningful `card_moved` with `.in_play`: cancel (→hand) and resolve (→discard)

**Decision: Rename `.in_play` to `.played`**
- Clearer semantics: cards have been played, now live in timeline
- Timeline cleanup restores them to discard/exhaust
- Rename in both `cards.Zone` and `combat.CombatZone`
- Keep enum value (costs nothing), remove backing ArrayList in 5i

#### 5i. Remove CombatState fields (final step)
- Remove `in_play: ArrayList(entity.ID)`
- Remove `in_play_sources: HashMap(ID, InPlayInfo)`
- Update `zoneList()`, `isInZone()`, etc. to handle missing zone
- Keep `addToInPlayFrom()` for clone creation? Or rename to `createPoolClone()`?

**Decisions:**
1. ~~Do mobs need timeline support?~~ **Yes** - `in_play` goes entirely, mobs use timeline too
2. `CombatZone.in_play` enum value - keep for events? TBD
3. View render timing - verify timeline populated before render

**Suggested order:**
1. 5a (view) - quick win, validates timeline-during-selection works
2. 5b (channel conflicts) - small, self-contained
3. 5c (rule execution) - important, touches game logic
4. 5d (mob plays) - ensure mobs use timeline properly
5. 5e (cleanup) - needs `cleanupTimelinePlays()` helper
6. 5f-5g (snapshot, debug) - low risk
7. 5h (zone transitions) - conceptual, may need event changes
8. 5i (remove fields) - final cleanup

---

## Risks and Mitigations

### Risk 1: Losing hand cards
**Mitigation**:
- Exhaustive tests for all lifecycle paths
- source=null always means "goes to discard, never destroyed"
- Defensive: log warning if hand card would be destroyed

### Risk 2: Clone leaks (not destroyed)
**Mitigation**:
- End-of-turn cleanup iterates Timeline, destroys all clones
- source=Some always means "destroy clone"

### Risk 3: Cooldown desync
**Mitigation**:
- source.master_id used for all cooldown operations
- Cancel path verified to refund correctly

### Risk 4: Modifier lifecycle bugs
**Mitigation**:
- ModifierEntry with source tracking
- Same lifecycle logic as action cards

---

## Recommendation

**Proceed with Option A (derive in_play from Timeline)** with these additions:

1. ~~**Add `source: ?PlaySource` to Play**~~ ✓ - essential for lifecycle
2. ~~**Add `ModifierEntry` struct**~~ ✓ - modifiers need source tracking too (Phase 4)
3. ~~**Rename `added_in_commit` to `added_in_phase: Phase`**~~ ✓ - cleaner semantics
4. **Add `Timeline.actionCardIterator()` helper** - clean derivation API (Phase 5)
5. ~~**Verify exhaust handling**~~ ✓ - consolidated to `applyCommittedCosts()` only

**Implementation note**: Named the type `PlaySource` (not `CardSource`) to avoid
confusion with the existing `CombatState.CardSource` enum. The new struct carries
`master_id` and `source_zone` for pool cards; null means hand card.

The approach is sound if we:
- Track source on Play (not just in zone metadata)
- Handle modifiers consistently
- Test all lifecycle scenarios exhaustively

---

## Test Scenarios Needed

1. Hand card played → resolved → discarded
2. Hand card played → cancelled → returned to hand
3. Pool card played → resolved → clone destroyed
4. Pool card played → cancelled → clone destroyed, cooldown refunded
5. Card with exhausts=true → ends up in exhaust
6. Modifier stacked from hand → resolved → discarded
7. Modifier stacked from pool → resolved → clone destroyed
8. Effect removes opponent's hand card → discarded
9. Effect removes opponent's pool clone → destroyed
10. End of turn with cards still in play → all cleaned up correctly
11. Combat ends with cards in play → deck integrity preserved

---

## Implementation Guidelines

### Exhaust Handling Policy

**Decision**: Defer all zone moves to the existing `applyCommittedCosts()` pass.

This pass already happens after plays resolve. By keeping all zone transitions
there:
- A Play remains valid throughout the tick even if its card will end up in exhaust
- Timeline-driven cleanup stays deterministic
- No special mid-resolution handling needed

Cards with `exhausts=true` are simply moved to exhaust zone instead of discard
during `applyCommittedCosts()`.

**Prerequisite cleanup (completed)**: Removed duplicate exhaust handling from
`executeResolvePhaseRules()`. Previously, cards with `on_resolve` rules that fired
AND `exhausts=true` were moved to exhaust there, then `applyCommittedCosts()` would
try to move them again (silently caught). Now `applyCommittedCosts()` is the single
point for all zone transitions.

### Cleanup Helper for Both Paths

**Decision**: Create shared helper `cleanupTimelinePlays(agent_state, registry)`.

Two paths need identical cleanup logic:
1. **Normal end-of-turn**: After `applyCommittedCosts()`, clear timeline
2. **Combat end**: During encounter teardown, clean up all agents

The helper iterates the timeline for an agent and:
- Moves hand cards back to discard (deck integrity preserved)
- Destroys clones (registry.remove)
- Clears the timeline

This ensures both paths use identical operations, preventing divergence bugs.

```zig
pub fn cleanupTimelinePlays(
    enc_state: *AgentEncounterState,
    agent: *Agent,
    registry: *CardRegistry,
) void {
    for (enc_state.current.timeline.slots()) |slot| {
        const play = &slot.play;
        if (play.source) |src| {
            // Pool clone: destroy
            registry.remove(play.action);
        } else {
            // Hand card: move to discard
            if (agent.combat_state) |cs| {
                cs.discard.append(cs.alloc, play.action) catch {};
            }
        }
        // Also handle modifiers in play.modifier_stack
        for (play.modifierEntries()) |mod| {
            if (mod.source) |_| {
                registry.remove(mod.card_id);
            } else {
                if (agent.combat_state) |cs| {
                    cs.discard.append(cs.alloc, mod.card_id) catch {};
                }
            }
        }
    }
    enc_state.current.timeline.clear();
}
```

---

## Design Decisions

### Timeline.cardIds() API

**Decision**: Use an iterator rather than returning a stack-allocated array.

Returning `[]const entity.ID` from a stack buffer works for iteration but callers
can't store the result. An iterator-based API is more flexible:
```zig
pub fn actionCardIterator(self: *const Timeline) ActionCardIterator { ... }
```

### Modifier Source Tracking

**Decision**: Use `ModifierEntry` struct with source tracking.

Survey of callers found the change reasonably scoped:
- `plays.zig`: `modifiers()` returns `[]const ModifierEntry`, callers extract `.card_id`
- `view.zig`: Already transforms to `CardViewData`, just reads different field
- `validation.zig`, `command_handler.zig`: Only check length, unaffected

Modifiers *are* cards with the same lifecycle rules. A parallel tracking mechanism
would duplicate logic and create another sync point.

### Card Instance Immutability

**Decision**: Card instances are immutable while in play.

Transforming an instance would persist for the rest of the game through encounters.
Effects that "transform" a card should instead exhaust-and-replace: exhaust the
original, create a replacement with appropriate source tracking to ensure correct
lifecycle (destruction for clones, discard for hand cards).

---

## Open Questions

None currently—all raised questions have been resolved above.
