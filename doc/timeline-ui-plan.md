# Timeline UI Implementation Plan

> **Status**: Draft. 2026-01-07.

## Overview

The combat UI needs to represent plays positioned on a timeline with multiple channels. This replaces the current simple list of committed plays.

### Current State

- Plays shown as card icons in a committed area (top-left)
- No timing information visible
- No channel visualization
- Resource bars (stamina/focus/time) at bottom

### Target State

- Timeline with 4 channel lanes (weapon, off_hand, footwork, concentration)
- Plays rendered as blocks spanning their time duration
- Clear visualization of overlapping plays across channels
- Primary target indicator with switch capability
- Click-to-place and drag-to-reposition interactions

---

## Design

### Layout

```
┌─────────────────────────────────────────────────────────────────┐
│  [Player]    [Goblin @sabre]  [Orc* @mace]   Stam ████  Foc ███ │
│                                              [End Turn]         │
├──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┬──┤
│  0.0 │  0.1 │  0.2 │  0.3 │  0.4 │  0.5 │  0.6 │  0.7 │  0.8 │..│
├──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┴──┤
│ ┌────┐┌────┐                                         weapon     │
│ │Thru││    │                                                    │
│ └────┘└────┘                                                    │
├─────────────────────────────────────────────────────────────────┤
│ ┌────┐                                               off_hand   │
│ │Bloc│                                                          │
│ └────┘                                                          │
├─────────────────────────────────────────────────────────────────┤
│ ┌────┐┌────┐                                         footwork   │
│ │Adva││    │                                                    │
│ └────┘└────┘                                                    │
├┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┤
│  ┌──┬──┬──┬──┐   ┌──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┐          │
│  │  │  │  │Ha│ ~ │  │  │  │  │  │  │  │  │  │  │  │Kn│          │
└──┴──┴──┴──┴nd┴───┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴──┴wn┴──────────┘
```

**Key layout decisions:**

- **Top right corner**: Status bars (stamina, focus) + End Turn button (moves from bottom)
- **Enemies**: Show range per enemy (e.g., `@sabre`, `@mace`), primary marked with `*`
- **Timeline**: 3 channel rows (weapon, off_hand, footwork) - concentration hidden for now
- **Cards as cards**: Full card renders in timeline slots, not abstract blocks
- **Bottom edge**: Hand + Known cards in single row, overlapping carousel-style
  - Slight gap between hand and known groups
  - Cards peek from bottom edge (partly offscreen)
  - Fan out on hover to reveal full set
  - Angle TBD (straight or fanned)

**Removed:**
- Time remaining (explicit positioning replaces time budget)
- Concentration channel (no cards use it yet)

### Play Block Rendering

Each committed play appears as a colored block:
- **Position**: Channel row × time columns
- **Width**: Spans `time_start` to `time_end` (snapped to 0.1s grid)
- **Height**: Full channel row height
- **Content**: Card name, optional small icon
- **Color coding**:
  - Offensive: red-tinted
  - Defensive: blue-tinted
  - Manoeuvre: green-tinted
  - Concentration: purple-tinted

### Modifier Display

Modifiers shown as **rune chips** on play blocks:
- Each card has an iconic dwarf rune
- Modifiers appear as small rune icons stacked/overlaid on the play block
- Hover on rune shows full modifier card info
- Consistent with card game aesthetic (solitaire-style stacking, but compact)

### Space Solution

Resolved via card carousel at bottom edge:
- Hand + Known share single row, overlapping carousel-style
- Cards peek from bottom, fan on hover
- Status bars move to top right chrome
- 3 channel rows get full card height each

**Still open**: Resolution phase display (enemy plays, pairing visualization).

### Interaction Patterns

**Click to Place** (< 150ms press):
1. Click card in hand
2. Card placed at next available time on appropriate channel(s)
3. If card requires targeting and differs from primary, show cost warning

**Drag to Position**:
1. Press and hold card (> 150ms)
2. Ghost block follows cursor along valid timeline positions
3. Invalid positions shown as red zones
4. Release to place

**Drag to Reposition** (from timeline):
1. Click existing play block
2. Drag to new position (same channel constraints)
3. Other plays do NOT auto-shift (explicit positioning)

**Remove Play**:
1. Drag play block back to hand area (consistent with drag model)

**Target Selection**:
1. Click enemy sprite to set as primary target
2. Shows stamina cost if switching mid-turn
3. All subsequent `.single` target plays default to primary

**Target Highlighting**:
- Hover card in hand/known → highlight its current target (primary by default)
- Hover committed play → highlight that play's target
- Dragging card → highlight primary (where it will go)
- Each play can have different target; primary is the placement default

---

## Data Requirements

### Extended PlayStatus (DTO)

```zig
pub const PlayStatus = struct {
    play_index: usize,
    owner_id: entity.ID,
    owner_is_player: bool,

    // Timing (NEW)
    time_start: f32,
    time_end: f32,

    // Channels (NEW)
    channels: ChannelSetDTO,

    // Target
    target_id: ?entity.ID,

    // Card info for rendering (NEW)
    action_card_id: entity.ID,
    action_name: []const u8,
    is_offensive: bool,
    is_defensive: bool,
    is_manoeuvre: bool,

    // Modifiers (NEW)
    modifier_count: u8,
    // Full modifier info available via separate query if needed
};

pub const ChannelSetDTO = packed struct {
    weapon: bool = false,
    off_hand: bool = false,
    footwork: bool = false,
    concentration: bool = false,
};
```

### Extended CombatSnapshot

```zig
pub const CombatSnapshot = struct {
    // Existing
    card_statuses: ...,
    play_statuses: ...,
    modifier_attachability: ...,

    // NEW: Player resources
    player_stamina_current: f32,
    player_stamina_available: f32,
    player_focus_current: f32,
    player_focus_available: f32,
    player_time_remaining: f32,

    // NEW: Primary target
    primary_target_id: ?entity.ID,
    target_switch_cost: f32,  // stamina cost to switch

    // NEW: Enemy list
    enemies: std.ArrayList(EnemyStatus),

    // NEW: Turn phase
    turn_phase: TurnPhase,

    // NEW: Valid slot computation (for drag preview)
    // Computed on demand rather than pre-cached
};

pub const EnemyStatus = struct {
    id: entity.ID,
    name: []const u8,
    is_primary: bool,
    range: Reach,  // from player's perspective
};
```

### New Query: Available Slots

For drag preview, we need to know where a card can be placed:

```zig
/// Returns valid time positions for placing a card.
/// Called during drag operation.
pub fn getAvailableSlots(
    snapshot: *const CombatSnapshot,
    card_id: entity.ID,
    registry: *const CardRegistry,
) []const SlotAvailability;

pub const SlotAvailability = struct {
    time_start: f32,  // 0.0, 0.1, 0.2, ...
    valid: bool,
    conflict_reason: ?ConflictReason,
};

pub const ConflictReason = enum {
    channel_occupied,
    exceeds_tick,
    out_of_range,  // target unreachable at this timing
};
```

---

## Implementation Phases

### Phase 0: Visual Prototype

**Goal**: Validate timeline layout and interactions before committing to data architecture.

Work directly with domain types (accept temporary coupling). Focus on:

1. **Layout restructure**
   - Move status bars + End Turn to top right
   - 3 channel rows (weapon, off_hand, footwork) at card height
   - Time grid as vertical bars (0.0-1.0)
   - Enemy sprites with per-enemy range labels

2. **Card carousel (bottom edge)**
   - Hand + Known in single overlapping row
   - Cards peek from bottom (partly offscreen)
   - Fan out on hover (angle TBD)
   - Slight gap between hand and known groups

3. **Timeline card rendering**
   - Full card visuals in timeline slots
   - Position by channel row × time column
   - Rune chips for modifiers

4. **Basic interactions**
   - Click to place at next available
   - Drag ghost preview with snap-to-grid
   - Target highlighting on hover/drag

5. **Multi-enemy scenarios**
   - Test with 1, 2, 3 enemies
   - Range display per enemy
   - Primary target indicator

**Output**: Screenshots of viable layout, confirmed card sizes work, interaction feel validated.

**Explicitly NOT doing**:
- Clean data layer separation
- Full PlayStatus DTO
- Production-quality code

Once layout is validated, proceed to Phase 1 to properly architect the data flow.

---

### Phase 1: Data Layer (Query)

**Goal**: Extend CombatSnapshot with all data needed for timeline rendering.

1. Add timing fields to `PlayStatus`
   - `time_start`, `time_end` from `TimeSlot`
   - `channels` from technique lookup

2. Add card display info to `PlayStatus`
   - `action_name`, `is_offensive`, `is_defensive`, `is_manoeuvre`
   - Resolved from template via registry

3. Add player resources to `CombatSnapshot`
   - Stamina, focus, time remaining
   - Primary target ID

4. Add enemy list to `CombatSnapshot`
   - ID, name, is_primary, range

5. Add turn_phase to `CombatSnapshot`

**Tests**:
- `test "PlayStatus includes timing from TimeSlot"`
- `test "PlayStatus includes channel info"`
- `test "CombatSnapshot includes player resources"`
- `test "CombatSnapshot includes enemy list"`

### Phase 2: Timeline View Component

**Goal**: Render timeline with channel lanes and play blocks.

1. Create `TimelineView` struct
   - Consumes `[]PlayStatus` from snapshot
   - Renders 4 channel rows
   - Renders time grid (0.0-1.0 in 0.1 increments)

2. Create `PlayBlockView` for each play
   - Position: channel row × time columns
   - Width: proportional to duration
   - Color: based on card type
   - Content: card name

3. Integrate into combat view
   - Replace current play list rendering
   - Position between avatar area and card hand

**Tests**:
- Visual inspection (screenshot comparison)
- `test "PlayBlockView positions correctly for time range"`

### Phase 3: Click-to-Place Interaction

**Goal**: Clicking a card places it at next available time.

1. Modify card click handler
   - On click (< 150ms), issue `PlayCard` command
   - Command uses `timeline.nextAvailableStart()` for timing

2. Add `time_start` to play commands
   - Commands currently don't specify timing
   - Need to extend command payload or infer in handler

3. Visual feedback
   - Brief highlight on timeline where card landed
   - Error feedback if placement fails

**Tests**:
- `test "clicking card places at next available slot"`
- `test "clicking manoeuvre places on footwork channel"`

### Phase 4: Drag-to-Position Interaction

**Goal**: Drag card from hand to specific timeline position.

1. Drag detection (> 150ms hold)
   - Track mouse down time
   - Threshold determines click vs drag

2. Ghost preview during drag
   - Semi-transparent play block follows cursor
   - Snaps to valid 0.1s positions
   - Shows red overlay on invalid positions

3. Available slots query
   - Call `getAvailableSlots()` during drag
   - Highlight valid drop zones on timeline

4. Drop handling
   - Issue `PlayCard` command with specific `time_start`
   - Cancel if dropped outside valid zone

**Tests**:
- `test "dragging shows ghost preview"`
- `test "dropping on invalid zone cancels"`
- `test "dropping on valid zone places at position"`

### Phase 5: Drag-to-Reposition (from timeline)

**Goal**: Reposition existing plays by dragging.

1. Detect drag start on play block
   - Distinguish from click (< 150ms = select for info)
   - Drag removes play from current position

2. Show available slots excluding removed play
   - Recompute valid slots without the dragged play

3. Drop to reposition
   - Issue `RepositionPlay` command (new command type)
   - Or: Remove + Add sequence

4. Cancel drag returns to original position

**Tests**:
- `test "dragging play block shows repositioning ghost"`
- `test "repositioning respects channel constraints"`

### Phase 6: Primary Target Selector

**Goal**: UI for selecting/switching primary target.

1. Enemy sprites clickable
   - Click sets as primary target
   - Visual indicator (highlight, star, etc.) on primary

2. Switch cost display
   - Show stamina cost when hovering non-primary
   - Confirmation if cost > 0

3. Target indicator on plays
   - Small icon or color tint showing target
   - Different from primary = warning indicator

**Tests**:
- `test "clicking enemy sets primary target"`
- `test "switch cost displayed for non-primary"`

### Phase 7: Synergy Preview

**Goal**: Show bonuses when plays overlap.

1. Hover detection on play blocks
   - Detect mouse over committed play

2. Synergy calculation
   - Query overlapping plays from snapshot
   - Compute bonus effects (advance + thrust = damage bonus)

3. Tooltip display
   - Show synergy info on hover
   - Include: bonus type, magnitude, source cards

**Deferred detail**: Exact synergy display format TBD.

---

## Component Structure

```
src/presentation/views/combat/
├── view.zig              # Main combat view (modified)
├── timeline/
│   ├── mod.zig           # TimelineView
│   ├── channel_lane.zig  # Single channel row
│   ├── play_block.zig    # Play block rendering
│   ├── time_grid.zig     # Time markers
│   └── drag_ghost.zig    # Drag preview
├── target_selector.zig   # Primary target UI
└── ...existing files...
```

---

## Command Changes

### Existing: PlayCard

Currently handled by coordinator. Need to add optional `time_start`:

```zig
pub const PlayCardCommand = struct {
    card_id: entity.ID,
    play_index: ?usize,  // for modifier attachment
    time_start: ?f32,    // NEW: explicit timing (null = auto)
};
```

### New: RepositionPlay

```zig
pub const RepositionPlayCommand = struct {
    play_index: usize,
    new_time_start: f32,
};
```

---

## Open Questions

1. **Card carousel fan angle**: Straight vertical fan, or angled like a hand of cards?

2. **Enemy plays during resolution**: How to show what enemy committed? Options:
   - Separate enemy timeline row(s) above player's
   - Interleaved/paired view
   - Reveal progressively as resolution happens

3. **Resolution animations**: How to show attack/defense matchups, damage, etc.

4. **Per-play target override**: UI for changing a specific play's target from primary (costs stamina). Click play then click enemy? Context menu?

5. **Mobile/touch**: Not immediate concern, but drag interactions may need adaptation.

---

## Dependencies

- **Phase 0** (visual prototype) informs all subsequent work - validates layout before architecture
- Phase 1 blocks phases 2-7 (clean data layer before production rendering)
- Phases 2-4 are core MVP
- Phases 5-7 are enhancements
- Must maintain presentation-domain separation per `doc/presentation-domain-decoupling.md` (after Phase 0)

---

## Related Documents

- [Timing, Simultaneity, Positioning](timing_simultaneity_positioning.md) - Domain model
- [Presentation-Domain Decoupling](presentation-domain-decoupling.md) - Architecture constraints
- [Command-Query Decoupling](command-query-decoupling.md) - Command patterns
