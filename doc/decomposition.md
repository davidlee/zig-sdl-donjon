 Key Findings

  - src/domain/apply.zig:118-1775 currently mixes unrelated responsibilities: CommandHandler orchestrates
    world transitions, EventProcessor mutates encounters, predicate/target evaluation lives alongside
    condition ticking, cost enforcement, manoeuvre resolution, and a large block of tests. The file imports
    most of the domain just to support those cross-cutting concerns, which makes it hard to reason about a
    single phase of play.
  - src/domain/combat.zig:1-760 defines almost every combat data structure (Armament, Agent, CombatState,
    Encounter, Play/Timeline, TurnState, AdvantageEffect, etc.) in one monolith. Types that never interact
    at runtime (e.g. the draw/deck containers vs. the advantage math) still share state, making the file
    hard to navigate and discouraging focused tests.
  - src/domain/tick.zig:1-220 handles three concepts—CommittedAction/TickResolver data objects, the logic
    for committing player/mob actions, and the attack/defense resolution pipeline—while also depending on
    apply.evaluateTargets and resolution.resolveTechniqueVsDefense. The resolver is forced to know about
    UI-only targeting rules, and tests for time sorting sit next to combat resolution code.
  - src/domain/resolution.zig:1-320 mixes outcome enums, combat modifier aggregation, advantage
    calculations, overlay bonuses, hit-location selection, and integration with the world event system.
    There is no obvious entry point for “compute damage” vs. “emit outcome events”.

  Proposed Module Boundaries & Directory Layout

  - src/domain/apply/
      - command_handler.zig: CommandHandler + helpers that touch world state (playActionCard, commitStack,
        withdraw/cancel logic).
      - event_processor.zig: EventProcessor and event-driven transitions (shuffle, cleanup, encounter
        termination).
      - validation.zig: canPlayerPlayCard, validateMeleeReach, predicate evaluation utilities,
        rulePredicatesSatisfied, and shared validation tests.
      - targeting.zig: evaluateTargets, evaluatePlayTargets, resolvePlayTargetIDs, PlayTarget struct,
        target evaluation tests.
      - effects/commit.zig: applyCommitPhaseEffect, executeCommitPhaseRules, modifier-attachment helpers.
      - effects/resolve.zig: executeResolvePhaseRules, stamina/focus recovery, tickConditions.
      - effects/manoeuvre.zig: manoeuvre cards (executeManoeuvreEffects, applyRangeModification,
        adjustRange).
      - costs.zig: applyCommittedCosts and cooldown/zone transitions.
      - A local mod.zig can re-export the public API so existing imports keep using @import("apply").
      - Move the unit tests alongside the modules they cover to keep each file self-contained.
  - src/domain/combat/
      - types.zig: enums (Reach, AdvantageAxis, CombatZone, TurnPhase, etc.) and small helper functions
        (e.g. getPlayDuration, getPlayChannels).
      - armament.zig: Armament union and category helpers.
      - agent.zig: Agent, Director, condition management, balance/stamina/focus resources.
      - encounter.zig: Encounter, Engagement, AgentPair, environment handling.
      - state.zig: CombatState, cooldown tracking, zone manipulation.
      - plays.zig: Play, modifier stack, TimeSlot, Timeline, TurnState, TurnHistory.
      - advantage.zig: AdvantageEffect, TechniqueAdvantage, helper math.
      - Tests can be scoped per file, and the existing combat.zig can shrink to a pub const re-export
        module until large callers are migrated.
  - src/domain/tick/
      - committed_action.zig: CommittedAction, TickResult data types and related tests.
      - committers.zig: commitPlayerCards, commitMobActions, plus helpers that pull data from combat.
      - resolver.zig: TickResolver.resolve, isOffensiveAction, defense lookup, and bridging to resolution.
        Target evaluation should depend on a new apply/targeting.zig API instead of the full apply.
      - Keep a small mod.zig to expose {CommittedAction, TickResolver}.
  - src/domain/resolution/
      - context.zig: AttackContext, DefenseContext, CombatModifiers.
      - advantage.zig: AdvantageEffect, TechniqueAdvantage, getAdvantageEffect, stakes scaling.
      - damage.zig: createDamagePacket, armour/body resolution.
      - outcome.zig: Outcome enum, resolveTechniqueVsDefense, applyAdvantageWithEvents.
      - height.zig: height targeting helpers and hit-location selection.
      - Each module can own its tests; resolution/mod.zig re-exports the public API.

  Refactor & Simplification Steps

  1. Surface APIs and create mod.zig files: start by moving pure helpers (targeting, validation) into new
     files and re-export them through apply/mod.zig. Update call sites gradually; this keeps the original
     filenames compiling during the migration.
  2. Split combat data-only modules: move Armament, CombatState, Play/Timeline, and Agent into separate
     files. Because they are mostly struct definitions with methods, this is a mechanical cut-and-paste
     plus updated imports, but it unlocks focused ownership (e.g. timeline logic no longer shares a file
     with agent resources).
  3. Decouple tick resolver from apply: once apply/targeting.zig exists, TickResolver.resolve can depend on
     a narrow interface (TargetResolver.evaluate) instead of all of apply. This also enables alternative
     resolvers (AI simulations) to reuse the same API without pulling UI command code.
  4. Isolate resolution pipelines: by splitting combat modifiers, advantage, and damage creation into
     modules, each step can be unit tested without event emission. resolution/outcome.zig becomes the
     single orchestrator that imports the smaller helpers.
  5. Reorganize directories: move the existing src/domain/apply.zig, combat.zig, tick.zig, resolution.zig
     into their respective subdirectories and leave apply.zig/combat.zig/etc. as thin modules that pub
     const import the new structure. This preserves external paths during the refactor and reinforces
     discoverability in src/domain/.
  6. Follow-up cleanups: after splitting, revisit each module to tighten APIs (e.g. pass lightweight
     context structs, drop duplicate event pushes, centralize logging) and to trim imports. The smaller
     files will also make it easier to extend tests (especially for predicate and timeline logic).

  Next steps: 1) carve out apply/validation.zig and apply/targeting.zig since they have minimal
  dependencies, 2) create combat/mod.zig plus combat/state.zig to house CombatState, 3) migrate
  TickResolver consumers to the new apply API, and 4) split resolution helpers into damage vs. advantage
  modules before tackling the rest of the directory reshuffle.

---

## Implementation Notes — Steps 1 & 2

### Step 1: Extract apply/validation.zig and apply/targeting.zig

Analysis of `src/domain/apply.zig` reveals clear functional boundaries. The key insight is that
**validation.zig** is a lower-level module (pure predicate evaluation, no world mutation) and
**targeting.zig** depends on it (uses `evaluatePredicate` via `expressionAppliesToTarget`).

#### apply/validation.zig — Card Playability Validation

Symbols to extract (with current line numbers in apply.zig):

| Symbol                    | Lines     | Visibility | Notes                                      |
|---------------------------|-----------|------------|--------------------------------------------|
| `ValidationError`         | 30-44     | pub        | Error set for card validation              |
| `PredicateContext`        | 1049-1054 | const      | Context for full predicate evaluation      |
| `canPlayerPlayCard`       | 768-775   | pub        | Top-level player card validation           |
| `isCardSelectionValid`    | 779-781   | pub        | Wrapper for selection-phase validation     |
| `validateCardSelection`   | 785-835   | pub        | Core validation logic                      |
| `validateMeleeReach`      | 839-864   | fn         | Melee range check                          |
| `isInPlayableSource`      | 868-897   | fn         | Checks card source (hand, pool, etc.)      |
| `wouldConflictWithInPlay` | 901-915   | fn         | Channel conflict detection                 |
| `getCardChannels`         | 918-923   | fn         | Extract channels from technique            |
| `rulePredicatesSatisfied` | 992-1001  | pub        | Rule predicate validation                  |
| `evaluateValidityPredicate`| 1004-1042| fn         | Predicate eval without full context        |
| `evaluatePredicate`       | 1056-1097 | fn         | Full predicate evaluation (for filters)    |
| `compareReach`            | 1099-1109 | fn         | Reach enum comparison                      |
| `compareF32`              | 1111-1119 | fn         | Float comparison for thresholds            |
| `canWithdrawPlay`         | 1316-1318 | pub        | Check if play can be withdrawn             |

**Dependencies**: std, cards, combat (Reach, Encounter, Engagement, CombatState), entity, world (for CardRegistry).

**Tests to move**: All tests with names containing "rulePredicatesSatisfied", "validateMeleeReach",
"compareReach", "compareF32", "canWithdrawPlay".

#### apply/targeting.zig — Target Evaluation

Symbols to extract:

| Symbol                    | Lines       | Visibility | Notes                                      |
|---------------------------|-------------|------------|--------------------------------------------|
| `PlayTarget`              | 1257-1260   | pub const  | Agent + play_index pair                    |
| `expressionAppliesToTarget`| 1123-1137  | pub        | Check if expression applies to target      |
| `cardHasValidTargets`     | 1141-1160   | pub        | Check if card has any valid targets        |
| `getTargetsForQuery`      | 1163-1190   | fn         | Get target list for a query                |
| `getEngagementBetween`    | 1192-1195   | fn         | Lookup engagement between two agents       |
| `evaluateTargets`         | 1203-1250   | pub        | Evaluate targets, returning Agent list     |
| `playMatchesPredicate`    | 1263-1290   | fn         | Check if play matches a predicate          |
| `getModifierTargetPredicate`| 1294-1313 | pub        | Extract modifier's target predicate        |
| `canModifierAttachToPlay` | 1321-1328   | pub        | Check modifier-play compatibility          |
| `resolvePlayTargetIDs`    | 1332-1358   | pub        | Resolve play target to entity IDs          |
| `evaluateTargetIDsConst`  | 1361-1397   | fn         | Const-correct target ID evaluation         |
| `evaluatePlayTargets`     | 1400-1444   | pub        | Evaluate play targets (modifier stacking)  |

**Dependencies**: std, cards, combat (Play, Encounter, Engagement, TurnState), entity, world,
**validation** (for `evaluatePredicate`, `PredicateContext`).

**Tests to move**: All tests with names containing "evaluateTargetIDsConst", "getTargetsForQuery",
"expressionAppliesToTarget", "getModifierTargetPredicate", "canModifierAttachToPlay".

### Step 2: Extract combat/state.zig

Analysis of `src/domain/combat.zig` shows `CombatState` and `CombatZone` are self-contained with
minimal dependencies on other combat types (only needs world.CardRegistry for clone operations).

#### combat/state.zig — Combat Zone State Management

Symbols to extract (with current line numbers in combat.zig):

| Symbol       | Lines     | Visibility | Notes                                      |
|--------------|-----------|------------|--------------------------------------------|
| `CombatZone` | 137-143   | pub        | Zone enum (draw, hand, in_play, etc.)      |
| `CombatState`| 147-348   | pub        | Card zone management, cooldowns            |

**Nested types within CombatState**:
- `ZoneError` (L160)
- `CardSource` (L161)
- `InPlayInfo` (L164-169)

**CombatState methods**:
- `init`, `deinit`, `clear`
- `zoneList`, `isInZone`, `findIndex`, `moveCard`
- `shuffleDraw`, `populateFromDeckCards`
- `addToInPlayFrom`, `isPoolCardAvailable`, `tickCooldowns`
- `removeFromInPlay`, `setCooldown`

**Dependencies**: std, entity, world (CardRegistry), Agent (for `isPoolCardAvailable`).

**Dependency concern**: `CombatState.isPoolCardAvailable` takes `*const Agent` — may need to move
to Agent or pass a narrower interface. For now, keep as-is and accept the circular reference via
combat/mod.zig re-exports.

**Tests to move**: All tests containing "CombatState", "addToInPlayFrom", "removeFromInPlay",
"isPoolCardAvailable", "tickCooldowns", "pool card" (cooldown tests).

### Migration Strategy

1. **Create directories**: `src/domain/apply/`, `src/domain/combat/`

2. **Extract in dependency order**:
   - `combat/state.zig` first (no domain dependencies beyond entity/world)
   - `apply/validation.zig` second (depends on combat types)
   - `apply/targeting.zig` third (depends on validation)

3. **Create mod.zig files** that re-export public symbols, allowing existing imports to work:
   ```zig
   // src/domain/apply/mod.zig
   pub const validation = @import("validation.zig");
   pub const targeting = @import("targeting.zig");
   // Re-export commonly used symbols at top level for gradual migration
   pub const ValidationError = validation.ValidationError;
   pub const canPlayerPlayCard = validation.canPlayerPlayCard;
   // ...
   ```

4. **Update original files** to re-export from new locations:
   ```zig
   // src/domain/apply.zig (after extraction)
   const apply_mod = @import("apply/mod.zig");
   pub const ValidationError = apply_mod.ValidationError;
   // ... remaining CommandHandler, EventProcessor, effects code stays here
   ```

5. **Verify build** after each extraction before proceeding.

### Resolved Design Decisions

- **`evaluatePredicate` visibility**: Make pub in validation.zig. targeting.zig imports it.
- **`isPoolCardAvailable` refactor**: Move from CombatState to Agent. The method semantically
  asks "is this pool card available to me?" which belongs on Agent. Agent already has
  `combat_state` so it can check both its pools and cooldowns. Single call site in apply.zig:411.

### Progress Tracking

- [x] Create `src/domain/apply/` directory
- [x] Create `src/domain/combat/` directory
- [x] Extract `combat/state.zig` with `CombatZone`, `CombatState`
- [x] Create `combat/mod.zig`
- [x] Update `combat.zig` to re-export from `combat/mod.zig`
- [x] Extract `apply/validation.zig`
- [x] Extract `apply/targeting.zig`
- [x] Create `apply/mod.zig`
- [x] Update `apply.zig` to re-export from `apply/mod.zig`
- [x] Run tests, verify build
- [x] Create `src/domain/tick/` directory
- [x] Extract `tick/committed_action.zig` with CommittedAction, ResolutionEntry, TickResult
- [x] Extract `tick/resolver.zig` with TickResolver (depends on apply/targeting, not full apply)
- [x] Create `tick/mod.zig`
- [x] Update `tick.zig` to re-export from `tick/mod.zig`
- [x] Create `src/domain/resolution/` directory
- [x] Extract `resolution/context.zig` with AttackContext, DefenseContext, CombatModifiers, overlay
- [x] Extract `resolution/advantage.zig` with AdvantageEffect, getAdvantageEffect, defaults
- [x] Extract `resolution/damage.zig` with createDamagePacket, getWeaponOffensive
- [x] Extract `resolution/height.zig` with hit location selection
- [x] Extract `resolution/outcome.zig` with Outcome, resolveTechniqueVsDefense orchestrator
- [x] Create `resolution/mod.zig`
- [x] Update `resolution.zig` to re-export from submodules

### Completed (2026-01-06)

Steps 1 & 2 of the decomposition are complete:

**New files created:**
- `src/domain/apply/validation.zig` - Card playability validation
- `src/domain/apply/targeting.zig` - Target evaluation
- `src/domain/apply/mod.zig` - Apply module re-exports
- `src/domain/combat/state.zig` - CombatState and CombatZone
- `src/domain/combat/mod.zig` - Combat module re-exports

**Key changes:**
- `isPoolCardAvailable` moved from `CombatState` to `Agent` (cleaner ownership)
- `combat.zig` and `apply.zig` now re-export from their respective submodules
- All existing imports continue to work (backward compatible)
- Build and tests pass

---

### Step 3 Completed (2026-01-06)

Decoupled tick resolver from full apply module:

**New files created:**
- `src/domain/tick/committed_action.zig` - CommittedAction, ResolutionEntry, TickResult data types
- `src/domain/tick/resolver.zig` - TickResolver with narrow dependency on apply/targeting
- `src/domain/tick/mod.zig` - Tick module re-exports

**Key changes:**
- `TickResolver` now imports `apply/targeting.zig` directly instead of full `apply.zig`
- Data types (CommittedAction, ResolutionEntry, TickResult) extracted to separate file
- `tick.zig` is now a thin re-export module
- All existing imports continue to work (backward compatible)
- Build and tests pass

---

### Step 4 Completed (2026-01-06)

Isolated resolution pipelines into focused modules:

**New files created:**
- `src/domain/resolution/context.zig` - AttackContext, DefenseContext, CombatModifiers, overlay bonuses
- `src/domain/resolution/advantage.zig` - AdvantageEffect, getAdvantageEffect, default effects, applyAdvantageWithEvents
- `src/domain/resolution/damage.zig` - createDamagePacket, getWeaponOffensive
- `src/domain/resolution/height.zig` - Hit location selection (height weights, selectHitLocation)
- `src/domain/resolution/outcome.zig` - Outcome enum, calculateHitChance, resolveOutcome, resolveTechniqueVsDefense
- `src/domain/resolution/mod.zig` - Resolution module re-exports

**Module structure:**
```
resolution/
├── context.zig    # Attack/defense contexts, combat modifiers
├── advantage.zig  # Advantage effects and scaling
├── damage.zig     # Damage packet creation
├── height.zig     # Hit location selection
├── outcome.zig    # Orchestrator (imports all above)
└── mod.zig        # Re-exports public API
```

**Key changes:**
- Each resolution step can now be unit tested independently
- `outcome.zig` is the single orchestrator that imports smaller helpers
- `resolution.zig` is now a thin re-export module
- All existing imports continue to work (backward compatible)
- Build and tests pass

---

### Step 2 Continued: Combat Module Decomposition (2026-01-06, COMPLETED)

Extracted remaining combat types into focused modules:

**New files created:**
- `src/domain/combat/types.zig` - Director, Reach, AdvantageAxis, DrawStyle, CombatOutcome, TurnPhase, TurnEvent, TurnFSM
- `src/domain/combat/armament.zig` - Armament union with hasCategory, getOffensiveMode
- `src/domain/combat/advantage.zig` - AdvantageEffect (with apply method), TechniqueAdvantage
- `src/domain/combat/plays.zig` - Play, TimeSlot, Timeline, TurnState, TurnHistory, AgentEncounterState, getPlayDuration, getPlayChannels
- `src/domain/combat/engagement.zig` - Engagement, AgentPair
- `src/domain/combat/agent.zig` - Agent, ConditionIterator
- `src/domain/combat/encounter.zig` - Encounter

**Updated:**
- `src/domain/combat/mod.zig` - Re-exports all submodules
- `src/domain/combat.zig` - Now a thin re-export from combat/mod.zig

**Module structure:**
```
combat/
├── types.zig       # Enums and FSM
├── state.zig       # CombatState, CombatZone (from step 2 earlier)
├── armament.zig    # Weapon configuration
├── advantage.zig   # Advantage effects
├── plays.zig       # Play, Timeline, TurnState
├── engagement.zig  # Engagement, AgentPair
├── agent.zig       # Agent, ConditionIterator
├── encounter.zig   # Encounter
└── mod.zig         # Re-exports
```

**Test fixes applied:**
- Fixed incorrect API usage: `card_list.getTemplate(.swing)` → `card_list.byName("slash")`
- Fixed incorrect API usage: `registry.register()` → `registry.create().id`
- Fixed ChannelSet initialization: `var x = ChannelSet{}; x.set(.movement)` → `const x: ChannelSet = .{ .footwork = true }`
- Fixed memory leak in agent.zig tests: `makeTestAgent` now returns `TestAgent` struct with proper cleanup
- Fixed Timeline tests: now use actual registered cards instead of `testId()` for proper duration calculations
- Fixed agent.zig test issues: `mobility_weight` → `can_stand`, `.turns` → `.ticks`

**Build and tests pass.**

---

### Step 5: Apply Module Decomposition (2026-01-06, COMPLETED)

Extracted remaining apply.zig code into focused modules:

**New files created:**
- `src/domain/apply/command_handler.zig` - CommandHandler, CommandError, playValidCardReservingCosts, channel helpers
- `src/domain/apply/event_processor.zig` - EventProcessor, game state transitions, combat lifecycle
- `src/domain/apply/costs.zig` - applyCommittedCosts, post-resolution card zone management
- `src/domain/apply/effects/commit.zig` - applyCommitPhaseEffect, executeCommitPhaseRules
- `src/domain/apply/effects/resolve.zig` - executeResolvePhaseRules, applyResolveEffect, tickConditions
- `src/domain/apply/effects/manoeuvre.zig` - executeManoeuvreEffects, applyRangeModification, adjustRange

**Updated:**
- `src/domain/apply/mod.zig` - Re-exports all submodules and commonly used symbols
- `src/domain/apply.zig` - Now a thin re-export module (tests remain here for compatibility)

**Module structure:**
```
apply/
├── validation.zig      # Card playability (from step 1)
├── targeting.zig       # Target evaluation (from step 1)
├── command_handler.zig # CommandHandler
├── event_processor.zig # EventProcessor
├── costs.zig           # Cost application
├── effects/
│   ├── commit.zig      # Commit phase effects
│   ├── resolve.zig     # Resolve phase effects
│   └── manoeuvre.zig   # Manoeuvre effects
└── mod.zig             # Re-exports
```

**Key changes:**
- `apply.zig` reduced from ~1500 lines to ~270 lines (thin re-exports + tests)
- Dead code removed: `EffectContext`, `TechniqueContext`, `DEFAULT_COOLDOWN_TICKS`
- Effect modules now have focused responsibilities
- EventProcessor imports `effects/commit.executeCommitPhaseRules` instead of full apply
- All existing imports continue to work (backward compatible)
- Build and tests pass

**All four main domain files are now thin re-exports:**
- `apply.zig` → `apply/mod.zig`
- `combat.zig` → `combat/mod.zig`
- `tick.zig` → `tick/mod.zig`
- `resolution.zig` → `resolution/mod.zig`