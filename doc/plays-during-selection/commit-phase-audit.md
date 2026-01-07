# Commit Phase Interactions Audit

Research for: Refactor where Play objects are created during selection phase.

## Executive Summary

Currently, Play objects are created at **two distinct points**:

1. **Selection phase** cards go to `in_play` zone but do NOT create Plays
2. **Transition to commit_phase** creates Plays from `in_play` cards via `buildPlaysFromInPlayCards()`
3. **Commit phase operations** (`commitAdd`, `commitStack`, `commitWithdraw`) manipulate Plays differently

This creates an asymmetry: selection-phase cards exist only as zone membership until commit phase begins.

---

## 1. commitWithdraw

**Location**: `src/domain/apply/command_handler.zig:269-305`

### What it does

Removes a **Play AND its card** from the timeline:

1. **Finds the play** by card ID using `findPlayByCard(card_id)`
2. **Validates** play has no modifiers (cannot withdraw if stacked)
3. **Spends focus** (1 focus cost via `FOCUS_COST`)
4. **Moves card** from `in_play` zone back to `hand`
5. **Refunds resources**: uncommits stamina, restores time
6. **Removes the Play** from timeline via `removePlay(play_index)`

### Key constraint

```zig
// validation.zig:110-112
pub fn canWithdrawPlay(play: *const combat.Play) bool {
    return play.modifier_stack_len == 0;
}
```

A play with stacked modifiers **cannot be withdrawn**. The modifiers are committed and cannot be easily undone.

### Asymmetry with selection phase

In **selection phase**, `cancelActionCard` achieves similar result (card from `in_play` to `hand`, refund costs) but:
- No Play exists yet (no timeline entry to remove)
- No focus cost
- Clears `pending_targets` separately

---

## 2. commitStack

**Location**: `src/domain/apply/command_handler.zig:362-389`

### What it does

Adds a **modifier card to an existing Play's stack**:

1. **Validates** via `validateStack()`:
   - Target play exists and `canStack()` returns true
   - Card is in hand or always_available pool
   - Card is a modifier OR same template as action (for stacking copies)
   - Modifier can attach (predicate check)
   - No channel conflicts between modifier and existing stack
   - Stack not full (`max_modifiers = 4`)

2. **Calculates focus cost**:
   - Base focus: 1 (paid once per turn for stacking)
   - Card focus: from `card.template.cost.focus`
   - Tracks `stack_focus_paid` to avoid double-charging base

3. **Applies stack** via `applyStack()`:
   - Moves card to `in_play` (clones if pool card)
   - Adds card ID to `target_play.modifier_stack`
   - Updates focus tracking

### The canStack() check

```zig
// plays.zig:49-51
pub fn canStack(self: Play) bool {
    return !self.added_in_commit;
}
```

Plays added via `commitAdd` have `added_in_commit = true`, blocking stacking on them **within the same turn**.

### Important: Stacking does NOT create a new Play

The modifier card:
- Goes to `in_play` zone
- Gets added to existing Play's `modifier_stack_buf`
- Does NOT get its own Play/TimeSlot

---

## 3. commitAdd

**Location**: `src/domain/apply/command_handler.zig:309-357`

### What it does

Creates a **new Play during commit phase**:

1. **Validates**:
   - Card in hand or always_available pool
   - Card passes selection validation for commit_phase
   - No channel conflicts with **existing plays** (not `in_play` zone)

2. **Spends focus** (1 focus)

3. **Plays card** via `playValidCardReservingCosts()`:
   - Moves to `in_play` zone
   - Commits stamina, reserves time
   - Handles pool card cloning

4. **Creates Play with `added_in_commit = true`**:

```zig
try enc_state.current.addPlay(.{
    .action = in_play_id,
    .added_in_commit = true, // Cannot be stacked this turn
}, &self.world.card_registry);
```

### Key difference from selection phase

| Aspect | Selection Phase | Commit Phase (commitAdd) |
|--------|-----------------|--------------------------|
| Focus cost | None | 1 focus |
| Play created | No (deferred) | Yes (immediately) |
| Can be stacked | Yes (after commit begins) | No (same turn) |
| Channel conflict check | Against `in_play` zone | Against existing Plays |

---

## 4. The added_in_commit Flag

**Location**: `src/domain/combat/plays.zig:28`

```zig
added_in_commit: bool = false, // true if added via Focus, cannot be stacked
```

### Purpose

Prevents **same-turn stacking exploitation**:

1. Player enters commit phase with existing plays (from selection)
2. Player uses Focus to `commitAdd` a new action card
3. Player CANNOT stack modifiers on that new play this turn

This prevents gaming the Focus mechanic by:
- Adding a card just to stack it (getting both capabilities for 1 focus)
- Adding cards based on what opponent revealed, then immediately enhancing them

### Usage

Only checked in `Play.canStack()`, which is called by `validateStack()`.

---

## 5. Asymmetries: Selection vs Commit Phase

### Card State During Selection Phase

```
Selection Phase:
  Card in hand --> Card in in_play zone
                   (stamina committed, time reserved)
                   (pending_target stored separately)
                   NO Play exists yet
```

### Transition to Commit Phase

```zig
// event_processor.zig:133-144
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

This bridges the gap: converts `in_play` zone membership into actual Plays.

### Channel Conflict Checks

| Phase | Check Against |
|-------|---------------|
| Selection | `in_play` zone cards (`wouldConflictWithInPlay`) |
| Commit Add | Existing Plays (`wouldConflictOnChannel`) |

These are functionally equivalent BUT use different data structures:
- Selection: iterates `combat_state.in_play.items`
- Commit: iterates `TurnState.timeline.slots()`

---

## 6. Summary of Key Findings

### Current Flow

```
Selection Phase:
  playActionCard() --> card to in_play zone, no Play

Transition:
  buildPlaysFromInPlayCards() --> creates Plays from in_play cards

Commit Phase:
  commitAdd() --> creates Play immediately (added_in_commit=true)
  commitStack() --> modifies existing Play's modifier stack
  commitWithdraw() --> removes Play AND returns card to hand
```

### Implications for "Plays During Selection" Refactor

If Plays were created during selection instead of at transition:

1. **commitWithdraw would be redundant** with `cancelActionCard` (both remove plays)
2. **Channel conflict logic** would unify (always check Plays, not zones)
3. **pending_targets** might become unnecessary (stored in Play.target directly)
4. **added_in_commit** semantics need review - what distinguishes "selected" from "focus-added"?
5. **buildPlaysFromInPlayCards()** becomes a no-op or verification step

### Open Questions

1. Should selection-phase plays also set a flag (e.g., `added_in_selection`)?
2. How to handle modifier attachment during selection (currently not allowed)?
3. Would unifying the model simplify or complicate the cancel/withdraw distinction?
