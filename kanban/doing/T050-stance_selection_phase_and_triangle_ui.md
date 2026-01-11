# T050: Stance Selection Phase & Triangle UI
Created: 2026-01-11

## Problem statement / value driver

Add pre-round stance commitment. Players (and AI) choose attack/defense/movement
weighting before drawing cards. Weights modify contested roll scores.

### Scope - goals

1. Add `stance_selection` TurnPhase before `draw_hand`
2. Implement stance triangle UI (visual selector with barycentric coordinates)
3. AI mechanism for random/weighted stance selection
4. Wire stance weights into agent/encounter state

### Scope - non-goals

- Wiring weights into contested roll formula (future task)
- Partial hit damage scaling
- Combat log presentation changes

## Background

### Relevant documents

- `doc/artefacts/contested_rolls_and_stance_triangle.md` — full spec, UI mockups

### Key files

| File | Change |
|------|--------|
| `src/domain/combat/types.zig` | Add `stance_selection` to TurnPhase |
| `src/domain/combat/plays.zig` | Add `Stance` struct, add to `TurnState` |
| `src/domain/combat/encounter.zig` | Initialize phase to `stance_selection` |
| `src/presentation/view_state.zig` | Add `stance_cursor` to CombatUIState |
| `src/presentation/views/combat/stance.zig` | NEW: stance triangle view |
| `src/presentation/views/combat/mod.zig` | Dispatch to stance view in phase |
| `src/domain/apply/phase_transitions.zig` | Handle stance → draw transition |

## Changes Required

### Domain

Add `Stance` to `TurnState` in `src/domain/combat/plays.zig`:
```zig
pub const Stance = struct {
    attack: f32 = 1.0 / 3.0,    // barycentric, sums to 1.0
    defense: f32 = 1.0 / 3.0,
    movement: f32 = 1.0 / 3.0,
};

pub const TurnState = struct {
    timeline: Timeline = .{},
    focus_spent: f32 = 0,
    stack_focus_paid: bool = false,
    stance: Stance = .{},  // new - cleared with rest of TurnState
    // ...
};
```
Rationale: stance is per-turn, and `TurnState` already gets pushed to `TurnHistory`,
giving us stance history for free.

### UI State

Add to CombatUIState:
```zig
stance_cursor: struct {
    position: ?[2]f32,  // null = centered, else normalized triangle coords
    locked: bool,
} = .{ .position = null, .locked = false },
```

### Visual Design

Triangle inscribed in circle inscribed in square ("Squaring the Circle").
- Cursor follows mouse (no drag)
- Click to lock, click again to unlock
- Space/button confirms stance
- Vertices: ⚔️ Attack (top), 🛡️ Defence (bottom-left), 🦵 Position (bottom-right)

### AI Stance Selection

AI needs a mechanism to select stance. Options:
- Random uniform (baseline)
- Weighted by situation (aggressive when winning, defensive when losing)
- Card-aware (if hand favours attack, lean attack)

Start with random uniform; refine later.

### Decisions

1. **Stance lives in `TurnState`** — per-turn, cleared automatically, history via TurnHistory
2. **Simultaneous double-blind selection** — all combatants (player + AI) select during
   `stance_selection` phase, not revealed until phase ends
3. **AI vs AI uses same flow** — no special casing, both select double-blind

## Tasks / Sequence of Work

- [ ] Add `stance_selection` to TurnPhase enum
- [ ] Add Stance struct to TurnState in plays.zig
- [ ] Add phase transition logic (stance_selection → draw_hand)
- [ ] Add stance_cursor to CombatUIState
- [ ] Implement barycentric coordinate calculation
- [ ] Create stance triangle view (render + input handling)
- [ ] Wire view into combat mod dispatch
- [ ] AI random stance selection
- [ ] Tests for barycentric math
- [ ] Integration test for phase flow

## Test / Verification Strategy

### success criteria / ACs

- Player can select stance via triangle UI before drawing cards
- AI agents automatically select stance
- Weights stored correctly and sum to 1.0
- Phase transitions work: stance → draw → card selection...

### unit tests

- Barycentric coordinate calculation (point → weights)
- Weights always sum to 1.0
- Edge cases: vertices, edges, center

### integration tests

- Full turn cycle includes stance phase
- AI completes stance selection

### user acceptance

- Visual: triangle renders correctly, cursor tracks mouse
- Interaction: click locks, space confirms
- Feedback: weights display updates live

## Quality Concerns / Risks

- Barycentric math edge cases (degenerate triangles, precision)
- Input handling: mouse outside triangle snaps to edge
- Ensure phase can't be skipped/bypassed

## Progress Log / Notes
