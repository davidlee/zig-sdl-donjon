# State Management Roadmap

## Context

This document outlines remaining state management work following the FSM refactoring completed in January 2026.

### What Was Done

We split the monolithic `GameState` FSM into two separate concerns:

1. **GameState** (world.zig) - High-level app/context:
   - `splash`, `in_encounter`, `encounter_summary`, `world_map`

2. **TurnPhase** (combat.zig, owned by Encounter) - Combat turn flow:
   - `draw_hand`, `player_card_selection`, `commit_phase`, `tick_resolution`, `player_reaction`, `animating`

World provides facade methods: `turnPhase()`, `inTurnPhase()`, `transitionTurnTo()`.

Events split into `game_state_transitioned_to` and `turn_phase_transitioned_to`.

### Original Design Goals (Not Yet Implemented)

From the design discussion, several items remain:

## 1. StateSnapshot for Presentation

**Problem**: Views currently query World directly via live methods. This creates implicit coupling and makes testing harder.

**Proposed Solution**: Coordinator builds a snapshot struct once per frame, passes to views.

```zig
const StateSnapshot = struct {
    app: GameState,              // splash | in_encounter | ...
    turn_phase: ?TurnPhase,      // null if not in encounter
    can_accept_input: bool,      // derived from phase + animations
    // ... other derived state
};
```

**Benefits**:
- Clear contract between domain and presentation
- Views receive exactly what they need
- Easier to test views with constructed snapshots
- Single source of truth per frame

**When to do this**: When adding more views or when the current approach becomes unwieldy.

## 2. Animation State Model

**Problem**: `animating` is currently a TurnPhase state, but animation is orthogonal to game logic.

**Two animation flavours identified**:

| Type | Scope | Blocks input? | Model |
|------|-------|---------------|-------|
| Local tweens | Per-element | No (or just that element) | EffectSystem |
| Priority sequences | Global | Yes, until resolved | Queue |

**Proposed Solution**:
- Remove `animating` from TurnPhase
- `can_accept_input` becomes a derived property: `!effect_system.hasPrioritySequence()`
- FSM stays in its logical state (e.g., `tick_resolution`) while animations play

**When to do this**: When implementing actual animations beyond placeholder state.

## 3. Reaction Windows & Interactive Draw

**Problem**: Current turn flow is linear. Future features need nested interruptible contexts:

- **Interactive draw**: Player draws cards one at a time from chosen piles
- **Reaction windows**: After certain triggers, opportunity for reaction cards

**Proposed Model**: Pushdown automaton (stack) for turn context:

```
commit_phase
  → player plays Attack
    → reaction_window (opponent)
      → opponent plays Parry
        → reaction_window (player)
          → pass
        ← resolve Parry
    ← resolve Attack (modified)
```

**Implementation Notes**:
- Could be implicit in call structure during resolution (recursion = push, return = pop)
- FSM just needs to track "in reaction window" for UI purposes
- `player_reaction` TurnPhase exists but is currently unused

**When to do this**: When implementing the reaction card system.

## 4. Further GameState Decomposition

**Current state**: GameState handles both app lifecycle and game context together.

**Potential future split**:

| FSM | States | When to split |
|-----|--------|---------------|
| AppState | splash, in_game, paused, settings | When adding pause menu |
| GameContext | world_map, encounter, town, dungeon | When adding world map navigation |

**Current approach is fine** until one of these features is needed.

## 5. ViewState Consolidation

**Observation**: `CombatUIState` in ViewState (drag, hover, selection, log_scroll) is essentially a presentation-layer FSM.

**Potential improvement**: Make UI interaction states more explicit:
- `idle` - waiting for input
- `dragging` - card being dragged
- `targeting` - selecting a target
- `scrolling` - log scroll active

**When to do this**: If UI state transitions become complex or buggy.

---

## File Reference

Key files for state management:

| File | Contents |
|------|----------|
| `src/domain/world.zig` | GameState, GameEvent, FSM, facade methods |
| `src/domain/combat.zig` | TurnPhase, TurnEvent, TurnFSM on Encounter |
| `src/domain/events.zig` | Event union with state transition events |
| `src/domain/apply.zig` | EventProcessor handles state transitions |
| `src/presentation/coordinator.zig` | Maps GameState to active View |
| `src/presentation/view_state.zig` | ViewState, CombatUIState |
| `src/presentation/views/combat_view.zig` | Uses turn_phase for UI decisions |

## Summary

Priority order for remaining work:

1. **Animation model** - Needed when implementing actual animations
2. **Reaction windows** - Core gameplay feature, moderate complexity
3. **Interactive draw** - Enhancement to draw phase
4. **StateSnapshot** - Architectural improvement, lower urgency
5. **Further decomposition** - Only when specific features require it
