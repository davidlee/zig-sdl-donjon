  1. Command Path Refactor

  Goal: break the presentation -> infra.commands -> domain.apply.CommandHandler dependency so the domain never sees UI‑shaped commands.

  Implementation plan:

  1. Introduce an “application” layer module (e.g. src/app/game_service.zig). This module owns the current CommandHandler logic because it is inherently “application
     orchestration” (translating UI intents into domain operations).
      - Move the existing CommandHandler struct out of src/domain/apply.zig into the new module unchanged.
      - Rename it to GameService (or similar) and keep lib.Command as its public input.
  2. Define a thin domain API that the application layer calls. In src/domain/world_api.zig (or world/service.zig), expose explicit methods such as:

     pub const PlayCardRequest = struct { card_id: entity.ID, target: ?entity.ID };
     pub fn playCard(world: *World, req: PlayCardRequest) !PlayCardResult;
     pub fn cancelCard(world: *World, card_id: entity.ID) !void;
     pub fn advanceTurnPhase(world: *World, target: TurnPhase) !void;

     These functions wrap the logic currently inside CommandHandler.playActionCard, cancelActionCard, etc., but they live in the domain tree and never mention lib.Command.
  3. Update the coordinator to hold a handle to GameService instead of CommandHandler. Input handling stays the same (views return Command), but Coordinator now simply calls
     service.handle(cmd); GameService translates to domain API calls.
  4. Gradually delete lib.Command usages from the domain:
      - After lifting all logic out, src/domain/apply.zig only re-exports domain rules and no longer imports lib.
      - Domain modules now exclusively expose rule-level functions (playCard, validateCardSelection, etc.). The application layer is the only place that depends on infra.commands.
  5. Testing: move or add tests for GameService into src/app/tests to ensure command translation still works. Domain tests target the new API functions directly.

  Result: presentation depends on infra.commands + application layer; application layer depends on domain; domain never sees UI concepts.

  ———

  2. Query Path & UI-Friendly Snapshots

  Goal: stop views from calling apply.* directly each frame by providing a read-only cache of expensive combat queries.

  Implementation plan:

  1. Create src/domain/query/combat.zig (or domain/reporting/combat.zig) that exposes immutable structs describing the current combat UI state. Core types:
      - CardStatus (card_id, zone, playable, reason, cost, requires_target, target_ids[])
      - PlayStatus (play_index, modifier_slots, attachable_modifier_predicates)
      - TargetArc data (source card, resolved targets)
  2. Attach a cache to the world: extend World with an optional combat_cache: ?CombatSnapshot. Provide methods:

     pub fn rebuildCombatSnapshot(world: *World, alloc: std.mem.Allocator) !void;
     pub fn combatSnapshot(world: *const World) ?*const CombatSnapshot;

     CombatSnapshot stores the arrays above plus timestamps/dirty flags.
  3. Dirty-flagging strategy: hook into existing domain points that mutate combat state (card movement, targeting, engagement changes) and mark the cache dirty.
      - After playCard, cancel, commitStack, executeManoeuvreEffects, applyCommittedCosts, etc., set world.combat_cache_dirty = true.
      - When the coordinator or application layer asks for the snapshot, rebuild only if dirty. Rebuild reuses the existing validation/targeting modules but runs once per tick, not per
        frame.
  4. Snapshot building:
      - Use apply/validation.canPlayerPlayCard, apply/targeting.resolvePlayTargetIDs, etc., internally. Their results are stored in arrays inside the snapshot.
      - Include helper maps (std.AutoHashMap(entity.ID, CardStatus)) so views can look up by card ID in O(1).
      - Provide convenience getters (e.g. snapshot.cardStatus(card_id)) so the UI doesn’t need to know about the underlying maps.
  5. Presentation consumption:
      - Update views/combat/view.zig to request the snapshot via world.combatSnapshot(). Replace every direct apply.* call with a lookup into the snapshot data.
      - For transient drag validation, reuse the cached modifier predicates and only revalidate if the card actually changes (can still fall back to domain call if data missing, but that
        should be rare).
  6. Optional incremental caching: if rebuilding everything every time is still cheap enough, step 3 can be simplified by rebuilding on demand each frame but caching results in World so the
     UI always uses the same data structure (even if regenerated frequently). The important part is that the UI doesn’t know about apply.*.

  Result: UI reads a dedicated, domain-provided snapshot; domain decides when/how to compute expensive validations; presentation is decoupled from rule helpers.

  ———

  3. Integration Checklist

  - [ ] Add src/app/game_service.zig with the moved CommandHandler logic.
  - [ ] Define domain API wrappers for play/cancel/commit actions.
  - [ ] Update Coordinator to use GameService.
  - [ ] Create src/domain/query/combat.zig and World cache fields.
  - [ ] Emit dirty flags from domain mutations.
  - [ ] Update combat views to consume snapshots instead of apply.*.
  - [ ] Remove now-unused UI helpers from apply.zig (they live in query/combat instead).

  With these pieces, the domain regains UI ignorance, and the presentation layer gets a stable, cacheable interface for both commands (through the application service) and queries (through
  combat snapshots).