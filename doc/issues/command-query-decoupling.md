# Command-Query Decoupling

## Context: Current Architecture (Research Findings)

### Command Path Coupling

**Single coupling point:** `src/domain/apply/command_handler.zig` imports `lib.Command` (from infra):

```zig
const lib = @import("infra");
// ...
pub fn handle(self: *CommandHandler, cmd: lib.Command) !void {
    switch (cmd) {
        .start_game => { ... },
        .play_card => |data| { ... },
        .cancel_card => |id| { ... },
        // etc.
    }
}
```

**Dependency chain:**
```
presentation/coordinator.zig -> lib.Command -> CommandHandler.handle(lib.Command) -> domain/*
```

CommandHandler is the ONLY domain module that imports the UI-shaped Command union. Pure domain functions
(validation.zig, targeting.zig, costs.zig) are already cleanly separated.

### Query Path Coupling

**Single file:** Only `src/presentation/views/combat/view.zig` calls `apply.*` functions.

**Four functions called:**

| Function                    | Location          | Line | Purpose                          |
|-----------------------------|-------------------|------|----------------------------------|
| `validateCardSelection`     | `buildCardList`   | 363  | Card playability for rendering   |
| `validateCardSelection`     | `isCardDraggable` | 508  | Drag eligibility check           |
| `canModifierAttachToPlay`   | `handleDragging`  | 463  | Predicate validation on drag     |
| `resolvePlayTargetIDs`      | `buildPlayViewData` | 311 | Target display for plays        |

All are **read-only validation queries**, never mutations.

### Key Files

```
src/commands.zig                          # Defines lib.Command union
src/domain/apply/command_handler.zig      # ⭐ ONLY domain file using lib.Command
src/domain/apply/validation.zig           # validateCardSelection, rulePredicatesSatisfied
src/domain/apply/targeting.zig            # resolvePlayTargetIDs, canModifierAttachToPlay
src/presentation/views/combat/view.zig    # ⭐ ONLY presentation file calling apply.*
src/presentation/coordinator.zig          # Dispatches commands to handler
```

### Function Signatures (Query Path)

```zig
// validation.zig
pub fn validateCardSelection(
    actor: *const Agent,
    card: *const Instance,
    phase: combat.TurnPhase,
    encounter: ?*const combat.Encounter,
) !bool

// targeting.zig
pub fn canModifierAttachToPlay(
    template: *const cards.Template,
    play: *const combat.Play,
    world: *const World,
) !bool

pub fn resolvePlayTargetIDs(
    alloc: std.mem.Allocator,
    play: *const combat.Play,
    actor: *const Agent,
    world: *const World,
) !?[]const entity.ID
```

---

## 1. Command Path Refactor

Goal: break the presentation -> infra.commands -> domain.apply.CommandHandler dependency so the domain
never sees UI‑shaped commands.

Implementation plan:

1. Introduce an "application" layer module (e.g. src/app/game_service.zig). This module owns the current
   CommandHandler logic because it is inherently "application orchestration" (translating UI intents into
   domain operations).
    - Move the existing CommandHandler struct out of src/domain/apply.zig into the new module unchanged.
    - Rename it to GameService (or similar) and keep lib.Command as its public input.

2. Define a thin domain API that the application layer calls. In src/domain/world_api.zig (or
   world/service.zig), expose explicit methods such as:

   ```zig
   pub const PlayCardRequest = struct { card_id: entity.ID, target: ?entity.ID };
   pub fn playCard(world: *World, req: PlayCardRequest) !PlayCardResult;
   pub fn cancelCard(world: *World, card_id: entity.ID) !void;
   pub fn advanceTurnPhase(world: *World, target: TurnPhase) !void;
   ```

   These functions wrap the logic currently inside CommandHandler.playActionCard, cancelActionCard, etc.,
   but they live in the domain tree and never mention lib.Command.

3. Update the coordinator to hold a handle to GameService instead of CommandHandler. Input handling stays
   the same (views return Command), but Coordinator now simply calls service.handle(cmd); GameService
   translates to domain API calls.

4. Gradually delete lib.Command usages from the domain:
    - After lifting all logic out, src/domain/apply.zig only re-exports domain rules and no longer imports lib.
    - Domain modules now exclusively expose rule-level functions (playCard, validateCardSelection, etc.).
      The application layer is the only place that depends on infra.commands.

5. Testing: move or add tests for GameService into src/app/tests to ensure command translation still works.
   Domain tests target the new API functions directly.

Result: presentation depends on infra.commands + application layer; application layer depends on domain;
domain never sees UI concepts.

---

## 2. Query Path & UI-Friendly Snapshots

Goal: stop views from calling apply.* directly each frame by providing a read-only cache of expensive
combat queries.

### Strategy: Rebuild on Demand

The simplest approach: rebuild the snapshot once per tick (not per frame). Views cache the snapshot for
the duration of the frame. No dirty flags needed.

### Implementation Plan

1. **Create `src/domain/query/combat_snapshot.zig`** with immutable structs:

   ```zig
   pub const CardStatus = struct {
       card_id: entity.ID,
       playable: bool,
       // reason: ?ValidationError, // optional: why not playable
   };

   pub const PlayStatus = struct {
       play_index: usize,
       owner_id: entity.ID,
       target_id: ?entity.ID, // resolved target for offensive plays
       // modifier slots info if needed
   };

   pub const CombatSnapshot = struct {
       card_statuses: std.AutoHashMap(entity.ID, CardStatus),
       play_statuses: []PlayStatus,
       allocator: std.mem.Allocator,

       pub fn isCardPlayable(self: *const CombatSnapshot, card_id: entity.ID) bool;
       pub fn playTarget(self: *const CombatSnapshot, play_index: usize) ?entity.ID;
       pub fn deinit(self: *CombatSnapshot) void;
   };

   pub fn buildSnapshot(alloc: std.mem.Allocator, world: *const World) !CombatSnapshot;
   ```

2. **Snapshot building internally uses existing apply functions:**
   - Calls `validation.validateCardSelection` for each card
   - Calls `targeting.resolvePlayTargetIDs` for each play
   - Results stored in maps/arrays for O(1) lookup

3. **Attach to World (optional) or build in Coordinator:**
   - Option A: `world.combat_snapshot: ?*CombatSnapshot` — rebuilt per tick
   - Option B: Coordinator builds snapshot, passes to view render — keeps World pure

4. **Update CombatView to consume snapshot:**
   - Replace `apply.validateCardSelection(...)` → `snapshot.isCardPlayable(card_id)`
   - Replace `apply.resolvePlayTargetIDs(...)` → `snapshot.playTarget(play_index)`
   - Replace `apply.canModifierAttachToPlay(...)` → `snapshot.canAttachModifier(mod, play)`

5. **Remove apply.* imports from presentation:**
   - After migration, `views/combat/view.zig` no longer imports domain/apply.zig
   - All queries go through the snapshot interface

### Modifier Attachment During Drag

The `canModifierAttachToPlay` call happens during drag interaction (per mouse-motion event). Two options:

A. **Pre-compute in snapshot:** For each modifier in hand, cache which plays it can attach to.
   Snapshot stores `modifier_attachability: std.AutoHashMap(struct{mod_id, play_idx}, bool)`.

B. **Keep as fallback:** For transient drag validation, allow a direct domain call. This is acceptable
   because it only runs during active drag (not per-frame for all cards).

Option B is simpler; if perf becomes an issue, upgrade to A.

---

## 3. Integration Checklist

### Command Path (deferred)
- [ ] Add src/app/game_service.zig with the moved CommandHandler logic.
- [ ] Define domain API wrappers for play/cancel/commit actions.
- [ ] Update Coordinator to use GameService.

### Query Path (COMPLETE)
- [x] Create `src/domain/query/combat_snapshot.zig` with CardStatus, PlayStatus, CombatSnapshot.
- [x] Implement `buildSnapshot()` using existing apply/* validation/targeting functions.
- [x] Decide snapshot ownership: Coordinator-managed.
- [x] Update `views/combat/view.zig`:
  - [x] `buildCardList()` → uses `self.isCardPlayable(id)` helper
  - [x] `isCardDraggable()` → uses `self.isCardPlayable(id)` helper
  - [x] `buildPlayViewData()` → uses `self.resolvePlayTarget()` helper
  - [x] `handleDragging()` → uses `snapshot.canModifierAttachToPlay()`
- [x] Added `snapshot` field to View, `initWithSnapshot()` constructor
- [x] Coordinator builds snapshot in `render()` for combat view
- [x] Pre-computed modifier attachability in snapshot
- [x] Removed `apply` import from `view.zig`
- [x] Build passes, tests pass

---

With these pieces, the domain regains UI ignorance, and the presentation layer gets a stable, cacheable
interface for both commands (through the application service) and queries (through combat snapshots).

## Related

- [Presentation-Domain Decoupling](presentation-domain-decoupling.md) - Expanding query layer to eliminate all domain type dependencies from presentation
