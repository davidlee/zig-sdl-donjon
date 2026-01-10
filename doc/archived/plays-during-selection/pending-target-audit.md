# PendingTarget Audit

> Research document for plays-during-selection refactor.
> Generated: 2026-01-07

## Overview

`PendingTarget` is a stopgap mechanism for storing target selection during the selection phase, before Play objects exist. This document audits all usages to inform the refactor where Play objects would be created immediately during selection.

---

## Definition

**File**: `src/domain/combat/plays.zig:367-371`

```zig
/// Target selected for a card before Play is created (during selection phase).
pub const PendingTarget = struct {
    card_id: entity.ID,
    target_id: entity.ID,
};
```

**Storage**: `TurnState.pending_targets` (line 379)
```zig
pending_targets: [Timeline.max_slots]?PendingTarget = .{null} ** Timeline.max_slots,
```

Fixed-size array matching Timeline capacity. Stores card->target mappings before Plays exist.

---

## Helper Methods on TurnState

### setPendingTarget

**File**: `src/domain/combat/plays.zig:399-408`

Stores a target for a card. Finds empty slot or overwrites existing entry for same card.

```zig
pub fn setPendingTarget(self: *TurnState, card_id: entity.ID, target_id: entity.ID) void
```

**Note**: Overwrites if card already has a pending target (supports target switching).

### getPendingTarget

**File**: `src/domain/combat/plays.zig:411-418`

Retrieves stored target for a card, if any.

```zig
pub fn getPendingTarget(self: *const TurnState, card_id: entity.ID) ?entity.ID
```

### clearPendingTarget

**File**: `src/domain/combat/plays.zig:421-429`

Removes target for a card (used when card is cancelled).

```zig
pub fn clearPendingTarget(self: *TurnState, card_id: entity.ID) void
```

### TurnState.clear

**File**: `src/domain/combat/plays.zig:391-396`

Resets all pending targets to null (end of turn cleanup).

---

## Usage Sites

### 1. SET: playActionCard (Selection Phase)

**File**: `src/domain/apply/command_handler.zig:254-259`

```zig
// Store pending target if provided (for .single targeting cards)
if (target) |target_id| {
    const enc = self.world.encounter orelse return CommandError.BadInvariant;
    const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;
    enc_state.current.setPendingTarget(in_play_id, target_id);
}
```

**Lifecycle**: Called when player plays a card during selection phase with a target.

**With Play.target**: Would set `play.target = target_id` directly on the newly-created Play.

### 2. SET: commitAdd (Commit Phase)

**File**: `src/domain/apply/command_handler.zig:346-348`

```zig
// Store pending target if provided (for .single targeting cards)
if (target) |target_id| {
    enc_state.current.setPendingTarget(in_play_id, target_id);
}
```

Followed immediately by:
```zig
// Add to plays with added_in_commit flag
try enc_state.current.addPlay(.{
    .action = in_play_id,
    .added_in_commit = true,
}, &self.world.card_registry);
```

**Lifecycle**: Called when adding a card during commit phase (costs Focus).

**Note**: This is INCONSISTENT - it stores in pending_targets, then creates a Play without reading it back. The Play's target field would be null until `buildPlaysForAgent` runs.

**With Play.target**: Would set `play.target = target_id` directly in the addPlay call:
```zig
try enc_state.current.addPlay(.{
    .action = in_play_id,
    .target = target_id,  // <-- direct assignment
    .added_in_commit = true,
}, &self.world.card_registry);
```

### 3. GET: buildPlaysForAgent (Commit Phase Entry)

**File**: `src/domain/apply/event_processor.zig:133-144`

```zig
fn buildPlaysForAgent(self: *EventProcessor, agent: *Agent, enc: *combat.Encounter) !void {
    const enc_state = enc.stateFor(agent.id) orelse return;
    const cs = agent.combat_state orelse return;
    for (cs.in_play.items) |card_id| {
        const pending_target = enc_state.current.getPendingTarget(card_id);
        try enc_state.current.addPlay(.{
            .action = card_id,
            .target = pending_target,
        }, &self.world.card_registry);
    }
}
```

**Lifecycle**: Called at selection->commit phase transition. Converts in_play cards to Play structs, reading pending targets.

**With Play.target**: This function becomes UNNECESSARY. Plays already exist with targets set.

### 4. CLEAR: cancelCard (Selection Phase)

**File**: `src/domain/apply/command_handler.zig:219-224`

```zig
// Clear any pending target for this card
if (self.world.encounter) |enc| {
    if (enc.stateFor(player.id)) |enc_state| {
        enc_state.current.clearPendingTarget(id);
    }
}
```

**Lifecycle**: Called when player cancels a card during selection phase (returns to hand).

**With Play.target**: Would remove the Play from Timeline. Target cleanup is implicit.

### 5. CLEAR: TurnState.clear (End of Turn)

**File**: `src/domain/combat/plays.zig:395`

```zig
self.pending_targets = .{null} ** Timeline.max_slots;
```

Called via `AgentEncounterState.endTurn()` at line 556-558.

**Lifecycle**: End of each turn, resets all state for next turn.

**With Play.target**: No change needed - Timeline already cleared.

---

## Re-exports

The type is re-exported for external access:

- `src/domain/combat/mod.zig:44`: `pub const PendingTarget = plays.PendingTarget;`
- `src/domain/combat.zig:45`: `pub const PendingTarget = combat_mod.PendingTarget;`

These can be removed after the refactor.

---

## Edge Cases

### Target Switching

`setPendingTarget` handles target switching by overwriting existing entries:

```zig
if (slot.* == null or slot.*.?.card_id.eql(card_id)) {
    slot.* = .{ .card_id = card_id, .target_id = target_id };
    return;
}
```

**With Play.target**: Would find the Play by card_id and update `play.target`. Timeline already supports lookup by action card ID (via iteration).

### Multi-Target (elected_n)

Currently stubbed out. `TargetQuery.elected_n` exists but:

```zig
// src/domain/apply/targeting.zig:107-109
.elected_n => {
    // TODO: requires Play.targets (multi-target)
}
```

**With Play.target**: Would need `Play.targets: []entity.ID` (bounded) instead of single `?entity.ID`.

### Cards Without Targets

Cards with `TargetQuery.all_enemies` or `TargetQuery.self` don't need pending targets. `getPendingTarget` returns null, which is passed through correctly.

### Commit Phase Add Inconsistency

As noted above, `commitAdd` stores pending target but doesn't read it back when creating the Play. This is a bug that doesn't manifest because:
1. Commit phase adds are immediately followed by resolution
2. But the target IS missing from the Play struct

This bug would be fixed by the refactor since target goes directly on Play.

---

## Summary: What Would Change

| Current | With Play.target |
|---------|------------------|
| `setPendingTarget(card_id, target)` | `play.target = target` |
| `getPendingTarget(card_id)` | (removed - read from Play directly) |
| `clearPendingTarget(card_id)` | (removed - Play removal handles it) |
| `pending_targets` array | (removed from TurnState) |
| `buildPlaysFromInPlayCards()` | (removed - Plays exist already) |
| `PendingTarget` struct | (removed) |

### Files Requiring Changes

1. **src/domain/combat/plays.zig**
   - Remove `PendingTarget` struct (lines 367-371)
   - Remove `pending_targets` field from `TurnState` (line 379)
   - Remove `setPendingTarget`, `getPendingTarget`, `clearPendingTarget` methods
   - Update `clear()` to remove pending_targets reset

2. **src/domain/combat/mod.zig**
   - Remove `PendingTarget` re-export (line 44)

3. **src/domain/combat.zig**
   - Remove `PendingTarget` re-export (line 45)

4. **src/domain/apply/command_handler.zig**
   - `playActionCard`: Create Play with target directly instead of storing pending
   - `cancelCard`: Remove clearPendingTarget call (Play removal suffices)
   - `commitAdd`: Pass target directly to addPlay

5. **src/domain/apply/event_processor.zig**
   - Remove `buildPlaysFromInPlayCards()` function entirely
   - Remove `buildPlaysForAgent()` function entirely
   - Update commit phase entry to skip this step

---

## Questions for Design

1. **commitAdd bug**: Should we fix the current bug before or during the refactor?

2. **Play lookup by card_id**: Timeline needs efficient lookup for target switching. Current iteration is O(n) but n is small (max_slots = 8).

3. **in_play zone**: If Plays exist during selection, is `in_play` zone redundant? Could derive it from Timeline.plays.

4. **Event sequencing**: `card_moved` events currently fire when card enters `in_play`. Would this change if Play creation is the primary action?
