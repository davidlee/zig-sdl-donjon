- src/domain/apply.zig:136-169 couples the core command-processing loop directly to lib.Command, which is defined for the presentation layer (it even includes UI-only actions such
    as .open_inventory, .close_overlay, .select_target, etc.). The domain handler now has to understand every UI verb, log “UNHANDLED COMMAND” for view-only controls, and will keep growing
    whenever the UI adds a new interaction. A thinner application/service layer should translate UI intents into domain operations (e.g., world.playCard, world.openInventory) so the domain
    remains unaware of control schemes.
  - Several helpers inside apply.zig are explicitly documented as UI utilities:
      - canPlayerPlayCard (src/domain/apply.zig:778-787) is “for UI validation (greying out unplayable cards)”.
      - resolvePlayTargetIDs / evaluateTargetIDsConst (src/domain/apply.zig:1342-1408) exist “for UI display”.
      - playValidCardReservingCosts reserves stamina/time “for the UI to display” (src/domain/apply.zig:982-993).
        These routines mix rendering concerns with authoritative game rules. They’d be healthier as presentation adapters that call pure domain predicates (validateCardSelection,
        applyCommittedCosts) rather than living inside the domain module itself.
  - evaluatePlayTargets and related predicate helpers (src/domain/apply.zig:1412-1506) are used solely to drive commit-phase UI interactions (building play lists, attaching modifiers).
    Keeping them in the domain means resolving view-level constructs like “play indices” and selection states. Moving them into a presentation-side “combat UI model” (fed by domain state
    snapshots) would keep domain logic focused on agents, cards, and rules.
  - EventProcessor.dispatchEvent contains presentation knowledge—e.g. when transitioning to .encounter_summary it comments “handled by summary view” (src/domain/apply.zig:668-681). That
    indicates the domain event loop is aware of which screen will consume the transition rather than simply mutating state and emitting semantic events.
  - The shared event union (src/domain/events.zig:150-161) defines play_sound (and similar presentation-specific variants) inside the domain package. Even though no code currently emits
    them, the domain layer is formally promising to trigger sound cues for the UI. Domain events should describe game outcomes (“technique_resolved”, “range_changed”) and let the
    presentation map those onto audio/visual effects; sound playback shouldn’t be encoded as a domain event type.

  Overall, apply.zig mixes core rule enforcement with helpers that only exist to drive UI affordances and relies on a UI-shaped Command contract. Extracting a thin “application/controller”
  layer outside src/domain—one that translates UI commands into domain method calls and derives UI-only data (target IDs, validation flags, etc.)—would let the domain stay ignorant of the
  presentation while still exposing the information the UI needs.


› **Problem:** combat/view.zig calls `apply.*` validation functions directly:
  - `apply.validateCardSelection()` - card playability
  - `apply.canModifierAttachToPlay()` - drag validation
  - `apply.resolvePlayTargetIDs()` - targeting arrows

  also notable: views are disposed & recreated each frame (no persistent state), hence card validations - some of which must iterate each card x each engagement - must be called at least
  once every frame.

  this is the other side of the equation; we need to find an appropriate interface or mechanism for views to query (or retrieve precomputed) information from the domain.


• combat/view.zig is tightly coupled to apply.zig because the UI keeps pulling three different checks every frame: “can I play this card?”, “can I drag this modifier onto that play?”, and
  “who would this attack target?”. Doing those checks in the render path has two major issues: (1) the view depends on the entire apply module and therefore on internal rule logic, and (2)
  the work scales with cards × engagements × frames, which is why you’re calling predicate-heavy code dozens of times per second.

  To break this, the domain should expose a read‑only snapshot that already contains the validation results the UI needs. A pragmatic approach:

  1. Introduce a CombatQuery service (domain-side): when the world advances state (card added, engagement changed, phase switch, etc.), build a CombatQuery struct (or small cache) that
     holds:
      - for each play candidate: can_play, failure_reason (from validateCardSelection).
      - for each play in the timeline: allowed modifier predicates (so the UI just checks a tag flag) and modifier_attachable[target_play_index].
      - the resolved target IDs for each offensive play (per card instance) plus a “requires manual target” flag for .single.
        This cache can live on the World/Encounter or on a dedicated domain subsystem that the application layer updates whenever relevant state mutates (after
        CommandHandler.playActionCard, commit transitions, range shifts, etc.).
  2. Expose that snapshot through a narrow API: e.g. domain.combat_query.read(world) returns immutable data (arrays keyed by card ID / play index). The UI only talks to the query layer, not
     to apply.*. The query layer hides the expensive predicate evaluation behind an incremental update (only recompute the subset that changed) so you don’t pay per-frame costs.
  3. Move UI-specific helpers out of apply: canPlayerPlayCard, resolvePlayTargetIDs, evaluatePlayTargets become methods on CombatQuery or the new CombatViewModel the application layer
     maintains. They still reuse the same predicate logic internally, but presentation files import combat/query.zig rather than apply.zig.
  4. Let the application layer drive refreshes: since views are recreated every frame, the coordinator (presentation/coordinator.zig) can ask the domain for the latest query snapshot once
     per tick or whenever the event stream indicates relevant changes (e.g. card_moved, range_changed, advantage_changed). That reduces redundant computation and ensures the UI consumes
     consistent state.

  If a full cache feels heavy, a lighter interface would be to add domain-side read methods such as world.canPlayCard(card_id), world.getModifierTargets(play_id),
  world.resolveTargetsForPlay(play_id) that consult internal state but are pure/read-only. The key is to keep these methods on a dedicated “query” module (separate from apply) so the UI
  imports domain/queries instead of the rule-enforcement code.

  Either way, the view should stop calling apply.* directly. Adding a query boundary makes the domain API deliberate, allows caching/dirty flags, and preserves UI independence. Natural next
  steps:

  1. Create src/domain/combat/query.zig exposing the read-only data you need.
  2. Update the coordinator/view to pull from that query layer once per frame, replacing direct apply.* calls.
  3. Remove the UI-annotated helpers from apply.zig after the new API lands, reinforcing the separation.