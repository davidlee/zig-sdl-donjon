# Plan: Modifier-to-Play Attachment Validation

## Goal
Enable drag-and-drop attachment of modifier cards to plays in the UI by:
1. Validating which plays a modifier can attach to (for drop target highlighting)
2. Finding plays by card ID (since UI works with card IDs, not play indices)
3. Representing plays in the UI data model

## Implementation Status

### COMPLETED - Domain Layer

#### 1. Validation Functions (apply.zig)

```zig
/// Extract target predicate from modifier template's first my_play expression.
/// Returns error if multiple distinct my_play targets found (ambiguous attachment).
pub fn getModifierTargetPredicate(template: *const cards.Template) !?cards.Predicate

/// Check if a modifier can attach to a specific play.
pub fn canModifierAttachToPlay(
    modifier: *const cards.Template,
    play: *const combat.Play,
    world: *World,
) !bool
```

#### 2. Conflict Detection (combat.zig)

```zig
/// Check if adding a modifier would conflict with existing modifiers.
/// Currently detects: conflicting height_override (e.g., Low + High).
pub fn wouldConflict(self: *const Play, new_modifier: *const cards.Template, registry: *const world.CardRegistry) bool
```

#### 3. Find Play by Card ID (combat.zig)
Already existed as `TurnState.findPlayByCard()`.

#### 4. Command Handler (apply.zig)

Refactored `commitStack` to handle both same-template stacking AND modifier attachment:
- Split into `validateStack()` and `applyStack()` for clean separation
- Accepts cards from hand OR always_available zones
- Focus costs are additive: base 1 (first stack only) + card's own focus cost
- Validates predicate match for modifiers via `canModifierAttachToPlay()`
- Detects conflicts via `Play.wouldConflict()`

New error variants added to `CommandError`:
- `CardOnCooldown` - for always_available cards on cooldown
- `ModifierConflict` - for height_override conflicts (e.g., Low + High)

#### Tests Added
- `getModifierTargetPredicate` extracts predicate from modifier template
- `getModifierTargetPredicate` returns null for non-modifier
- `canModifierAttachToPlay` validates offensive tag match
- `canModifierAttachToPlay` rejects non-offensive play
- `Play.wouldConflict` detects conflicting height_override
- `Play.wouldConflict` allows same height_override
- `Play.wouldConflict` allows non-conflicting modifiers
- `Play.wouldConflict` returns false for empty modifier stack

### IN PROGRESS - UI Layer (Session 2)

#### Completed This Session:
- `PlayZoneView` struct added to combat.zig view (lines 300-410)
- `playerPlays()` and `buildPlayViewData()` added to CombatView (lines 572-626)
- `DragState.target_play_index` field added (view_state.zig:74)
- `Encounter.stateForConst()` added for read-only access (combat.zig:402-405)
- `resolvePlayTargetIDs()` stub added to apply.zig (returns null - needs const-aware impl)
- Rendering pipeline updated to switch between PlayZoneView (commit phase) and CardZoneView (selection phase)
- `handleDragging()` partially updated for play-based targets

#### RESOLVED - Const Propagation:
Fixed by adding `.getConst()` accessors through the call chain. The view layer can now call
validation functions with `*const World`.

#### Still TODO:

### TODO - UI Layer

#### 1. PlayViewModel (combat.zig view)

Create play representation in UI data model:
```zig
const PlayViewModel = struct {
    action_id: entity.ID,
    action_template: *const cards.Template,
    modifier_ids: []const entity.ID,
    play_index: usize,
    rect: Rect,  // computed position
};
```

#### 2. Drop Target Highlighting

When dragging a modifier, highlight valid drop targets by:
1. Getting current plays from encounter state
2. For each play, call `canModifierAttachToPlay()`
3. Check `play.wouldConflict()` for existing modifiers
4. Set drag target state on valid plays

#### 3. Drop Command Dispatch

On drop, dispatch `commit_stack` command with:
- `card_id`: the dragged modifier
- `target_play_index`: from PlayViewModel

#### 4. Grouped Card Rendering (optional polish)

Render plays as stacked card groups instead of flat cards:
- Action card in front
- Modifier cards fanned behind

## Files Modified
- `src/domain/apply.zig` - validation functions, refactored commitStack
- `src/domain/combat.zig` - wouldConflict() on Play

## Decisions Made
1. Modifiers playable from always_available (with cooldown) - IMPLEMENTED
2. UI shows plays as grouped/stacked cards - DEFERRED (rendering only, data model first)
3. Focus costs additive: base 1 + card focus cost - IMPLEMENTED
4. Multiple targeting expressions error rather than picking first - IMPLEMENTED
5. Conflict detection on height_override only for now - IMPLEMENTED

----
Architecture Analysis Report: Combat View and Play Representation

1. CardViewModel and CardZoneView Structures

CardViewModel (src/presentation/views/card_view.zig)

Purpose: Presentation data for rendering a single card instance.

Fields:
- id: entity.ID - unique instance identifier
- name: []const u8 - display name
- description: []const u8 - card text
- kind: CardKind - visual category (action, modifier, passive, reaction)
- rarity: CardRarity - visual treatment (common through legendary)
- stamina_cost: f32 - cost display
- time_cost: f32 - cost display
- state: CardState - packed struct with visual flags (exhausted, selected, highlighted, disabled, played, target)

Factory Methods:
- fromInstance(instance, state) - creates from full domain instance
- fromTemplate(id, template, state) - creates from template (for previews)

CardZoneView (src/presentation/views/combat.zig:187-298)

Purpose: Lightweight view over a collection of cards in a zone (hand, in_play, always_available).

Fields:
- zone: ViewZone - layout designation (hand, in_play, always_available, etc.)
- layout: CardLayout - position/sizing (w, h, y, start_x, spacing)
- cards: []const CardViewData - array of card presentation data

CardViewData: Minimal data for view rendering, decoupled from Instance pointers:
- id: entity.ID
- template: *const cards.Template
- playable: bool - computed via validateCardSelection
- source: Source - enum tracking origin (hand, in_play, always_available, etc.)

Key Methods:
- hitTest(vs, pt) - returns card ID at point (reverse order for z-order)
- appendRenderables(alloc, vs, list, last) - generates card renderables with state
- cardRect(index, card_id, vs) - computes position with drag offset
- cardInteractionState(card_id, ui) - determines visual state (normal, hover, drag, target)

Initialization Patterns:
CardZoneView.init(zone, card_data)                    // standard
CardZoneView.initWithLayout(zone, card_data, layout) // custom positioning

2. Current in_play Zone Rendering

Selection Phase (player_card_selection)

Data Source: CombatState.in_play (flat list of card IDs)

Rendering:
- Cards displayed at fixed layout position (y=200, spacing=card_width+10)
- Individual cards with .played = true state flag
- Hit-testable for cancellation (returns card to hand)
- No grouping or play structure

Commit Phase (commit_phase)

Current Behavior:
- Player cards: still rendered from CombatState.in_play as flat list
- Enemy cards: rendered per-agent with offset layouts (lines 678-690)
- No visual distinction between plays vs individual cards
- No modifier attachment visualization

Missing:
- Play grouping (action + modifiers shown together)
- Target/engagement indication for offensive plays
- Visual hierarchy (action card prominent, modifiers behind/attached)

3. Calling Conventions

View Construction Pattern

pub fn init(world: *const World, arena: std.mem.Allocator) CombatView
- CombatView owns an arena allocator for per-frame allocations
- Queries world state on-demand (doesn't cache)

Zone Data Building

fn handCards(self: *const CombatView, alloc: Allocator) []const CardViewData
fn inPlayCards(self: *const CombatView, alloc: Allocator) []const CardViewData
fn alwaysCards(self: *const CombatView, alloc: Allocator) []const CardViewData
- Query pattern: fetch IDs from domain → resolve via card_registry → build CardViewData array
- Playability computed via apply.validateCardSelection(player, inst, phase)

Zone View Access

fn handZone(self: *const CombatView, alloc: Allocator) CardZoneView
fn inPlayZone(self: *const CombatView, alloc: Allocator) CardZoneView
fn alwaysZone(self: *const CombatView, alloc: Allocator) CardZoneView
- Convenience wrappers that combine data query + CardZoneView.init

Rendering Pipeline

pub fn renderables(self: *const CombatView, alloc: Allocator, vs: ViewState) !ArrayList(Renderable)
- Builds fresh renderable list each frame
- Z-order: avatar → enemies → in_play → hand → always_available → hovered/dragged (last)
- Returns Renderable union (sprite, text, filled_rect, card, log_pane)

4. Existing vs Planned Play Representation

PlayViewData (lines 78-112) - ALREADY EXISTS

Purpose: View model for committed plays (action + modifiers).

Current Structure:
const PlayViewData = struct {
    const max_modifiers = combat.Play.max_modifiers; // 4

    // Ownership
    owner_id: entity.ID,
    owner_is_player: bool,

    // Cards in the play
    action: CardViewData,
    modifier_stack_buf: [max_modifiers]CardViewData,
    modifier_stack_len: u4,
    stakes: cards.Stakes,

    // Targeting
    target_id: ?entity.ID,

    // TODO: Resolution context (commented out)
    // timing, matchup, outcome
};

Helpers:
- modifiers() - slice access to modifier stack
- cardCount() - total cards (1 + modifier_stack_len)
- isOffensive() - checks action.template.tags.offensive

Status: Defined but NOT YET USED in rendering pipeline.

Domain Play Structure (src/domain/combat.zig:639-669)

pub const Play = struct {
    action: entity.ID,
    modifier_stack_buf: [max_modifiers]entity.ID,
    modifier_stack_len: usize,
    stakes: cards.Stakes,
    added_in_commit: bool,

    // Applied by modify_play effects
    cost_mult: f32,
    damage_mult: f32,
    advantage_override: ?TechniqueAdvantage,
};

Storage: AgentEncounterState.current.plays (TurnState)

Target Determination: NOT stored in Play - resolved at tick time via:
- card.template.expression.target (TargetQuery enum)
- Evaluates to entities dynamically (e.g., all_enemies, single: Selector)

5. DragState and Interaction

DragState (src/presentation/view_state.zig:69-74)

pub const DragState = struct {
    id: entity.ID,              // card being dragged
    original_pos: Point,        // grab position
    target: ?entity.ID = null,  // highlighted drop target
};

Current Drag Behavior:
- Dragging modifier cards sets DragState.target to card ID under cursor (line 537)
- CardZoneView applies visual states: .drag for dragged card, .target for highlighted drop target
- On release: drag state cleared (snap back) - no command dispatched yet

Drop Target Detection (lines 527-544):
- Currently checks inPlayZone().hitTest() to find target card
- Sets drag.target = id for visual feedback
- Does NOT call validation functions yet

CombatUIState (src/presentation/view_state.zig:56-61)

pub const CombatUIState = struct {
    drag: ?DragState,
    selected_card: ?entity.ID,
    hover: EntityRef,           // union: none, card, enemy
    log_scroll: usize,
};

6. Architecture Assessment: PlayViewModel Integration

Key Question: Replace CardZoneView or Wrap It?

Option A: Replace CardZoneView for in_play during commit phase
// New structure
const PlayZoneView = struct {
    plays: []const PlayViewData,
    layout: CardLayout,

    fn hitTest(...) ?PlayHitResult // returns play_index + card_id
    fn appendRenderables(...) // renders grouped plays
};

Option B: Parallel structure alongside CardZoneView
// Add to CombatView
fn playerPlays(alloc) []const PlayViewData
fn enemyPlays(agent, alloc) []const PlayViewData

// Rendering
if (commit_phase) {
    render plays with grouping
} else {
    render flat in_play zone
}

Recommendation: Option B - Parallel Structure

Rationale:
1. Phase Distinction: Selection phase needs individual cards (for cancellation), commit phase needs plays (for modifier attachment)
2. Minimal Disruption: CardZoneView works well for hand/always_available - don't change it
3. Clear Separation: Different data sources (CombatState.in_play vs AgentEncounterState.plays)
4. PlayViewData Already Exists: Just needs population + rendering logic

7. Data Flow for Play Rendering

Required Steps:

1. Query plays from encounter:
fn playerPlays(self: *const CombatView, alloc: Allocator) ![]PlayViewData {
    const enc = self.world.encounter orelse return &.{};
    const state = enc.stateFor(self.world.player.id) orelse return &.{};

    const result = try alloc.alloc(PlayViewData, state.current.plays_len);
    for (state.current.plays(), 0..) |play, i| {
        result[i] = try self.buildPlayViewData(play, alloc);
    }
    return result;
}

2. Build PlayViewData from domain Play:
fn buildPlayViewData(self: *const CombatView, play: combat.Play, alloc: Allocator) !PlayViewData {
    const action_inst = self.world.card_registry.getConst(play.action) orelse ...;

    var pvd = PlayViewData{
        .owner_id = self.world.player.id,
        .owner_is_player = true,
        .action = CardViewData.fromInstance(action_inst, .in_play, true),
        .stakes = play.stakes,
        .target_id = null, // computed separately if offensive
    };

    for (play.modifiers(), 0..) |mod_id, i| {
        const mod_inst = self.world.card_registry.getConst(mod_id) orelse continue;
        pvd.modifier_stack_buf[i] = CardViewData.fromInstance(mod_inst, .in_play, true);
        pvd.modifier_stack_len += 1;
    }

    // If offensive, determine target
    if (pvd.isOffensive()) {
        pvd.target_id = try self.resolvePlayTarget(action_inst);
    }

    return pvd;
}

3. Render grouped plays:
- Action card at base position
- Modifiers fanned/stacked behind (offset by spacing)
- Highlight entire play group on hover
- Hit-testing returns both play_index and card_id within play

8. Outstanding Questions

1. Target Determination: Plays don't store target_id - it's resolved at tick time. For commit phase display:
    - Option A: Leave target_id null (no visual indication)
    - Option B: Evaluate TargetQuery during rendering (expensive, couples UI to game logic)
    - Option C: Determine on transition to commit_phase, cache in PlayViewData or parallel structure
2. Grouped Card Layout:
    - Fan modifiers behind action (card poker style)?
    - Stack vertically with slight offset?
    - Side-by-side with action larger?
3. Hit-Testing Grouped Plays:
    - Click action card → withdraw entire play?
    - Click modifier card → remove just that modifier?
    - Need distinct hit regions or unified?
4. Drag Target Validation:
    - Currently checks hitTest() for any card ID
    - Should check canModifierAttachToPlay() + wouldConflict()
    - Need access to play index, not just card ID

Summary

Current State:
- CardViewModel and CardZoneView are mature, well-designed for individual cards
- PlayViewData structure exists but unused
- Commit phase currently renders flat in_play cards (no play grouping)
- Drag infrastructure exists but validation not connected

Path Forward:
- PlayViewData should parallel CardZoneView, not replace it
- Add playerPlays()/enemyPlays() query methods to CombatView
- Implement play grouping renderer (fanned cards or stacked layout)
- Connect drag validation to canModifierAttachToPlay() + Play.wouldConflict()
- Dispatch commit_stack command on valid modifier drop

---
---
PlayZoneView Implementation Plan

Summary

- Keep CardZoneView for hand/always_available (unchanged)
- Add PlayZoneView for in_play during commit phase
- Selection phase continues using flat CardZoneView for in_play

1. Domain: Add target resolution facade to Play (combat.zig)

/// Resolve target agent IDs for this play's action.
/// Returns null if non-offensive, otherwise the target IDs.
pub fn resolveTargetIDs(
    self: *const Play,
    actor: *const Agent,
    world: *World,
    alloc: Allocator,
) !?[]const entity.ID {
    const card = world.card_registry.getConst(self.action) orelse return null;
    if (!card.template.tags.offensive) return null;

    const expr = card.template.getTechniqueWithExpression();
    const query = if (expr) |e| e.expression.target else .all_enemies;

    var targets = try apply.evaluateTargets(alloc, query, actor, world);
    defer targets.deinit(alloc);

    const ids = try alloc.alloc(entity.ID, targets.items.len);
    for (targets.items, 0..) |agent, i| {
        ids[i] = agent.id;
    }
    return ids;
}

2. Presentation: Add PlayZoneView (combat.zig view)

const PlayZoneView = struct {
    plays: []const PlayViewData,
    layout: CardLayout,
    play_index: usize,  // for hit testing result

    /// Hit test returning play index (not card ID)
    pub fn hitTest(self: *const PlayZoneView, vs: *const ViewState, pt: Point) ?usize {
        // Reverse order for z-order (last rendered = on top)
        var i = self.plays.len;
        while (i > 0) {
            i -= 1;
            const rect = self.playRect(i, vs);
            if (rect.contains(pt)) return i;
        }
        return null;
    }

    /// Compute rect for entire play stack (action + modifiers)
    fn playRect(self: *const PlayZoneView, index: usize, vs: *const ViewState) Rect {
        const play = self.plays[index];
        const base_x = self.layout.start_x + @as(i32, @intCast(index)) * (self.layout.w + self.layout.spacing);
        const stack_height = self.layout.h + @as(i32, @intCast(play.modifier_stack_len)) * modifier_offset;
        return Rect{ .x = base_x, .y = self.layout.y, .w = self.layout.w, .h = stack_height };
    }

    /// Generate renderables for all plays (solitaire-style stacking)
    pub fn appendRenderables(self: *const PlayZoneView, alloc: Allocator, vs: *const ViewState, list: *ArrayList(Renderable)) !void {
        for (self.plays, 0..) |play, i| {
            try self.appendPlayRenderables(alloc, vs, list, play, i);
        }
    }

    fn appendPlayRenderables(...) !void {
        // Render modifiers first (behind)
        for (play.modifiers(), 0..) |mod, j| {
            const offset_y = @as(i32, @intCast(j + 1)) * modifier_offset;
            // render mod card at (base_x, base_y - offset_y)
        }
        // Render action card last (in front)
        // Apply target highlight if dragging modifier and this is valid target
    }
};

const modifier_offset: i32 = 20; // vertical offset for stacked modifiers

3. CombatView: Add play query methods

/// Get player's plays for commit phase rendering
fn playerPlays(self: *const CombatView, alloc: Allocator) ![]PlayViewData {
    const enc = self.world.encounter orelse return &.{};
    const state = enc.stateFor(self.world.player.id) orelse return &.{};

    var result = try alloc.alloc(PlayViewData, state.current.plays_len);
    for (state.current.plays(), 0..) |play, i| {
        result[i] = try self.buildPlayViewData(&play, self.world.player, alloc);
    }
    return result;
}

fn buildPlayViewData(self: *const CombatView, play: *const combat.Play, owner: *const Agent, alloc: Allocator) !PlayViewData {
    const action_inst = self.world.card_registry.getConst(play.action) orelse return error.BadInvariant;

    var pvd = PlayViewData{
        .owner_id = owner.id,
        .owner_is_player = owner.director == .player,
        .action = CardViewData.fromTemplate(play.action, action_inst.template, .in_play, true),
        .stakes = play.effectiveStakes(),
    };

    // Add modifiers
    for (play.modifiers()) |mod_id| {
        const mod_inst = self.world.card_registry.getConst(mod_id) orelse continue;
        pvd.modifier_stack_buf[pvd.modifier_stack_len] = CardViewData.fromTemplate(mod_id, mod_inst.template, .in_play, true);
        pvd.modifier_stack_len += 1;
    }

    // Resolve target if offensive
    if (pvd.isOffensive()) {
        if (try play.resolveTargetIDs(owner, self.world, alloc)) |ids| {
            if (ids.len > 0) pvd.target_id = ids[0];
        }
    }

    return pvd;
}

/// Get PlayZoneView for commit phase
fn playerPlayZone(self: *const CombatView, alloc: Allocator) !PlayZoneView {
    return PlayZoneView{
        .plays = try self.playerPlays(alloc),
        .layout = in_play_layout,
    };
}

4. Rendering: Switch based on phase

fn renderables(self: *const CombatView, alloc: Allocator, vs: ViewState) !ArrayList(Renderable) {
    // ...

    // In-play zone: plays during commit, flat cards during selection
    if (self.world.fsm.currentState() == .commit_phase) {
        const play_zone = try self.playerPlayZone(alloc);
        try play_zone.appendRenderables(alloc, &vs, &list);
    } else {
        const in_play = self.inPlayZone(alloc);
        try in_play.appendRenderables(alloc, &vs, &list, null);
    }

    // ...
}

5. Drop target validation

fn handleDragging(self: *CombatView, ui: *CombatUIState, mouse: Point) void {
    const drag = &(ui.drag orelse return);
    const card = self.world.card_registry.getConst(drag.id) orelse return;

    if (card.template.kind != .modifier) return;

    // During commit phase, hit test against plays
    if (self.world.fsm.currentState() == .commit_phase) {
        const play_zone = self.playerPlayZone(self.arena) catch return;
        if (play_zone.hitTest(&self.vs, mouse)) |play_index| {
            const play = &self.getEncounterState().current.plays()[play_index];

            // Validate attachment
            if (apply.canModifierAttachToPlay(card.template, play, self.world) catch false) {
                if (!play.wouldConflict(card.template, &self.world.card_registry)) {
                    drag.target_play_index = play_index;  // new field
                    return;
                }
            }
        }
    }
    drag.target_play_index = null;
}

6. DragState: Add play index

pub const DragState = struct {
    id: entity.ID,
    original_pos: Point,
    target: ?entity.ID = null,           // kept for card-to-card drops
    target_play_index: ?usize = null,    // for modifier-to-play drops
};