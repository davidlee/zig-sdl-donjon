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

### Domain (complete)
- [x] Add `stance_selection` to TurnPhase enum
- [x] Add Stance struct to TurnState in plays.zig
- [x] Add phase transition logic (stance_selection → draw_hand)
- [x] AI random stance selection (sorted uniforms method for barycentric)

### UI Logic (complete)
- [x] Add stance_cursor to CombatUIState
- [x] Implement barycentric coordinate calculation (screen coords → weights)
- [x] Create stance triangle view (logic + input handling)
- [x] Wire view into combat mod.zig exports
- [x] Add confirm_stance command + handler
- [x] Tests for barycentric math

### UI Rendering (in progress)
- [ ] Integrate stance view into combat view (renderables + handleInput) — **do this first, works with placeholder rects**
- [ ] Add triangle/polygon rendering capability (graphics layer work) — blocked, needs SDL GPU or Bresenham
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

### 2026-01-11: Domain layer complete

**Files modified:**
- `src/domain/combat/types.zig` — added `stance_selection` to TurnPhase, `confirm_stance` to TurnEvent, updated FSM initial state
- `src/domain/combat/plays.zig` — added `Stance` struct, added `stance` field to TurnState, updated clear()
- `src/domain/combat/encounter.zig` — added FSM transitions, added `forceTransitionTo` for tests
- `src/domain/ai.zig` — added `selectStanceFn` to Director interface, implemented in all directors using sorted uniforms method
- `src/domain/apply/event_processor.zig` — added stance_selection phase handler, updated encounter entry and animating handler
- `src/testing/integration/harness.zig` — updated beginSelection to bypass stance phase for tests

**Flow:**
1. Encounter starts → `stance_selection` phase
2. AI selects random stance via Director.selectStance()
3. Player confirms stance → transition to `draw_hand`
4. `draw_hand` does shuffle/draw → transition to `player_card_selection`
5. After `animating`, next turn goes to `stance_selection` (not draw_hand)

**Next:** UI implementation (stance triangle view, barycentric coords, input handling)

### 2026-01-11: UI layer partially complete

**Files added/modified:**
- `src/presentation/view_state.zig` — added `StanceCursor` struct, added `stance_cursor` field to `CombatUIState`
- `src/presentation/views/combat/stance.zig` — NEW: complete stance selection view with:
  - `Triangle` struct: geometry, barycentric coordinate math, point clamping
  - `View` struct: input handling (mouse follow, click-to-lock, space-to-confirm), renderable generation
  - Unit tests for barycentric math (vertices, center, outside, sum-to-1)
- `src/presentation/views/combat/mod.zig` — exports `StanceView`, `StanceTriangle`
- `src/commands.zig` — added `Stance` struct, added `confirm_stance` command
- `src/domain/apply/command_handler.zig` — added `confirmStance` handler (stores stance, transitions to draw_hand)

**What works:**
- Barycentric coordinate calculation (screen point → weights)
- Point clamping to triangle boundary
- Input handling logic (mouse tracking, lock toggle, space confirm)
- Command flow (confirm_stance → store in TurnState → transition to draw_hand)
- All tests pass

**BLOCKING: Triangle/polygon rendering**

Current `Renderable` union only supports: `sprite`, `text`, `filled_rect`, `card`, `log_pane`.
The stance.zig view attempts to draw triangle edges using `filled_rect` but this only works for axis-aligned rectangles.

To properly render the triangle, need one of:
1. **New Renderable type for polygons** — add `.polygon` or `.triangle` variant
2. **SDL GPU support** — use `zig-sdl3/src/gpu.zig` for Direct3D triangle rendering
3. **Algorithmic line drawing** — implement Bresenham or similar for arbitrary lines

For circles (the inscribed circle in the spec mockup):
- Midpoint Circle Algorithm for outlines
- Triangle fan with `SDL_RenderDrawLines` for filled
- Or render to texture once and reuse

**Remaining tasks:**
- [ ] Add triangle/polygon rendering capability (requires graphics layer work)
- [ ] Integrate stance view into combat view's renderables() and handleInput()
- [ ] Integration test for full phase flow

**Files to modify for integration:**
- `src/presentation/views/combat/view.zig` — check phase in renderables/handleInput, dispatch to stance view during stance_selection
- `src/presentation/views/types.zig` — add new Renderable variant if needed
- `src/presentation/graphics.zig` — implement new rendering primitives

**NOTE:** Currently the game still shows timeline/carousel/enemies during stance_selection phase.
The combat view's `renderables()` and `handleInput()` methods need a phase check at the top:

```zig
// In View.renderables():
if (self.inPhase(.stance_selection)) {
    // Render stance triangle UI instead of cards/timeline
    var stance_view = stance.View.init(center, radius);
    try stance_view.appendRenderables(alloc, &list, vs);
    return list;
}
// ... rest of normal combat rendering

// In View.handleInput():
if (self.inPhase(.stance_selection)) {
    var stance_view = stance.View.init(center, radius);
    return stance_view.handleInput(event, vs);
}
// ... rest of normal input handling
```

This is independent of the triangle rendering blocker — can be done now with placeholder rectangles.

**Code quality concern:** `View.handleInput()` in combat/view.zig is already sprawling (~70 lines, nested switches). Adding stance_selection handling risks making it a monolithic tangle. Consider:
- Phase-specific input handlers (e.g., `handleStanceInput`, `handleSelectionInput`, `handleCommitInput`)
- Dispatch at top level based on phase, delegate to focused handlers
- Or extract to separate modules like we did with stance.zig

Same applies to `renderables()` — currently ~180 lines with lots of conditional logic.
