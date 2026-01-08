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

