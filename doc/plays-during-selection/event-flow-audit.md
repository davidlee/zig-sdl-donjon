# Event Flow Audit: Card Play Operations

## Overview

This document traces the event flow during card play operations, from initial
play through commit and resolution phases. This research supports a potential
refactor where Play objects would be created during selection phase instead of
at commit phase.

---

## 1. Command Entry Point

### `playActionCard` Command Flow

**File:** `src/domain/apply/command_handler.zig` (lines 231-262)

```
Command received -> CommandHandler.handle() -> CommandHandler.playActionCard()
```

Validation sequence:
1. Verify player in combat
2. Check turn phase is `.player_card_selection`
3. Look up card instance from registry
4. Verify card is in hand OR in always-available/spells-known pool
5. Run `validation.validateCardSelection()` (costs, predicates)
6. Check channel conflicts with existing in-play cards via `wouldConflictWithInPlay()`

If valid, delegates to `playValidCardReservingCosts()`.

---

## 2. Event Emission: `playValidCardReservingCosts`

**File:** `src/domain/apply/command_handler.zig` (lines 67-123)

This function handles both pool cards (always_available, spells_known) and hand
cards differently. Events fire in this order:

### Scenario A: Pool Card (always_available or spells_known)

| Order | Event | Payload | Notes |
|-------|-------|---------|-------|
| 1 | `card_cloned` | `{ clone_id, master_id, actor }` | New ephemeral instance created |
| 2 | `played_action_card` | `{ instance, template, actor, target }` | Uses clone_id |
| 3 | `card_cost_reserved` | `{ stamina, time, actor }` | Costs committed to player state |

### Scenario B: Hand Card

| Order | Event | Payload | Notes |
|-------|-------|---------|-------|
| 1 | `card_moved` | `{ instance, from: .hand, to: .in_play, actor }` | Zone transition |
| 2 | `played_action_card` | `{ instance, template, actor, target }` | Same instance ID |
| 3 | `card_cost_reserved` | `{ stamina, time, actor }` | Costs committed |

### State Mutations (not events)

Alongside events, these state changes occur:
- Card added to `combat_state.in_play` list
- Card source tracked in `combat_state.in_play_sources`
- `actor.stamina.commit(cost)` called
- `actor.time_available` reduced
- If pool card: cooldown set via `cs.setCooldown(master_id, cd)`
- If target provided: `enc_state.current.setPendingTarget(in_play_id, target_id)`

---

## 3. Event Types and Payloads

**File:** `src/domain/events.zig` (lines 37-213)

### Card-Related Events

```zig
played_action_card: struct {
    instance: entity.ID,     // Card instance played (clone for pool cards)
    template: u64,           // Template ID for lookups
    actor: AgentMeta,        // { id, player: bool }
    target: ?entity.ID = null,
}

card_moved: struct {
    instance: entity.ID,
    from: Zone,              // CombatZone enum
    to: Zone,
    actor: AgentMeta,
}

card_cloned: struct {
    clone_id: entity.ID,     // New ephemeral instance
    master_id: entity.ID,    // Original pool card
    actor: AgentMeta,
}

card_cancelled: struct {
    instance: entity.ID,     // master_id for pool cards
    actor: AgentMeta,
}

card_cost_reserved: struct {
    stamina: f32,
    time: f32,
    actor: AgentMeta,
}

card_cost_returned: struct {
    stamina: f32,
    time: f32,
    actor: AgentMeta,
}
```

### AgentMeta Structure
```zig
pub const AgentMeta = struct {
    id: entity.ID,
    player: bool = false,
};
```

---

## 4. Cancel Flow Events

**File:** `src/domain/apply/command_handler.zig` (lines 175-228)

### Scenario A: Pool Card Clone Cancelled

| Order | Event | Payload |
|-------|-------|---------|
| 1 | `card_cancelled` | `{ instance: master_id, actor }` |
| 2 | `card_cost_returned` | `{ stamina, time, actor }` |

Clone is destroyed, cooldown refunded.

### Scenario B: Hand Card Cancelled

| Order | Event | Payload |
|-------|-------|---------|
| 1 | `card_moved` | `{ instance, from: .in_play, to: .hand, actor }` |
| 2 | `card_cost_returned` | `{ stamina, time, actor }` |

---

## 5. Commit Phase: Play Object Creation

**File:** `src/domain/apply/event_processor.zig` (lines 120-144)

When `.commit_phase` transition fires, `buildPlaysFromInPlayCards()` is called:

```
turn_phase_transitioned_to: .commit_phase
  -> buildPlaysFromInPlayCards()
     -> buildPlaysForAgent(player)
     -> buildPlaysForAgent(mob) [for each mob]
```

### buildPlaysForAgent

For each card in `combat_state.in_play`:
1. Read pending target from `enc_state.current.getPendingTarget(card_id)`
2. Call `enc_state.current.addPlay(.{ .action = card_id, .target = pending_target })`

**Key Insight:** Play objects are created from `in_play` zone cards. The Play
stores the `action` (card ID) and `target`. Timeline slot positioning computed
from card template duration and channel requirements.

### After Play Creation

`executeCommitPhaseRules()` runs (commit.zig lines 40-72):
- Iterates `cs.in_play.items`
- Applies `.on_commit` rule effects (cost modifiers, damage modifiers, etc.)
- Targets can be `.my_play` or `.opponent_play`

---

## 6. Event Consumers

### 6.1 Domain: EventProcessor.dispatchEvent

**File:** `src/domain/apply/event_processor.zig` (lines 184-297)

Handles state transitions only:
- `.game_state_transitioned_to` - encounter/game lifecycle
- `.turn_phase_transitioned_to` - phase transitions, AI card play
- Other events: logged but not processed

**Critical behavior:** On `.commit_phase` transition, calls
`buildPlaysFromInPlayCards()` which reads from `cs.in_play.items`.

### 6.2 Presentation: Coordinator.processWorldEvents

**File:** `src/presentation/coordinator.zig` (lines 149-163)

For each event in `current_events`:
1. `effect_system.processEvent(event, ...)` - animation state updates
2. `EffectMapper.map(event)` - convert to visual Effect
3. `combat_log.format(event, ...)` - generate log entry

### 6.3 Presentation: EffectSystem.processEvent

**File:** `src/presentation/effects.zig` (lines 153-160)

```zig
switch (event) {
    .card_cloned => handleCardCloned(vs, master_id, clone_id),
    .played_action_card => finalizeCardAnimation(vs, instance, world),
    else => {},
}
```

**handleCardCloned:** Updates running animation to use clone ID instead of master
**finalizeCardAnimation:** Calculates destination rect from card's position in `in_play` zone

### 6.4 Presentation: EffectMapper.map

**File:** `src/presentation/effects.zig` (lines 59-81)

| Event | Effect | Notes |
|-------|--------|-------|
| `card_moved` -> `.hand` | `card_dealt` | Draw animation |
| `card_moved` -> `.discard` | `card_discarded` | Discard animation |
| `played_action_card` | `card_played` | Covers all plays (hand + pool) |
| `wound_inflicted` | `hit_flash` | |
| `advantage_changed` | `advantage_changed` | |

**Key comment in code:**
> `played_action_card` fires for all played cards, including always_available clones
> (`card_moved` only fires for hand->in_play, not for pool card clones)

### 6.5 Presentation: combat_log.format

**File:** `src/presentation/combat_log.zig` (lines 106-242)

Explicitly ignores card events:
```zig
// Events not worth logging
// .played_action_card,
// .card_moved,
// .card_cancelled,
// .card_cost_reserved,
// .card_cost_returned,
```

---

## 7. Event Handlers That Assume Cards in Zones

### 7.1 finalizeCardAnimation (critical)

**File:** `src/presentation/effects.zig` (lines 188-220)

```zig
fn finalizeCardAnimation(vs, card_id, world) {
    // ...
    const in_play = combat_state.in_play.items;
    // Find index of card in in_play to compute destination rect
    for (in_play, 0..) |id, i| {
        if (id matches card_id) {
            // Calculate position from index
        }
    }
}
```

**Assumption:** Card is in `in_play` zone when this handler runs.

### 7.2 buildPlaysFromInPlayCards (critical)

**File:** `src/domain/apply/event_processor.zig` (lines 120-144)

```zig
for (cs.in_play.items) |card_id| {
    // Create Play from each in_play card
}
```

**Assumption:** Cards to become Plays are in `cs.in_play`.

### 7.3 executeCommitPhaseRules

**File:** `src/domain/apply/effects/commit.zig` (lines 40-72)

```zig
for (cs.in_play.items) |card_id| {
    // Apply on_commit rules
}
```

**Assumption:** Committed cards are in `in_play` zone.

### 7.4 executeResolvePhaseRules

**File:** `src/domain/apply/effects/resolve.zig` (lines 69-137)

```zig
for (cs.in_play.items) |card_id| {
    // Apply on_resolve rules
}
```

**Assumption:** Cards are still in `in_play` during resolution.

### 7.5 Combat View: playerPlays

**File:** `src/presentation/views/combat/view.zig` (lines 539-572)

```zig
// Selection phase: synthesize from in_play cards
const in_play = cs.in_play.items;
// ...
for (in_play) |card_id| {
    if (self.buildPlayViewDataFromCard(...)) |pvd| { ... }
}
```

**Assumption:** During selection phase, view synthesizes PlayViewData from
`in_play` zone cards (not from actual Play objects).

---

## 8. Event Ordering Dependencies

### 8.1 Clone Before Play

For pool cards, `card_cloned` must fire before `played_action_card`:
- `handleCardCloned` updates animation state with new clone ID
- `finalizeCardAnimation` then uses the correct (clone) ID

If order reversed: animation would reference wrong card ID.

### 8.2 Zone State Before Animation Finalization

`finalizeCardAnimation` reads from `cs.in_play.items` to compute destination:
- Card must be added to `in_play` before `played_action_card` event fires
- This is currently guaranteed: `addToInPlayFrom`/`moveCard` called before event push

### 8.3 Phase Transition Timing

`buildPlaysFromInPlayCards` runs on `.commit_phase` transition:
- All `playActionCard` calls must complete before phase transition
- Events from card plays must be processed before commit

---

## 9. Implications for Refactor

### If Plays Created During Selection Phase

Current flow:
```
Selection: card -> in_play zone -> events fire
Commit:    in_play zone -> iterate -> create Plays
```

Proposed flow:
```
Selection: card -> in_play zone + create Play -> events fire
```

### Components That Need Updates

1. **buildPlaysFromInPlayCards** - Would become no-op or removal
2. **playerPlays view function** - Already has dual-path logic (commit vs selection)
3. **Cancel flow** - Would need to remove Play, not just zone transition
4. **Event handlers** - Mostly event-driven, not zone-dependent
5. **finalizeCardAnimation** - Relies on in_play zone index for positioning

### Events That May Need New Variants

Consider new events:
- `play_created` - When Play object instantiated
- `play_cancelled` - When Play removed (vs just card zone change)
- `play_modified` - When modifiers stacked

### Risk Areas

1. **Animation positioning** uses `in_play` zone index - would need alternative
2. **Commit phase rules** iterate `in_play` - could iterate Plays instead
3. **Resolve phase rules** iterate `in_play` - same concern
4. **Commit-phase-only cards** (`added_in_commit` flag) - need clear semantics

---

## 10. Summary: Event Sequence

### Complete Play Flow (Hand Card)

```
1. play_card command received
2. card_moved { from: .hand, to: .in_play }
3. played_action_card { instance, template, actor, target }
4. card_cost_reserved { stamina, time, actor }
   [Selection continues...]
5. end_turn command
6. turn_phase_transitioned_to: .commit_phase
   [Plays created from in_play zone]
7. commit_done command
8. turn_phase_transitioned_to: .tick_resolution
   [Tick resolution runs]
9. stamina_deducted { agent_id, amount, new_value }
10. card_moved { from: .in_play, to: .discard/.exhaust }
11. turn_phase_transitioned_to: .animating
    [Combat continues or ends]
```

### Complete Cancel Flow (Hand Card)

```
1. cancel_card command received
2. card_moved { from: .in_play, to: .hand }
3. card_cost_returned { stamina, time, actor }
```
