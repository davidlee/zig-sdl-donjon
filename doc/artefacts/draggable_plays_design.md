# Draggable Card Plays - Design Document

Created: 2026-01-08
Task: T027

## Summary

Extend card interaction during selection phase to support:
1. Click vs drag discrimination (timing-based)
2. Drag-to-position on timeline
3. Reorder within lane (time repositioning)
4. Drag between lanes (channel selection for dual-wielding)

## Current State

### UI Layer (`src/presentation/`)

**Click handling** (`views/combat/view.zig`):
- `mouse_down`: if `isCardDraggable()` → set `DragState`; else record `clicked` position
- `mouse_up`: if dragging with valid target → `commit_stack`; else compare click/release pos → `onClick()`
- No timing - only position comparison determines click vs drag

**DragState** (`view_state.zig`):
```zig
pub const DragState = struct {
    id: entity.ID,
    original_pos: Point,
    target: ?entity.ID = null,
    target_play_index: ?usize = null,
};
```

**isCardDraggable**: Only modifiers that are playable (commit phase only).

### Domain Layer (`src/domain/`)

**Timeline** (`combat/plays.zig`):
- `time_start: f32` (0.0-1.0, snapped to 0.1 = 100ms)
- `TimelinePlays` sorted by `time_start`
- `canInsert(time_start, time_end, channels)` validates no overlap within same channel
- `addPlayAt(play, time_start)` exists but unused

**Channels** (`cards.zig`):
- `ChannelSet`: weapon, off_hand, footwork, concentration
- Channels derived from card template via `getPlayChannels(play, registry)`
- **No channel override** - Play doesn't store selected channel

**Commands** (`commands.zig`):
- `play_card`: adds at `nextAvailableStart()`
- `cancel_card`: removes from timeline
- No `move_play` or `reorder_play` command

## Required Changes

### 1. Click vs Drag Timing

**Problem**: Currently click vs drag is position-based (same pos = click).

**Solution**: Add timestamp to ViewState, compare on mouse_up.

```zig
// view_state.zig
pub const ViewState = struct {
    clicked: ?Point = null,
    click_time: ?f32 = null,  // NEW: timestamp when clicked
    // ...
};

// combat/view.zig handleInput
.mouse_button_down => {
    new_vs.clicked = vs.mouse_vp;
    new_vs.click_time = current_time;  // from coordinator
    // ...
}

.mouse_button_up => {
    if (vs.click_time) |start| {
        const elapsed = current_time - start;
        if (elapsed < 0.25) {  // 250ms threshold
            return self.onClick(vs, vs.clicked.?);
        }
    }
    return self.handleDragRelease(vs);
}
```

**Complication**: `handleInput` doesn't have access to `current_time`. Options:
- Pass through from coordinator
- Store in ViewState
- Use SDL timestamp from event

### 2. Channel Override for Dual-Wielding

**Problem**: Channels are intrinsic to card template. "thrust" always uses weapon channel.

**Solution**: Add optional channel override to Play.

```zig
// combat/plays.zig
pub const Play = struct {
    action: entity.ID,
    target: ?entity.ID = null,
    channel_override: ?cards.ChannelSet = null,  // NEW
    // ...
};

pub fn getPlayChannels(play: Play, registry: *const world.CardRegistry) cards.ChannelSet {
    // Use override if set
    if (play.channel_override) |override| return override;
    
    // Otherwise derive from template (existing logic)
    // ...
}
```

**When to allow override**:
- Card must be technique-based
- Target channel must have a weapon equipped
- Card's original channel must be weapon-type (weapon or off_hand)

This needs domain validation - can't drag a footwork card to weapon lane.

### 3. Move Play Command

**New command** for repositioning:

```zig
// commands.zig
pub const Command = union(enum) {
    // ...
    move_play: struct {
        card_id: ID,
        new_time_start: f32,
        new_channel: ?cards.ChannelSet = null,
    },
};
```

**Handler** (`command_handler.zig`):
1. Find play by card_id
2. Remove from current position
3. Validate new position (canInsert with new time/channel)
4. Insert at new position

### 4. Extended DragState

```zig
pub const DragState = struct {
    id: entity.ID,
    original_pos: Point,
    source: DragSource,
    
    // Drop target indicators
    target_time: ?f32 = null,          // timeline position under cursor
    target_channel: ?ChannelSet = null, // lane under cursor
    is_valid_drop: bool = false,        // can drop here?
    
    // Existing (for modifier stacking)
    target_play_index: ?usize = null,
    
    pub const DragSource = enum { hand, timeline };
};
```

### 5. UI Rendering Changes

**During drag**:
- Show card following cursor (offset from grab point)
- Ghost in original position (if from timeline)
- Highlight valid drop zones
- Show insertion indicator at target time

**Timeline lanes**:
- Already exist in UI (weapon, off_hand, footwork, conc)
- Need hit detection per lane
- Visual feedback for valid/invalid drop

### 6. Phase-Specific Behavior

| Phase | Card Types | Actions |
|-------|-----------|---------|
| Selection | All playable | Drag to timeline (position), reorder, change lane |
| Commit | Modifiers only | Drag onto plays (existing behavior) |

Modifier drag in commit phase stays as-is. Selection phase drag is new code path.

## Implementation Sequence

1. **Add click timing** - ViewState + handleInput changes
2. **Make all cards draggable** in selection phase (isCardDraggable)
3. **Extended DragState** - source, target_time, target_channel, is_valid_drop
4. **Timeline hit detection** - map cursor position → (time, channel)
5. **Drop zone visualization** - highlight valid positions during drag
6. **move_play command** - domain handler for repositioning
7. **Channel override** - Play field + validation logic
8. **Lane switching UI** - detect drop on different channel, dispatch move_play

### 7. Range Validation Per Lane (Natural Weapons)

**Problem**: Different weapons have different ranges.
- Sword in main hand: `reach`
- Fist (natural weapon) in off-hand: `close`

Dragging "thrust" to off_hand lane would use fist, which might not reach targets.

**Data source**: `Agent.allAvailableWeapons()` yields equipped + natural weapons with their ranges.

**UI feedback during drag**:
- White border (current): valid drop, technique has targets
- Orange border: valid drop position, but **no valid targets at this range**
- Red/invalid: can't drop here (time conflict, wrong channel type)

**Implementation**:
```zig
// During drag, for each potential lane:
fn validateLaneDrop(card_id: entity.ID, channel: ChannelSet, agent: *Agent) DropValidity {
    // 1. Can technique use this channel? (weapon-type check)
    // 2. Does agent have weapon in this slot?
    // 3. What's the weapon's range?
    // 4. Are there valid targets at that range?

    const weapon = agent.weaponForChannel(channel) orelse return .no_weapon;
    const range = weapon.template.range;
    const has_targets = checkTargetsInRange(range, encounter);

    return if (has_targets) .valid else .no_targets_in_range;
}
```

**Visual states**:
| State | Border | Meaning |
|-------|--------|---------|
| Hovering (not dragging) | White | Card highlighted |
| Dragging - valid | Green/none | Can drop, has targets |
| Dragging - no targets | Orange | Can drop, but no targets in range |
| Dragging - invalid | Red/dim | Can't drop (conflict/wrong channel) |

## Open Questions

1. **Drag visual**: Card follows cursor, or ghost + insertion line?
2. **Invalid drop behavior**: Snap back, or stay at nearest valid position?
3. **Multi-channel cards**: Can a card using both weapon+off_hand be moved to just one?
4. **Commit phase reorder**: Future scope? Uses Focus, domain rules.
5. **Range preview**: Show range indicator on battlefield when hovering over lane?

## Edge Cases / Future Considerations

### Two-handed weapons
2h weapon equipped → off_hand lane unavailable. Should hide or dim the lane.

### Mid-tick armament changes
If future cards allow drop/draw mid-tick, lane validity becomes time-dependent:
- Drop sword at t=0.3 → weapon lane blocked after t=0.3
- Draw dagger at t=0.4 → off_hand available after t=0.4

**Current approach**: Validate based on armament state at selection time. Revisit when weapon-change cards are implemented.

## Test Strategy

- Unit: command handler for move_play, channel override logic
- Unit: weaponForChannel returns correct weapon (equipped vs natural)
- Unit: range validation per channel
- Integration: drag from hand → timeline at specific position
- Integration: reorder within lane
- Integration: lane switch with dual-wield equipped
- Integration: lane switch shows orange border when no targets in range
- UI: click timing threshold (mock time)

## Files Affected

- `src/presentation/view_state.zig` - DragState, click_time
- `src/presentation/views/combat/view.zig` - handleInput, drag logic
- `src/presentation/views/combat/play.zig` - drop zone visualization
- `src/commands.zig` - move_play command
- `src/domain/apply/command_handler.zig` - move_play handler
- `src/domain/combat/plays.zig` - Play.channel_override, getPlayChannels
- `src/domain/combat/agent.zig` - weaponForChannel() helper (uses allAvailableWeapons)
- `src/presentation/query.zig` - range validation for lane drop (snapshot extension)
