# Handover Notes

## 2026-01-04: Card Hover Rendering Bug (UNRESOLVED)

### Symptoms

When entering or exiting hover state on a card (hand or in-play):
1. A partial card appears at viewport origin (0, 0) - visible under the chrome header bar
2. Only bottom/right borders and grey background square visible (top occluded by header)
3. Border colors vary: sometimes green, sometimes white, sometimes mixed
4. Sprites (player/enemy avatars) and other cards momentarily flicker black
5. Status bar and end turn button are NOT affected (they use `filled_rect` and a texture respectively)
6. Enemy hover (which renders a `filled_rect` tooltip) works fine - no glitches

### Root Cause Analysis

The issue occurs when card textures are re-rendered mid-frame due to state change (highlighted flag).

In `card_renderer.zig`, `getCardTexture()` detects state change and calls `renderCard()`:
```zig
fn renderCard(...) {
    // Create texture, switch render target, draw card content, restore target
    const prev_target = self.renderer.getTarget();
    try self.renderer.setTarget(tex);
    defer self.renderer.setTarget(prev_target) catch {};
    // ... draw operations at (0,0) relative to texture ...
}
```

This happens during `graphics.zig` `renderList()` iteration, WHILE a viewport is active:
- `renderWithViewport()` sets viewport to `(0, 100, 1420, 880)` (chrome game area)
- Card rendering triggers texture creation mid-iteration
- Draw operations intended for the texture appear to also affect the screen

Debug output showed:
```
prev_target=null, prev_viewport=.{ .x = 0, .y = 100, .w = 1420, .h = 880 }
```

### What Was Tried

1. **Save/restore viewport** in `renderCard()` - no effect
2. **Reset viewport to null** before drawing to texture - no effect
3. **Defer old texture destruction** until after new one created - no effect
4. **Add debug print for cards at origin** - nothing printed (no Renderable has dst at 0,0)
5. **Verify setTarget worked** - no warning printed

Key insight: No card Renderable has `dst` at (0,0), yet a card visually appears there. The artifact is coming from the texture creation process itself, not from a misplaced renderable.

### Alternative Theory: Arena Allocator / Stale Memory

The texture creation mid-render theory may be wrong. Another possibility:
- The arena allocator used for CardViewData might be showing stale memory contents
- `CombatView.arena` is `self.alloc` from Coordinator - need to verify this isn't being reset/reused unexpectedly
- The varying border colors (green/white) could indicate stale CardViewData with garbage values

Worth investigating:
1. What allocator is actually being passed to CombatView? Is it an arena that gets reset?
2. Add debug output to verify CardViewData contents are valid when renderables are built
3. Check if the Renderable list itself contains stale entries

### Original Theory: Texture Creation Mid-Render

Don't create textures mid-render while viewport is active. Options:
1. **Pre-pass**: Before `renderWithViewport()`, iterate all cards and ensure textures are cached
2. **Cache both states**: Pre-create highlighted and non-highlighted textures for each card
3. **Defer texture creation**: Queue texture updates, process them before next frame's render

### Files Involved
- `src/presentation/card_renderer.zig` - texture caching and creation
- `src/presentation/graphics.zig` - `renderCard()` calls `getCardTexture()`
- `src/presentation/coordinator.zig` - `render()` calls `renderWithViewport()`

---

## 2026-01-04: View Layer Migration Complete

### Completed This Session

**Hit testing migrated to new architecture**
- Added `arena: std.mem.Allocator` field to CombatView
- Updated `CombatView.init(world, arena)` to take allocator from Coordinator
- `handleInput()` now uses `handZone(arena)` / `inPlayZone(arena)` with allocator
- Added `enemyInPlayCards(alloc, agent)` query for multi-enemy support

**Legacy view code removed**
- Removed `LegacyCardZoneView` struct (was using Instance pointers)
- Removed legacy zone helpers: `handZone()`, `inPlayZone()`, `enemyInPlayZone()` (replaced with allocator-based versions)
- Removed legacy query methods: `playerHand()`, `playerInPlay()`, `enemy()`, `enemyInPlay()` (accessed Deck directly)
- Removed orphaned `cardViewState()` helper function

**Enemy rendering improved**
- Commit phase now supports multiple enemies (iterates `opposition.enemies` with offset layout)

### Ready for Phase 7 Completion

**Remove legacy Deck storage**
- `Deck.entities` SlotMap - instances now in `World.card_registry`
- `Deck.draw`, `Deck.hand`, `Deck.discard`, `Deck.in_play`, `Deck.exhaust` - zones now in `Agent.combat_state`

No more view layer references to Deck zone fields. All lookups use:
- `combat_state.hand.items` / `combat_state.in_play.items` (zone IDs)
- `world.card_registry.getConst(id)` (instance lookup)

---

## 2026-01-04: View Layer Migration (Partial) [superseded]

### Completed This Session

**View layer decoupled from Deck storage (rendering)**
- Renamed `view_state.CombatState` → `CombatUIState` to avoid naming collision with domain `combat.CombatState`
- Added `ViewZone` enum for view-specific zone types
- Added `CardViewData` struct (id, template, playable, source) - decoupled from Instance pointers
- Added `PlayViewData` struct (owner, primary, reinforcements, stakes) - for commit/resolution phases
- New CombatView query methods: `handCards(alloc)`, `inPlayCards(alloc)` - use CombatState zones + CardRegistry
- Refactored `CardZoneView` to use `[]const CardViewData` instead of `[]const *cards.Instance`
- `renderables()` now uses new query methods for player cards
- Added `CardRegistry.getConst()` and `SlotMap.getConst()` for const-correct lookups
- Changed `apply.validateCardSelection()` to take `*const Agent` and `*const Instance`

**Design doc updated** (`doc/view_card_design.md`)
- Clarified allocator pattern (parameter, not stored field)
- Added CombatUIState rename
- Updated CardZoneView with ViewState for drag/hover
- Marked speculative PlayViewData fields as TODO comments

**Phase 7 completion**
- Remove `Deck.entities` SlotMap and zone ArrayLists (once all Deck references gone)

**Phase 8**
- Wire `cleanupCombatState()` when combat termination exists

---

## 2026-01-04: Phase 7 Partial + View Layer Design

### Completed This Session

**Phase 7 partial: Domain layer cleanup**
- `SimpleDeckDirector` migrated to use `combat_state.hand` + `card_registry.get()`
- `ai.Director` interface simplified: `playCards(agent, world)` (removed redundant player/events params)
- Removed dead code from `deck.zig`: `TagIterator`, `countByTag()`, `drawableByTag()`, 4 tests
- Added `entity.ID.eql()` method, updated all ID comparisons across codebase

**Remaining legacy Deck zone references** (view layer only):
- `views/combat.zig:315` - `playerHand()` → `deck.hand.items`
- `views/combat.zig:319` - `playerInPlay()` → `deck.in_play.items`
- `views/combat.zig:331` - `enemyInPlay()` → `deck.in_play.items`

**View layer design document created**: `doc/view_card_design.md`
- Defines `CardViewData` (individual cards) and `PlayViewData` (committed plays)
- Query interface for CombatView: `handCards()`, `techniques()`, `playerPlays()`, etc.
- Layout concepts for multi-enemy, resolution matchups, stacks
- Migration steps and open questions

### Next Task: View Layer Migration

See `doc/view_card_design.md` for full design. Summary:

1. Add `CardViewData` and `PlayViewData` structs
2. Add frame allocator to CombatView
3. Implement query methods (build view data from combat_state + registry)
4. Refactor `CardZoneView` to use `[]const CardViewData`
5. Add `PlayZoneView` for committed plays
6. Remove legacy Deck zone access

### After View Migration

- Phase 7 complete: Remove `Deck.entities` SlotMap and zone ArrayLists
- Phase 8: Wire `cleanupCombatState()` when combat termination exists

---

## 2026-01-04: Card Storage Architecture - Phases 1-6 Complete

### Context
Implementing new card storage architecture per `doc/card_storage_design.md`. Goal: unified card registry at World level, with Agent containers for techniques_known, deck_cards, etc.

### Completed

**Phase 1: CardRegistry added to World** (`world.zig`)
- `CardRegistry` struct: `create()`, `get()`, `remove()`, `createFromTemplates()` methods
- `World.card_registry` field initialized/deinitialized
- Note: `remove()` invalidates ID but doesn't free memory (freed on deinit)

**Phase 2: Agent containers added** (`combat.zig`)
- `CombatState` struct: transient draw/hand/discard/in_play/exhaust (per-encounter)
- Agent gains: `techniques_known`, `spells_known`, `deck_cards`, `inventory`, `combat_state`
- Removed EquipmentSlots (weapons via Armament, armor via armour.Stack already)
- Fields have defaults for test compatibility

**Phase 3: Encounter environment added** (`combat.zig`)
- `Encounter.environment: ArrayList(entity.ID)` - holds thrown items, rubble, lootable cards
- `Encounter.thrown_by: AutoHashMap(entity.ID, entity.ID)` - maps card → original owner for recovery
- Both initialized in `Encounter.init()`, deinitialized in `Encounter.deinit()`

**Phase 4: Card lookups migrated to CardRegistry** (`apply.zig`, `tick.zig`, `deck.zig`)
- `Deck.initWithRegistry()` creates instances via CardRegistry (IDs come from registry)
- `Deck.copyCardIdsTo()` populates Agent.deck_cards from Deck instances
- World.init uses `initWithRegistry`, populates player.deck_cards
- Card lookups use `world.card_registry.get(id)` instead of `deck.entities.get(id)`:
  - `commitStack()` - look up primary card for template matching
  - `canPlayerPlayCard()` - UI validation
  - `playMatchesPredicate()` - play targeting (now takes *World)
  - `commitPlayerCards()` in tick.zig (now takes *World)
- CombatState zone helpers added: `CombatZone`, `zoneList()`, `isInZone()`, `moveCard()`, `shuffleDraw()`, `populateFromDeckCards()`
- Agent helpers: `initCombatState()`, `cleanupCombatState()`

**Phase 5: CombatState wired into combat flow** (`apply.zig`, `tick.zig`, `world.zig`)
- Combat state initialization: `initAllCombatStates()` called when entering `draw_hand` state
- All zone operations now use CombatState instead of Deck:
  - `shuffleAndDraw()` uses `combat_state.moveCard()` and `combat_state.shuffleDraw()`
  - `playValidCardReservingCosts()` uses `combat_state.moveCard(.hand, .in_play)`
  - `validateCardSelection()` uses `combat_state.isInZone(id, .hand)`
  - `playActionCard()` uses `combat_state.isInZone()` and `card_registry.get()`
  - `cancelActionCard()` uses `combat_state.moveCard(.in_play, .hand)`
  - `commitWithdraw()` uses `combat_state.moveCard(.in_play, .hand)` and `card_registry.get()`
  - `commitAdd()` uses `combat_state.isInZone()` and `card_registry.get()`
  - `commitStack()` uses `combat_state.isInZone()` and `card_registry.get()`
  - `buildPlaysForAgent()` uses `combat_state.in_play` for deck-based agents
  - `applyCommittedCosts()` uses `combat_state.moveCard(.in_play, .discard/.exhaust)`
  - `executeCommitPhaseRules()` iterates `combat_state.in_play` IDs
  - `commitSingleMob()` in tick.zig uses `combat_state.in_play` for deck-based mobs
- Key pattern: zone operations use CombatState (stores IDs), instance lookups use `card_registry.get(id)`

**Phase 6: Template Playability Metadata** (`cards.zig`, `apply.zig`)
- Added `PlayableFrom` packed struct with source flags: hand, techniques_known, spells_known, equipped, inventory, environment
- Added convenience constants: `PlayableFrom.hand_only`, `.technique`, `.spell`
- Added `Template.playable_from: PlayableFrom` (default: `.hand_only`)
- Added `Template.combat_playable: bool` (default: `true`)
- Added `ValidationError.NotCombatPlayable` and `ValidationError.InvalidPlaySource`
- Added `isInPlayableSource()` helper to check card location against playable_from flags
- Updated `validateCardSelection()` to check `combat_playable` and `playable_from`
- Note: equipped and environment source checks require World access (TODO)

### Remaining Phases
7. Remove legacy `Deck.entities` and zone ArrayLists
8. Add `cleanupCombatState()` call at combat end (when combat termination is implemented)

### Decisions & Notes from Phase 5

**Optional World in commitSingleMob:**
- `commitSingleMob(mob, w: ?*World)` - World is optional because pool-based mobs don't need registry access
- Existing tests use `null` for pool-based mob tests (no World setup needed)
- Deck-based mobs require World for `card_registry.get()` lookups

**cleanupCombatState not yet called:**
- No "combat ends" state in current FSM - cleanup will need wiring when combat termination is implemented
- For now, combat_state persists until agent is deallocated

**Deck still has redundant zone ArrayLists:**
- `Deck.draw`, `Deck.hand`, `Deck.discard`, etc. are now unused during combat (CombatState handles zones)
- Can be removed in Phase 7 after verifying no remaining references

**CombatZone vs cards.Zone:**
- `combat.CombatZone` enum has 5 values: draw, hand, in_play, discard, exhaust
- `cards.Zone` has 7 values: adds equipped, inventory
- Events still use `cards.Zone` for `.card_moved` - values match for common zones

### Next Task: Phase 7 - Remove Legacy Deck Storage

**Goal:** Remove now-redundant storage from Deck since CombatState handles zones and CardRegistry handles instances.

**What to remove:**
1. `Deck.entities: SlotMap(*Instance)` - instances now in World.card_registry
2. `Deck.draw`, `Deck.hand`, `Deck.discard`, `Deck.in_play`, `Deck.exhaust` - zones now in CombatState
3. Potentially simplify or remove `Strat` union if TechniquePool is no longer used

**Before removing, verify:**
- No remaining references to Deck zone fields
- All card lookups use `world.card_registry.get(id)`
- All zone operations use `combat_state` methods

### Key Files
- `doc/card_storage_design.md` - full architecture design
- `src/domain/world.zig` - CardRegistry, World.init uses initWithRegistry
- `src/domain/combat.zig` - CombatState, CombatZone, Agent containers, Encounter.environment
- `src/domain/deck.zig` - initWithRegistry, copyCardIdsTo
- `src/domain/apply.zig` - all zone operations now use combat_state
- `src/domain/tick.zig` - commitPlayerCards and commitSingleMob use card_registry

---

## 2026-01-03: Phase 3 Fixes Applied

### Completed

**Auto-transition bug fixed**
- Removed auto-transition from commit_phase to tick_resolution in `apply.zig`
- Player must now explicitly call `commit_done` to proceed

**TagSet phase flags added**
- Added `.phase_selection` and `.phase_commit` flags to TagSet
- Added `TagSet.canPlayInPhase(phase)` method
- Updated bitcast size from u13 to u15

**Phase validation wired into card selection**
- `validateCardSelection()` now takes a `phase` parameter
- Checks `template.tags.canPlayInPhase(phase)` before other validations
- Added `ValidationError.WrongPhase` and `CommandError.WrongPhase`
- `isCardSelectionValid()` wrapper assumes selection phase (for AI directors)

**Renamed canUseCard → rulePredicatesSatisfied**
- Clarifies that function only checks rule.valid predicates (weapon requirements)
- Updated all call sites and tests

**Stacking cost fixed (1F total)**
- Added `TurnState.stack_focus_paid: bool` flag
- `commitStack` only charges Focus on first stack; subsequent stacks free
- Updated command comments in `commands.zig`

**executeCommitPhaseRules clarified**
- Added docstring explaining trigger vs playability distinction
- Cards in_play already had costs validated during selection
- Phase flags (`.phase_commit`) prevent wrong-phase plays

**TODO added for integration tests**
- `combat.zig` now has TODO comment listing missing test coverage

**Card templates updated**
- All cards in `card_list.zig` now have `.phase_selection = true`
- Explicit phase flags required (no backwards-compatible default)

**UI validation function added**
- `apply.canPlayerPlayCard(world, card_id) bool` for UI greying out unplayable cards
- Derives phase from `world.fsm.currentState()`

### Files Changed
- `apply.zig` - validation, error types, renamed function, stacking cost fix, docstrings, canPlayerPlayCard
- `cards.zig` - TagSet phase flags and canPlayInPhase method
- `card_list.zig` - all cards have `.phase_selection = true`
- `combat.zig` - stack_focus_paid flag, TODO for tests
- `tick.zig` - updated function call
- `commands.zig` - updated comments

### Design Direction: Model B

See `focus_design.md` "Design Evolution" section for full details.

**Summary:**
- Techniques always available (from pool), not dealt
- Hand contains modifier cards (height, commitment, tempo)
- Play = technique + modifier_stack
- Computed properties (cost_mult, damage_mult) derived on-demand from modifier_stack
- Feint becomes a modifier, not a technique

**Next steps (not started):**
1. Refactor Play struct (technique + modifier_stack)
2. Add computed property methods
3. Create modifier card templates
4. Update resolution to use computed properties
5. Move techniques to pool

---

## 2026-01-02: Phase 3 Review - Issues Identified

### Bugs

**Auto-transition in commit_phase (blocking)**
- `apply.zig:455-459`: EventProcessor immediately transitions to tick_resolution after executing on_commit rules
- Player never gets opportunity to use Focus spending commands (withdraw/add/stack)
- `commit_done` command is unreachable
- **Fix**: Remove auto-transition; let player explicitly call `commit_done`

### Design Issues

**`on_commit` trigger misinterpretation**
- Current code interprets `on_commit` as "fire this rule's effects when entering commit phase"
- Design intent for Feint: "this card can only be PLAYED during commit phase"
- These are orthogonal concepts:
  1. Playability window (when can card enter play?)
  2. Effect trigger (when do card's rules fire?)
- **Fix**: Add TagSet flags for playability phases; Feint uses `.phase_commit` + standard `.on_play` trigger
- Note: `executeCommitPhaseRules` is still valid for cards with actual `on_commit` triggered effects

**Stacking cost calculation**
- Design doc: "You can stack any number of matching cards for 1F"
- Implementation: `commitStack()` charges 1F per card
- **Clarify**: Which is intended?

### Validation Gaps

**Focus cost not checked in executeCommitPhaseRules**
- `validateCardSelection()` checks Focus cost
- `executeCommitPhaseRules()` uses `canUseCard()` which only checks weapon predicates
- Cards with Focus cost could bypass validation

### Naming

**`canUseCard` is misleading**
- Only checks rule validity predicates (weapon requirements)
- Does not check stamina, time, focus, or zone
- **Rename**: `cardRulePredicatesSatisfied` or similar

### Missing Test Coverage

- Focus spending commands (withdraw/add/stack) integration tests
- `commit_withdraw` stamina refund
- `commit_add` sets `added_in_commit` flag
- `commit_stack` template matching enforcement
- `executeCommitPhaseRules` with actual on_commit triggered cards

### TagSet Extension Required

Add playability phase flags:
```zig
pub const TagSet = packed struct {
    // ...existing...
    phase_selection: bool = false,  // playable during selection (default for most)
    phase_commit: bool = false,     // playable during commit (Focus cards)
};
```

Wire into validation:
```zig
fn canPlayInPhase(tags: TagSet, phase: GameState) bool {
    return switch (phase) {
        .player_card_selection => tags.phase_selection,
        .commit_phase => tags.phase_commit,
        else => false,
    };
}
```

---

## 2026-01-02: Focus System Phase 3 Complete

### Implemented

**3.1: FSM Fix**
- Fixed typo `.begin_commit_phask` → `.begin_commit_phase` in world.zig

**3.2: Commit Phase Handler**
- `buildPlaysFromInPlayCards()` creates Play structs from in_play cards on entering commit_phase
- Executes `on_commit` rules for player and mobs during commit phase
- Auto-transitions to tick_resolution after commit phase processing

**3.3: New Trigger**
- Added `on_commit` to Trigger enum for cards that fire during commit phase (e.g., Feint)

**3.4: Play Targeting**
- Added `my_play: Predicate` and `opponent_play: Predicate` to TargetQuery
- Added `evaluatePlayTargets()` to find plays matching predicate
- Added `playMatchesPredicate()` for tag-based play filtering

**3.5: Play Effects**
- Added `modify_play` effect: cost_mult, damage_mult, replace_advantage
- Added `cancel_play` effect: removes target play
- Added `applyCommitPhaseEffect()` to apply effects to Play structs

**3.6: TurnState Methods**
- Added `TurnState.removePlay(index)` - removes play, shifts array
- Added `TurnState.findPlayByCard(card_id)` - returns play index

**3.7: Focus Spending Commands**
- `commit_withdraw`: 1F, remove card from play, refund stamina
- `commit_add`: 1F, add card from hand as new play (marked `added_in_commit`)
- `commit_stack`: 1F, reinforce existing play (same template required)
- `commit_done`: finish commit phase, transition to tick_resolution

**3.8: Tick Resolution Updates**
- `CommittedAction` now carries `damage_mult` and `advantage_override`
- `commitPlayerCards()` reads from `AgentEncounterState.current.plays`
- Uses Play's `cost_mult` for time, `effectiveStakes()` for stakes

**3.9: Focus Validation**
- `validateCardSelection()` checks `agent.focus.available >= template.cost.focus`
- Added `InsufficientFocus` error to ValidationError

### Key Files Changed
- `world.zig` - FSM typo fix, processTick passes encounter
- `cards.zig` - on_commit trigger, my_play/opponent_play targeting, modify_play/cancel_play effects
- `combat.zig` - TurnState.removePlay(), TurnState.findPlayByCard()
- `apply.zig` - buildPlaysFromInPlayCards, executeCommitPhaseRules, evaluatePlayTargets, commit commands, Focus validation
- `tick.zig` - CommittedAction damage_mult/advantage_override, commitPlayerCards uses plays
- `commands.zig` - commit_withdraw, commit_add, commit_stack, commit_done

### Tests Added
- `TurnState.removePlay` shifts remaining plays
- `TurnState.removePlay` handles out of bounds
- `TurnState.findPlayByCard` returns correct index

### Remaining (per design doc)
- Phase 4: Draw decision mechanics
- Phase 5: Transform cards (Feint)

---

## 2026-01-02: Test Coverage Backfill

- `stats.Resource`: 5 tests covering commit/finalize, uncommit, spend, tick, reset
- `AgentPair.canonical`: assertion for self-engagement (a==b), test for order invariance
- `Play.addReinforcement`, `TurnState.addPlay`: overflow error tests

---

## 2026-01-02: Focus System Phase 1.5 Complete

### Implemented

**1.5: Turn State Structs**
- Added `Play` struct with reinforcements buffer, stakes escalation, modifiers
- Added `TurnState` struct tracking plays and focus_spent
- Added `TurnHistory` ring buffer (4 turns) with push/lastTurn/turnsAgo
- Added `AgentEncounterState` wrapping current turn + history
- Added `Encounter.agent_state` hashmap with `stateFor()` accessor
- Player and enemy states auto-initialized in `Encounter.init()`/`addEnemy()`
- Note: BoundedArray removed in Zig 0.15, replaced with buffer+len pattern

### Key Files Changed
- `combat.zig` - Play, TurnState, TurnHistory, AgentEncounterState, Encounter.agent_state

---

## 2026-01-02: Focus System Phase 2 Complete

### Implemented

**2.1: TagSet Extension**
- Added `manoeuvre` tag to `TagSet` packed struct
- Updated bitcast size from `u12` to `u13`

**2.2: Draw Filtering**
- Added `TagIterator` struct for iterating cards by tag
- Added `Deck.countByTag()` - count cards in draw pile matching tag mask
- Added `Deck.drawableByTag()` - iterate draw pile by tag mask
- Added 4 tests for tag filtering functionality

### Key Files Changed
- `cards.zig` - TagSet.manoeuvre, updated bitcasts
- `deck.zig` - TagIterator, countByTag(), drawableByTag(), tests

### Remaining (per design doc)
- Phase 3: Commit phase mechanics
- Phase 4: Draw decision mechanics
- Phase 5: Transform cards (Feint)

---

## 2026-01-02: Focus System Phase 1 Complete

### Implemented

**1.1-1.3: Resource System**
- Added `stats.Resource` struct with commit/spend/finalize semantics
- Replaced `Agent.stamina`/`stamina_available` with `stamina: Resource`
- Added `Agent.focus: Resource`
- Added `Cost.focus: f32 = 0`

**1.4: Encounter State Migration**
- Added `AgentPair` for canonical agent pair keys
- Added `Encounter.engagements: AutoHashMap(AgentPair, Engagement)`
- Added `Encounter.player_id`, `getEngagement()`, `setEngagement()`, `addEnemy()`
- Removed `Agent.engagement` field
- Updated `ConditionIterator` to take optional engagement parameter
- Migrated all engagement lookups to use Encounter

### Remaining (Phase 1.5 per design doc)
- `TurnState`, `TurnHistory`, `Play` structs not yet added
- `AgentEncounterState` not yet wired up

### Default Resource Values
```zig
stamina: Resource.init(10.0, 10.0, 2.0)  // default, max, per_turn
focus: Resource.init(3.0, 5.0, 3.0)
```

### Key Files Changed
- `stats.zig` - Resource struct
- `combat.zig` - Agent, Encounter, AgentPair, ConditionIterator
- `cards.zig` - Cost.focus
- `apply.zig`, `tick.zig`, `resolution.zig` - engagement lookups
- `world.zig` - Encounter init ordering
- `harness.zig` - uses `addEnemy()`