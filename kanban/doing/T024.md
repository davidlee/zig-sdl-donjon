# T024: Enemy Timeline Display for Commit Phase
Created: 2026-01-08

## Problem statement / value driver

During commit phase, enemy plays are displayed using a basic horizontal card layout (`Zone`/`PlayZoneView`) rather than the full timeline visualization. This is inconsistent with the player's timeline view and hides timing relationships between player and enemy manoeuvres.

### Scope - goals

- Display enemy plays inline with/above the player timeline during commit phase
- Show timing relationships clearly (when plays overlap)
- Support multiple enemies without overwhelming visual clutter

### Scope - non-goals

- Redesigning the player timeline
- Interactive manipulation of enemy plays
- Full card detail rendering for enemies (compact representation acceptable)

## Background

### Key files

- `src/presentation/views/combat/play.zig` - Contains `TimelineView` (player's 4-lane grid) and `Zone` (simple horizontal card layout used for enemies)
- `src/presentation/views/combat/view.zig` - `View.renderables` renders enemy plays using `enemyPlayZone` in commit phase

### Existing systems, memories, research, design intent

Current state:
- `TimelineView`: Full 4-lane grid (weapon/off_hand/footwork/concentration), 10 time slots (0.0-1.0 in 0.1 increments), positioned at y=340
- `Zone` (`PlayZoneView`): Simple horizontal card stack with modifier overlays, enemy plays at y=50 with 200px horizontal offset per enemy
- Enemy plays only shown in commit phase, looping through `opposition.enemies`

## Design Options

### Option A: Mirror grids with shared timeline axis

Keep the player grid where it is, add a compact mirrored grid above/below for the selected enemy. Share the same horizontal timeline scale so plays line up vertically, making overlap obvious. Collapse unused lanes (e.g., enemies with no off-hand card show empty strip).

### Option B: Channel badges instead of full cards

Enemy plays rendered as slim capsules keyed by tag color (weapon/off-hand/footwork/concentration) with card icon + short name. Stack capsules within each channel lane; hover/tooltips show full card. Cuts width dramatically so multiple channels fit in one row.

### Option C: Expandable play stack per enemy

Condensed timeline strip per enemy (name + channel icons). Clicking/hovering expands that enemy's strip to full multi-lane grid, hiding others temporarily. Keeps clutter down while allowing detail inspection.

### Option D: Shared channel legend with colored subsegments

Small legend indicating lane order/colors so enemy lanes collapse into a single timeline row using colored subsegments (e.g., top half of bar = weapon, bottom quarter = footwork). Multi-channel plays visible in limited vertical space.

### Challenges / Tradeoffs / Open Questions

1. **Vertical space**: Full mirrored grids for multiple enemies will consume significant screen real estate
2. **Information density**: Balance between showing timing clearly and keeping things readable
3. **Multiple enemies**: How to handle 3+ enemies without horizontal scrolling or cramped display?
4. **Hover/interaction**: Do enemy plays need hit testing or purely visual?
5. **Reusability**: Can we extract a `TimelineStrip` widget usable for both player (full) and enemy (compact) modes?

### Decisions

**Option B: Channel badges/capsules** - Compact representation showing:
- Slim horizontal capsules per play, positioned on shared timeline axis
- Color-coded by channel (weapon/off_hand/footwork/concentration)
- Card icon + short name inside capsule

**Single enemy focus**: Show one enemy strip at a time with ◄ ► arrows to cycle.
- New "focused enemy" concept in UI state (independent of domain attention)
- Defaults to `attention.primary`, freely cyclable for viewing/targeting
- Focused enemy becomes default target when playing offensive cards
- Playing on non-primary still triggers attention shift (existing stamina cost mechanic)
- Reduces vertical clutter, scales to any number of enemies

**Deferred**:
- Hover-to-expand for full card detail
- Capsule visual treatment TBD: simple colored rects first, then evaluate if card_renderer capsule mode or dedicated textures needed

### Implications

- May need to parameterize `TimelineView` for compact vs full modes
- Could affect layout constants in `getLayout`
- Might want to highlight overlapping time windows across player/enemy strips

## Implementation Ideas

1. **TimelineStrip widget**: Render in two modes (full grid vs compact capsules), reuse logic for both player/enemy
2. **Overlap highlighting**: Tinted background blocks on both strips to reinforce timing relationships
3. **Channel badges**: Small badges at left edge of each capsule (stacked vertically) to avoid needing multiple rows per channel

## Tasks / Sequence of Work

1. [x] **Add `focused_enemy` to `CombatUIState`**
   - `?entity.ID` field in `view_state.zig`
   - Defaults to `attention.primary`, independently cyclable

2. [x] **Add `EnemyTimelineStrip`** in `play.zig`
   - Extracted `timeline_axis` shared constants (start_x, slot_width, num_slots)
   - 35px row height, positioned above player timeline
   - Capsules: colored rect by channel + card name text

3. [x] **Define channel colors** (`channel_colors` struct)
   - weapon: red-orange (180, 80, 60)
   - off_hand: blue (60, 100, 180)
   - footwork: green (60, 160, 80)
   - concentration: purple (140, 80, 180)

4. [x] **Add ◄ ► navigation**
   - `hitTestNav` method on EnemyTimelineStrip
   - `hitTestEnemyNav` in View.onClick
   - Cycles `focused_enemy` with wrap-around

5. [x] **Integrate in `View.renderables`**
   - `getFocusedEnemy` helper (UI focus > primary > first enemy)
   - Replaced `enemyPlayZone` loop with single strip

6. [x] **Default targeting behavior**
   - `playCard` and `commitAddCard` now use focused enemy as default target
   - Skips targeting mode when focused enemy available

## Test / Verification Strategy

### success criteria / ACs

- Enemy plays visible during commit phase with timing information
- Player and enemy plays share timeline axis for easy comparison
- Multiple enemies don't overwhelm the display
- Hover shows card detail for enemy plays

### user acceptance

- Visual comparison of timing between player and enemy moves is intuitive

## Quality Concerns / Risks / Potential Future Improvements

- Consider touch/gamepad interaction in future
- Animation of enemy plays entering timeline (if we add that later)

## Progress Log / Notes

- 2026-01-08: Card created. Explored existing `TimelineView` and `Zone` implementations.
- 2026-01-08: Decision: Option B (capsule badges). Hover expansion deferred.
- 2026-01-08: Refined: Single focused enemy with ◄ ► nav. Focused enemy (UI) distinct from primary (domain attention). Defaults to primary, free to cycle, becomes default target for cards.
- 2026-01-08: Capsule visuals TBD - start with simple colored rects, evaluate card_renderer capsule mode or dedicated textures later.
- 2026-01-08: **Implementation complete.** All tasks done:
  - `focused_enemy` field in CombatUIState
  - `timeline_axis` shared constants extracted
  - `channel_colors` struct with color palette
  - `EnemyTimelineStrip` with capsule rendering and nav arrows
  - `getFocusedEnemy`, `hitTestEnemyNav` helpers in View
  - Default targeting uses focused enemy in both playCard and commitAddCard
  - All tests pass
- 2026-01-08: Added skull overlay for incapacitated mobs (assets/skull.png)
- 2026-01-08: Selection phase improvements:
  - Left/right arrow keys cycle focused enemy
  - Cyan border around focused enemy sprite
  - Enemy name + nav arrows shown during selection phase (not just commit)
