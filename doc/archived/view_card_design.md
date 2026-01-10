# View Layer Card Architecture

## Problem Statement

The presentation layer (`views/combat.zig`) currently accesses card data via legacy Deck zone fields:

```zig
// Current: reaches into deck internals
pub fn playerHand(self: *const CombatView) []const *cards.Instance {
    return self.world.player.cards.deck.hand.items;
}
```

This needs to migrate to the new architecture where:
- Card IDs are stored in `Agent.combat_state` (CombatState zones)
- Card instances live in `World.card_registry`
- Lookup: `world.card_registry.get(id)` returns `?*Instance`

Beyond migration, the view layer needs to support:
- Always-available techniques (from `Agent.techniques_known`)
- Play stacks (primary + reinforcements)
- Multi-enemy layouts
- Resolution phase matchups and timing

## Design Goals

1. **Decouple view from storage** - View works with view-specific structs, not Instance pointers
2. **Support future card sources** - Techniques, spells, reactions, environment
3. **Model plays, not just cards** - Commit/resolution phases show plays with context
4. **Flexible layout** - Scale to multiple enemies, show matchups, animate resolution

## Naming Clarification

There's a naming collision to address:
- `combat.CombatState` - domain struct holding card zone ArrayLists (draw, hand, etc.)
- `view_state.CombatState` - UI interaction state (hover, drag, selected_card)

**Resolution**: Rename `view_state.CombatState` → `CombatUIState` to distinguish from domain state.

## Data Structures

### CardViewData

Minimal card data for rendering individual cards (hand, techniques, reactions).

```zig
pub const CardViewData = struct {
    id: entity.ID,
    template: *const Template,
    playable: bool,
    source: Source,

    /// Card sources - where the card originated from.
    /// Currently used: hand, in_play. Others stubbed for future card systems.
    pub const Source = enum {
        hand,           // dealt card in CombatState.hand
        in_play,        // committed card
        techniques,     // from Agent.techniques_known (future)
        spells,         // from Agent.spells_known (future)
        equipped,       // weapon/shield actions (future)
        inventory,      // consumables (future)
        environment,    // pickup from Encounter.environment (future)
    };

    pub fn fromInstance(inst: *const Instance, source: Source, playable: bool) CardViewData {
        return .{
            .id = inst.id,
            .template = inst.template,
            .playable = playable,
            .source = source,
        };
    }
};
```

### PlayViewData

Committed play with context (for commit phase and resolution).

```zig
pub const PlayViewData = struct {
    // Ownership
    owner_id: entity.ID,
    owner_is_player: bool,

    // Cards in the play
    primary: CardViewData,
    reinforcements: [4]CardViewData,
    reinforcements_len: u4,
    stakes: cards.Stakes,

    // Targeting (if offensive)
    target_id: ?entity.ID,

    // TODO: Resolution context (for tick_resolution animation)
    // timing: f32,                    // time cost determines sequence
    // matchup: ?*const PlayViewData,  // opposing play (attack vs defense pair)
    // outcome: Outcome,
    //
    // pub const Outcome = enum {
    //     pending, hit, parried, blocked, dodged, cancelled,
    // };

    /// Total cards in play (primary + reinforcements)
    pub fn cardCount(self: *const PlayViewData) usize {
        return 1 + self.reinforcements_len;
    }

    /// Is this an offensive play?
    pub fn isOffensive(self: *const PlayViewData) bool {
        return self.primary.template.tags.offensive;
    }
};
```

## CombatView Interface

### Allocator Pattern

Query methods take an allocator parameter (same pattern as `renderables(alloc, vs)`).
This is typically a frame/arena allocator that gets reset each frame.

### Card Queries (individual cards)

```zig
pub const CombatView = struct {
    world: *const World,
    // ... existing fields ...

    // --- Player card queries ---
    // Note: These are player-only. Enemy cards are only shown via plays during commit phase.

    /// Dealt cards in player's hand
    pub fn handCards(self: *const CombatView, alloc: Allocator) []const CardViewData {
        const player = self.world.player;
        const cs = player.combat_state orelse return &.{};
        return self.buildCardList(alloc, .hand, cs.hand.items);
    }

    /// Player cards currently in play (selection phase, before commit)
    pub fn inPlayCards(self: *const CombatView, alloc: Allocator) []const CardViewData {
        const player = self.world.player;
        const cs = player.combat_state orelse return &.{};
        return self.buildCardList(alloc, .in_play, cs.in_play.items);
    }

    /// Always-available techniques (future)
    pub fn techniques(self: *const CombatView, alloc: Allocator) []const CardViewData {
        return self.buildCardList(alloc, .techniques, self.world.player.techniques_known.items);
    }

    // --- Internal helpers ---

    fn buildCardList(
        self: *const CombatView,
        alloc: Allocator,
        source: CardViewData.Source,
        ids: []const entity.ID,
    ) []const CardViewData {
        const result = alloc.alloc(CardViewData, ids.len) catch return &.{};
        var count: usize = 0;

        const player = self.world.player;
        const phase = self.world.fsm.currentState();

        for (ids) |id| {
            const inst = self.world.card_registry.get(id) orelse continue;
            const playable = apply.validateCardSelection(player, inst, phase) catch false;
            result[count] = CardViewData.fromInstance(inst, source, playable);
            count += 1;
        }

        return result[0..count];
    }
};
```

### Play Queries (committed plays)

```zig
pub const CombatView = struct {
    // ... continued ...

    // --- Play queries (commit/resolution phases) ---

    /// Player's committed plays
    pub fn playerPlays(self: *const CombatView, alloc: Allocator) []const PlayViewData {
        const player = self.world.player;
        const enc = self.world.encounter orelse return &.{};
        const state = enc.stateFor(player.id) orelse return &.{};
        return self.buildPlayList(alloc, player, &state.current);
    }

    /// Single enemy's committed plays (revealed during commit phase)
    pub fn enemyPlays(self: *const CombatView, alloc: Allocator, enemy: *const Agent) []const PlayViewData {
        const enc = self.world.encounter orelse return &.{};
        const state = enc.stateFor(enemy.id) orelse return &.{};
        return self.buildPlayList(alloc, enemy, &state.current);
    }

    /// All enemies' plays (flattened, tagged with owner)
    pub fn allEnemyPlays(self: *const CombatView, alloc: Allocator) []const PlayViewData {
        const enc = self.world.encounter orelse return &.{};

        // Count total plays
        var total: usize = 0;
        for (enc.enemies.items) |enemy| {
            if (enc.stateFor(enemy.id)) |state| {
                total += state.current.plays_len;
            }
        }

        const result = alloc.alloc(PlayViewData, total) catch return &.{};
        var i: usize = 0;

        for (enc.enemies.items) |enemy| {
            const plays = self.enemyPlays(alloc, enemy);
            for (plays) |play| {
                result[i] = play;
                i += 1;
            }
        }

        return result[0..i];
    }

    fn buildPlayList(
        self: *const CombatView,
        alloc: Allocator,
        agent: *const Agent,
        turn_state: *const TurnState,
    ) []const PlayViewData {
        const plays = turn_state.plays();
        const result = alloc.alloc(PlayViewData, plays.len) catch return &.{};

        for (plays, 0..) |play, i| {
            result[i] = self.buildPlayView(agent, &play);
        }

        return result;
    }

    fn buildPlayView(
        self: *const CombatView,
        agent: *const Agent,
        play: *const combat.Play,
    ) PlayViewData {
        const primary_inst = self.world.card_registry.get(play.primary);
        const is_player = agent.id.eql(self.world.player.id);

        var view = PlayViewData{
            .owner_id = agent.id,
            .owner_is_player = is_player,
            .primary = if (primary_inst) |inst|
                CardViewData.fromInstance(inst, .in_play, true)
            else
                undefined,
            .reinforcements = undefined,
            .reinforcements_len = 0,
            .stakes = play.effectiveStakes(),
            .target_id = null,  // TODO: from play targeting
        };

        // Build reinforcements
        for (play.reinforcements[0..play.reinforcements_len], 0..) |r_id, j| {
            if (self.world.card_registry.get(r_id)) |inst| {
                view.reinforcements[j] = CardViewData.fromInstance(inst, .in_play, true);
                view.reinforcements_len += 1;
            }
        }

        return view;
    }
};
```

## Layout Zones

### Zone Types

```zig
pub const ViewZone = enum {
    // Player zones (bottom of screen)
    hand,           // dealt cards, selectable
    techniques,     // always-available, left sidebar
    spells,         // always-available, right of techniques
    player_plays,   // committed plays, middle area

    // Enemy zones (top of screen)
    enemy_plays,    // per-enemy, under their avatar

    // Resolution zone (center, during tick phase)
    resolution,     // paired plays with matchup lines
};
```

### Layout Concept

```
┌─────────────────────────────────────────────────────────┐
│                    ENEMY AREA                           │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐          │
│  │ [Mob A]  │    │ [Mob B]  │    │ [Mob C]  │          │
│  │  ┌─┐┌─┐  │    │   ┌─┐    │    │          │          │
│  │  │▪││▪│  │    │   │▪│    │    │ (no play)│          │
│  │  └─┘└─┘  │    │   └─┘    │    │          │          │
│  └──────────┘    └──────────┘    └──────────┘          │
│                                                         │
├─────────────────────────────────────────────────────────┤
│                  RESOLUTION AREA                        │
│         (shown during tick_resolution phase)            │
│                                                         │
│    ┌───────┐  ←─attack──→  ┌───────┐                   │
│    │Player │               │Enemy  │                    │
│    │Thrust │               │Parry  │                    │
│    │ +2x   │               │       │                    │
│    └───────┘               └───────┘                    │
│         ↓ outcome: PARRIED                              │
│                                                         │
├─────────────────────────────────────────────────────────┤
│                  PLAYER PLAYS                           │
│    ┌───────┐  ┌───────┐  ┌───────┐                     │
│    │Play 1 │  │Play 2 │  │Play 3 │                     │
│    │Thrust │  │Block  │  │Swing  │  ← committed        │
│    │██     │  │       │  │█      │  ← reinforcement    │
│    └───────┘  └───────┘  └───────┘    indicator        │
│                                                         │
├─────────────────────────────────────────────────────────┤
│ TECHNIQUES │              HAND                          │
│  ┌─┐ ┌─┐   │    ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐       │
│  │T│ │T│   │    │Card │ │Card │ │Card │ │Card │       │
│  │h│ │S│   │    │  1  │ │  2  │ │  3  │ │  4  │       │
│  │r│ │w│   │    │     │ │     │ │░░░░░│ │     │       │
│  └─┘ └─┘   │    └─────┘ └─────┘ └─────┘ └─────┘       │
│            │         ↑ unplayable (greyed)              │
└─────────────────────────────────────────────────────────┘
```

### Phase-Specific Rendering

| Phase | Hand | Techniques | Player Plays | Enemy Plays | Resolution |
|-------|------|------------|--------------|-------------|------------|
| `draw_hand` | visible | visible | empty | hidden | hidden |
| `player_card_selection` | interactive | interactive | building | hidden | hidden |
| `commit_phase` | interactive | interactive | shown | revealed | hidden |
| `tick_resolution` | dimmed | dimmed | shown | shown | animated |

## CardZoneView Refactor

Data is decoupled (CardViewData), but rendering accesses ViewState for drag/hover positioning.
This avoids duplicating interaction state into CardViewData.

```zig
/// Renders a horizontal row of individual cards
const CardZoneView = struct {
    zone: ViewZone,
    layout: CardLayout,
    cards: []const CardViewData,

    pub fn init(zone: ViewZone, cards: []const CardViewData) CardZoneView {
        return .{
            .zone = zone,
            .layout = getLayout(zone),
            .cards = cards,
        };
    }

    /// Hit test returns card ID (uses mouse from ViewState)
    pub fn hitTest(self: CardZoneView, vs: ViewState) ?entity.ID {
        var i = self.cards.len;
        while (i > 0) {
            i -= 1;
            const rect = self.cardRect(i, self.cards[i].id, vs);
            if (rect.pointIn(vs.mouse)) return self.cards[i].id;
        }
        return null;
    }

    /// Rendering takes ViewState for drag/hover effects
    pub fn appendRenderables(
        self: CardZoneView,
        alloc: Allocator,
        list: *std.ArrayList(Renderable),
        vs: ViewState,
        last: *?Renderable,  // hovered/dragged card rendered last (on top)
    ) !void {
        const ui = vs.combat orelse CombatUIState{};

        for (self.cards, 0..) |card, i| {
            const rect = self.cardRect(i, card.id, vs);
            const state = self.cardViewState(card.id, ui);

            const model = CardViewModel{
                .template = card.template,
                .disabled = !card.playable,
                .highlighted = state == .hover,
            };

            const item: Renderable = .{ .card = .{ .model = model, .dst = rect } };
            if (state == .normal) {
                try list.append(alloc, item);
            } else {
                last.* = item;  // render last for z-order
            }
        }
    }

    /// Card rect with drag offset applied if this card is being dragged
    fn cardRect(self: CardZoneView, index: usize, card_id: entity.ID, vs: ViewState) Rect {
        const base = Rect{
            .x = self.layout.start_x + @as(f32, @floatFromInt(index)) * self.layout.spacing,
            .y = self.layout.y,
            .w = self.layout.w,
            .h = self.layout.h,
        };

        const ui = vs.combat orelse return base;
        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) {
                return .{
                    .x = vs.mouse.x - drag.grab_offset.x,
                    .y = vs.mouse.y - drag.grab_offset.y,
                    .w = base.w,
                    .h = base.h,
                };
            }
        }
        return base;
    }

    fn cardViewState(self: CardZoneView, card_id: entity.ID, ui: CombatUIState) CardViewState {
        _ = self;
        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) return .drag;
        }
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) return .hover,
            else => {},
        }
        return .normal;
    }
};
```

## PlayZoneView (new)

```zig
/// Renders committed plays (can show stacks, stakes)
const PlayZoneView = struct {
    layout: PlayLayout,
    plays: []const PlayViewData,

    pub fn init(plays: []const PlayViewData) PlayZoneView {
        return .{
            .layout = PlayLayout.default(),
            .plays = plays,
        };
    }

    pub fn appendRenderables(
        self: PlayZoneView,
        alloc: Allocator,
        list: *std.ArrayList(Renderable),
    ) !void {
        for (self.plays, 0..) |play, i| {
            const rect = self.playRect(i);

            // Render primary card
            try list.append(alloc, .{ .card = .{
                .model = CardViewModel{ .template = play.primary.template },
                .dst = rect,
            } });

            // Render stack indicator if reinforced
            if (play.reinforcements_len > 0) {
                try self.renderStackIndicator(alloc, list, rect, play.reinforcements_len);
            }

            // Render stakes indicator
            try self.renderStakesIndicator(alloc, list, rect, play.stakes);

            // TODO: Resolution phase rendering
            // - matchup connectors (line to opposing play)
            // - outcome indicators
            // - timing/sequence visualization
        }
    }

    fn renderStackIndicator(...) !void { /* stack count badge */ }
    fn renderStakesIndicator(...) !void { /* color-coded border */ }
};
```

## Migration Steps

1. **Rename `view_state.CombatState` → `CombatUIState`** - resolve naming collision

2. **Add `ViewZone` enum** to `views/combat.zig` - replace cards.Zone usage in view layer

3. **Add `CardViewData` and `PlayViewData`** to `views/combat.zig`

4. **Implement query methods** on CombatView:
   - `handCards(alloc)` - player hand from combat_state
   - `inPlayCards(alloc)` - player in_play from combat_state
   - `playerPlays(alloc)` - from AgentEncounterState (commit phase)
   - `enemyPlays(alloc, enemy)` - enemy plays (commit phase)

5. **Refactor CardZoneView** to use `[]const CardViewData` + ViewState for drag/hover

6. **Add PlayZoneView** for committed plays (stakes, stack indicators)

7. **Update `renderables()`** to use new queries

8. **Remove legacy Deck zone access** - delete `playerHand()`, `playerInPlay()`, `enemyInPlay()`

9. **Verify** - build passes, existing behaviour preserved

## Open Questions

1. **Resolution animation** - How to animate the sequence of play resolutions? Tween cards to center, show outcome, return?

2. **Reaction window** - When player can react, how is that surfaced? Flash available reactions?

3. **Stack visualization** - Fanned cards? Stacked with offset? Badge showing count?

4. **Time dimension** - Show timeline bar? Order plays vertically by time? Animate in sequence?

5. **Targeting lines** - Draw lines from offensive plays to targets during resolution?

## Files to Modify

- `src/presentation/view_state.zig` - rename CombatState → CombatUIState
- `src/presentation/views/view.zig` - update CombatState re-export to CombatUIState
- `src/presentation/views/combat.zig` - main refactor (CardViewData, PlayViewData, ViewZone, queries)

## Dependencies

- Phase 6 complete (PlayableFrom, combat_playable) ✓
- CardRegistry operational ✓
- CombatState zones in use ✓
