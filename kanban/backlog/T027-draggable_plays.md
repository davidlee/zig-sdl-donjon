# T027: Draggable Card Plays
Created: 2026-01-08

**Blocked by**: T028 (Multi-Weapon Domain Support)

## Problem statement / value driver

Card interaction during selection phase is too binary - click toggles between hand and timeline. Need richer interaction model to support:
- Reordering cards on timeline
- Multi-lane placement (primary/offhand) for future multi-weapon combat

### Scope - goals

- Distinguish click (<250ms) from drag
- Click: toggle card between hand ↔ timeline (preserve current behavior)
- Drag from hand: place card on timeline at specific position
- Drag on timeline: reorder within lane
- Drag between lanes: move card from primary → offhand (or vice versa)
- Visual feedback: highlight valid drop zones during drag

### Scope - non-goals

- Domain changes (see T028)
- Actual multi-weapon combat resolution (see `doc/issues/multi_weapon_combat.md`)
- Touch/mobile input

## Background

### Relevant documents

- `doc/issues/multi_weapon_combat.md` - design debt driving this work
- `doc/artefacts/draggable_plays_design.md` - detailed design (created 2026-01-08)

### Key files

- `src/presentation/view_state.zig` - `CombatUIState`, drag state
- `src/presentation/views/combat/` - hand, timeline panels
- `src/presentation/coordinator.zig` - input loop

### Existing systems (audit 2026-01-08)

**Current drag infrastructure** (commit phase only, modifiers only):
- `DragState` in `view_state.zig`: `id`, `original_pos`, `target`, `target_play_index`
- `isCardDraggable()`: returns true only for modifiers that are playable
- `handleDragging()`: hit tests timeline plays, validates modifier attachment via snapshot
- On release with valid `target_play_index` → dispatches `commit_stack` command

**Current click handling**:
- `mouse_down`: if draggable → set drag state; else record `clicked` position
- `mouse_up`: if dragging → check target, clear drag; else compare click/release pos → `onClick()`
- `onClick()`: immediately plays/commits card or cancels from timeline
- No timing-based click vs drag - only position comparison (same pos = click)

**Gap**: Regular cards (non-modifiers) click-toggle instantly. No drag-to-position, no reorder, no lane switching.

**Phase distinction**:
- Selection phase: free drag/reorder for all cards (this task)
- Commit phase: reordering has domain rules (costs Focus, some cards can't move) - domain should already handle validation

**Commands** (`src/commands.zig`):
- Selection: `play_card`, `cancel_card` - no reorder/move command yet
- Commit: `commit_withdraw`, `commit_add`, `commit_stack`

**Domain mapping**:
- Lane == channel (weapon, off_hand, footwork, conc)
- Plays have `time_start: f32` (0.0-1.0 within tick, 0.1 = 100ms granularity)
- `TimelinePlays` keeps slots sorted by `time_start`, auto-snaps on insert
- Reordering = changing `time_start`, order changes only if you cross another play's time
- New command likely: `move_play { card_id, new_time_start }` or `{ card_id, new_time_start, new_channel? }`

## Changes Required

### Decisions

1. **Lanes** - already exist in timeline: `weapon`, `off_hand`, `footwork`, `conc`
2. **Offhand visibility** - always visible (as seen in current UI)
3. **Validation** - domain owns validity via DTOs/coordinator queries (existing pattern, may need extension)

## Tasks / Sequence of Work

1. Audit current card interaction code path (click handling, drag state)
2. Design: lane model, drop zone feedback, state machine for drag
3. Implement click vs drag detection (mouse down → mouse up timing)
4. Implement drag visual (card follows cursor, ghost in original position?)
5. Implement drop zone highlighting on timeline
6. Implement reorder within lane
7. Implement lane switching (primary ↔ offhand)
8. Tests

## Test / Verification Strategy

### success criteria / ACs

- [ ] Quick click (<250ms) toggles card as before
- [ ] Dragging card from hand shows it following cursor
- [ ] Valid drop positions highlighted during drag
- [ ] Can reorder cards on timeline via drag
- [ ] Can drag card between primary/offhand lanes
- [ ] Invalid drops return card to original position

### user acceptance

- Feels responsive and intuitive
- No regression in quick-click workflow

## Progress Log / Notes

### 2026-01-08 - Research & Design

Audited existing code, identified complications:

1. **Click timing**: Need to add timestamp to ViewState (currently position-based only)
2. **Channel override**: Play doesn't store channel - derived from template. Need `Play.channel_override` for dual-wielding lane switch
3. **No move command**: Need `move_play { card_id, new_time_start, new_channel? }`
4. **Modifier drag coexists**: Commit phase modifier→play drag stays separate from selection phase position drag

Created detailed design doc at `doc/artefacts/draggable_plays_design.md`.

**Key design decisions needed**:
- Channel override validation - can only switch lanes between weapon/off_hand if both have weapons equipped
- Range validation - natural weapons (fists) have different range than equipped weapons. Orange border = "can drop but no valid targets in range"

### 2026-01-09 - Core Implementation (Timeline Reordering)

**Implemented**:

1. **Click vs drag timing** (`view_state.zig`, `combat/view.zig`)
   - Added `click_time: ?u64` to `ViewState` (nanosecond timestamp from SDL)
   - 250ms threshold (`click_threshold_ns`) distinguishes click from drag
   - Quick release (<250ms) = click, long hold + move = drag

2. **Extended DragState** (`view_state.zig`)
   - Added `start_time: u64`, `source: DragSource` (hand/timeline)
   - Added `target_time: ?f32`, `target_channel: ?ChannelSet`, `is_valid_drop: bool`
   - Kept existing `target_play_index` for commit phase modifier stacking

3. **Selection phase dragging** (`combat/view.zig`)
   - `shouldStartImmediateDrag()`: only commit phase modifiers start drag on mouse_down
   - Other cards record click time; drag starts in `mouse_motion` after 250ms hold
   - `isCardDraggable()`: selection phase allows all playable cards + timeline cards
   - `handleDragging()`: tracks drop position via `TimelineView.hitTestDrop()`
   - `handleRelease()`: dispatches `move_play` for timeline drags with valid drop

4. **Timeline hit detection** (`combat/play.zig`)
   - `timeline_axis.xToTime()`: converts X position to time (0.0-1.0), floors to 0.1 slots
   - `TimelineView.yToLane()`: converts Y to lane index (0-3)
   - `TimelineView.hitTestDrop()`: returns `DropPosition { time, channel }` or null

5. **Visual feedback during drag** (`combat/play.zig`, `combat/view.zig`)
   - Duration bar renders at target position (not current) when dragging
   - Card at old position hidden while dragging
   - Dragged card follows cursor (rendered in `render()` at mouse position)

6. **Bug fix in movePlay** (`command_handler.zig`)
   - Fixed index-out-of-bounds panic: was accessing `slots()[play_index]` after removal
   - Now saves `old_time_start` before `removePlay()` for rollback on conflict

**Key files changed**:
- `src/presentation/view_state.zig` - DragState, ViewState.click_time
- `src/presentation/views/combat/view.zig` - input handling, drag logic, render
- `src/presentation/views/combat/play.zig` - timeline hit detection, visual feedback
- `src/domain/apply/command_handler.zig` - movePlay bug fix

**What works**:
- [x] Quick click (<250ms) toggles card as before
- [x] Hold + drag on timeline card shows card following cursor
- [x] Duration bar preview at drop position
- [x] Can reorder cards on timeline via drag (time repositioning)
- [x] Invalid drops (conflict) restore card to original position

**Not yet implemented**:
- [ ] Drag from hand to specific timeline position (currently click-to-play only)
- [ ] Lane switching (weapon ↔ off_hand) - validation exists in domain (`isValidChannelSwitch`) but UI doesn't use it yet
- [ ] Visual feedback for invalid drop zones (red/orange indicators)
- [ ] Tests for new drag functionality

**Design decisions made**:
- Commit phase modifiers: immediate drag on mouse_down (existing UX preserved)
- Selection phase cards: delayed drag (250ms hold) to avoid carousel visual glitch on quick clicks
- Lane switching disabled for now: `move_play` called with `new_channel = null`
- Floor (not round) for time slot detection: cursor must be past slot start to select it

**Next steps**:
1. Drag from hand to specific position (extend `play_card` or use `play_card` + `move_play`)
2. Lane switching UI (only weapon ↔ off_hand, requires equipped weapon check)
3. Invalid drop visualization
4. Unit tests for timing logic, hit detection, command dispatch

