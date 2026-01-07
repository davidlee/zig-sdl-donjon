# Plays During Selection Phase

> **Status**: Design complete, ready for implementation. 2026-01-07.

## Problem Statement

The timeline UI (see `timeline-ui-plan.md`) requires:
- Cards positioned at specific times on channel lanes
- Overlapping cards on different channels (e.g., weapon at t=0, footwork at t=0)
- Drag-to-reposition interactions

The current domain model doesn't support this because **Play objects don't exist during selection phase**.

## Current Architecture

```
Selection Phase              Commit Phase Entry           Commit Phase
─────────────────────────    ──────────────────────────   ────────────────
cards → in_play zone         buildPlaysFromInPlayCards()  Timeline w/ Plays
targets → PendingTarget      → addPlay() for each card    ↳ TimeSlots
timing → (none)              → nextAvailableStart()       ↳ explicit timing
```

### The Limitation

During selection:
1. `playActionCard()` moves card to `in_play` zone
2. Targets stored in `TurnState.pending_targets`
3. **No timing information captured**

At commit phase entry:
1. `buildPlaysFromInPlayCards()` iterates `in_play` cards
2. Calls `addPlay()` which uses `nextAvailableStart()`
3. Cards placed sequentially, even when channels don't conflict

### Workarounds in UI

`view.zig` synthesizes fake timing using a `time_cursor`:
```zig
var time_cursor: f32 = 0;
for (in_play) |card_id| {
    const time_start = time_cursor;
    time_cursor += duration;  // Sequential, no overlap possible
}
```

---

## Decision: Create Plays During Selection

Create `Play` objects immediately when cards are played during selection phase.

### Rationale

1. Domain model should reflect actual game semantics
2. Timeline with timing/channels IS the selection state
3. `in_play` zone becomes derived from Timeline
4. Eliminates `PendingTarget` hack (target lives on Play)
5. Eliminates `buildPlaysFromInPlayCards()` bridge
6. UI can work with real domain state, not synthesized views

---

## Research Summary

Research documents in `doc/plays-during-selection/`:

| Document | Key Finding |
|----------|-------------|
| `in-play-zone-audit.md` | 60 usages across 14 files; can derive from Timeline |
| `pending-target-audit.md` | Can be eliminated; bug found in `commitAdd` (stores but doesn't read) |
| `commit-phase-audit.md` | withdraw/stack/add all operate on Plays; `added_in_commit` prevents same-turn stacking |
| `event-flow-audit.md` | Events reference zones but are consumed by presentation; `card_moved` stays |
| `ai-selection-audit.md` | AI bypasses commands, calls `addPlay()` directly; minimal changes needed |
| `card-lifecycle-design.md` | **Critical**: source tracking on Play ensures deck integrity |

---

## Design Decisions

### Decision 1: Derive in_play from Timeline

The `in_play` zone currently serves two purposes:
1. **Zone semantics**: card not in hand, not yet discarded
2. **Play representation**: what cards are committed

We will derive `in_play` from Timeline (`timeline.cardIds()`) rather than maintain
it as a separate list. This requires:

- Adding `source: ?CardSource` to Play (null = hand card, Some = pool clone)
- Modifier source tracking via `ModifierEntry` struct
- Replacing `added_in_commit: bool` with `added_in_phase: Phase`

See `card-lifecycle-design.md` for full lifecycle scenario analysis.

### Decision 2: Phase Tracking

```zig
added_in_phase: enum { selection, commit } = .selection,
```

Plays added during commit phase (via Focus) cannot be stacked same-turn.

### Decision 3: Separate Timelines

Player and enemies have separate `AgentEncounterState` each with their own
`TurnState.timeline`. Visibility is a UI concern, not domain.

### Decision 4: Cleanup Helper

Create `cleanupTimelinePlays(agent_state, agent, registry)` shared by:
- End-of-turn cleanup (after `applyCommittedCosts()`)
- Combat-end cleanup (encounter teardown)

Both paths use identical operations: move hand cards to discard, destroy clones, clear timeline.

### Decision 5: Exhaust Handling

Defer all zone moves to existing `applyCommittedCosts()` pass. Play remains valid
throughout tick even if card will end up in exhaust.

---

## Implementation Plan

### Phase 1: Extend Play struct

```zig
pub const Play = struct {
    action: entity.ID,
    target: ?entity.ID = null,
    source: ?CardSource = null,           // NEW: null = hand, Some = pool clone
    added_in_phase: Phase = .selection,   // NEW: replaces added_in_commit
    // ... modifiers become ModifierEntry
};

pub const Phase = enum { selection, commit };

pub const ModifierEntry = struct {
    card_id: entity.ID,
    source: ?CardSource,
};
```

### Phase 2: Populate source during play creation

- `playActionCard()`: Create Play with source from card origin
- `commitAdd()`: Create Play with source, fix target bug
- `commitStack()`: Create ModifierEntry with source

### Phase 3: Update lifecycle operations

- `cancelActionCard()`: Use `play.source` instead of `in_play_sources`
- `applyCommittedCosts()`: Iterate timeline plays, use `play.source`
- `commitWithdraw()`: Use `play.source` for refund logic

### Phase 4: Add cleanup helper

- Create `cleanupTimelinePlays()` in `src/domain/apply/costs.zig`
- Wire into `agentEndTurnCleanup()`
- Wire into `cleanupEncounter()`

### Phase 5: Derive in_play from Timeline

- Add `Timeline.cardIds()` helper
- Update `CombatState.isInZone(.in_play)` to check Timeline
- Migrate reads from `cs.in_play` to timeline

### Phase 6: Remove obsolete code

- Remove `CombatState.in_play` ArrayList
- Remove `CombatState.in_play_sources` HashMap
- Remove `TurnState.pending_targets`
- Remove `buildPlaysFromInPlayCards()` and `buildPlaysForAgent()`
- Remove `PendingTarget` struct

### Phase 7: Update presentation layer

- Simplify `playerPlays()` to always use Timeline (remove dual-path)
- Remove `buildPlayViewDataFromCard()` workaround
- Update animation positioning to use Timeline slot

---

## Key Files to Modify

**Domain Layer**:
- `src/domain/combat/plays.zig` - Play struct, ModifierEntry, Timeline.cardIds()
- `src/domain/combat/state.zig` - Remove in_play, update isInZone()
- `src/domain/apply/command_handler.zig` - playActionCard, cancel, commit ops
- `src/domain/apply/event_processor.zig` - Remove bridge, update cleanup
- `src/domain/apply/costs.zig` - Add cleanupTimelinePlays(), update iteration

**Presentation Layer**:
- `src/presentation/views/combat/view.zig` - Simplify playerPlays()
- `src/presentation/effects.zig` - Update animation positioning

---

## Test Scenarios

1. Hand card played → resolved → discarded
2. Hand card played → cancelled → returned to hand
3. Pool card played → resolved → clone destroyed
4. Pool card played → cancelled → clone destroyed, cooldown refunded
5. Card with exhausts=true → ends up in exhaust
6. Modifier stacked from hand → resolved → discarded
7. Modifier stacked from pool → resolved → clone destroyed
8. Effect removes opponent's hand card → discarded
9. Effect removes opponent's pool clone → destroyed
10. End of turn with cards still in play → all cleaned up
11. Combat ends with cards in play → deck integrity preserved

---

## Related Documents

- [Timeline UI Plan](timeline-ui-plan.md) - UI requirements driving this change
- [Presentation-Domain Decoupling](presentation-domain-decoupling.md) - Architecture constraints
- [Command-Query Decoupling](command-query-decoupling.md) - Command patterns
