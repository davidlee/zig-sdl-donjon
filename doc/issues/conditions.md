• Condition Pipeline Snapshot

  - Stored conditions live on the agent (conditions: ArrayList(damage.ActiveCondition)), are appended by resolve-phase effects, and
    ticked/expired by tickConditions (src/domain/combat/agent.zig:65-70, src/domain/apply/effects/resolve.zig:52-154).
    ActiveCondition currently carries only an enum and expiration tag (src/domain/damage.zig:46-56).
  - Computed conditions are synthesized on demand via ConditionIterator, which yields stored entries first and then a fixed set of
    thresholds for balance, blood ratio, sensory loss, and two engagement stats when an Engagement pointer is supplied (src/domain/
    combat/agent.zig:298-372). activeConditions(engagement) is the only public accessor (src/domain/combat/agent.zig:235-239).
  - Condition events are emitted immediately for stored add/remove and once per tick for “dynamic” entries by diffing iterator
    output before/after agent.tick, but that diff is done with engagement = null, so relational states (pressured, weapon_bound,
    etc.) never trigger events (src/domain/apply/event_processor.zig:95-152, src/domain/apply/event_processor.zig:329-355).
  - Card predicates and validation pass only consult hasCondition, which explicitly ignores computed states (src/domain/combat/
    agent.zig:241-248), so rules can’t key off pressure/blood-loss states even though Predicate.has_condition exists (src/domain/
    cards.zig:141-159).

  Key Pain Points

  - Hard-coded, incomplete computed set. The iterator’s phase switch doesn’t cover everything declared in damage.Condition (e.g.,
    flanked, surrounded, stationary), and expanding it requires editing this monolithic switch plus bumping the u4 computed_phase
    limit (src/domain/combat/agent.zig:298-372, src/domain/damage.zig:58-143). Planned pain/trauma/adrenaline phases would quickly
    outgrow the current structure.
  - Events miss relational states and mid-turn changes. Because computedConditions is only called with engagement = null at end-of-
    turn, you never emit condition_applied/expired for engagement-dependent states or for intra-turn transitions such as blood
    thresholds crossed during resolution (src/domain/apply/event_processor.zig:95-152). Combat log/UI therefore lack visibility
    into the most interesting dynamic states.
  - Predicate blind spot. Agent.hasCondition only checks stored entries, so card predicates or UI panels can’t reason about
    computed states without rerunning the iterator themselves and guessing the correct engagement context (src/domain/combat/
    agent.zig:235-248). This blocks designs like “play only when target is pressured.”
  - No metadata payload. ActiveCondition has no room for intensity/stack count/doT magnitude/state-machine progress, even though
    damage.DoTEffect hints at richer effects (src/domain/damage.zig:212-225). That makes DoTs, staged condition sequences, or per-
    condition data (e.g., which enemy applied it) impossible without bespoke tables elsewhere.
  - Condition diff caps and duplication. The ConditionSet used for diffing is a fixed [8] buffer, so once pain/trauma/adrenaline
    conditions come online you’ll silently drop entries, and CombatModifiers recomputes modifiers twice per roll (once in
    calculateHitChance, again in resolveOutcome for logging), iterating the iterator repeatedly (src/domain/apply/
    event_processor.zig:329-355, src/domain/resolution/outcome.zig:88-130,157-180).

  Design Directions

  1. Introduce condition definitions & categories. Create a declarative table (ConditionDefinition) describing each condition’s
     category (internal vs relational), computation hook (resource ratio, engagement stat, timeline query), optional thresholds,
     and penalty metadata. ConditionIterator can then loop over this table instead of hard-coded switch cases, while
     ConditionDefinition can flag which ones need an engagement or broader encounter context.
  2. Unify querying and predicates. Extend Agent.hasCondition (or add hasCondition(condition, engagement_opt)) to consult the
     iterator so predicates, UI, and AI can reason about computed states. Provide convenience wrappers for common contexts (self,
     per-engagement) so callers don’t repeat the iterator pattern.
  3. Track computed-state transitions per context. Cache the last ConditionSet per agent plus per engagement (e.g., ConditionCache
     { internal: bitset, relational: HashMap(engagement_id -> bitset) }). Update the caches whenever the underlying metric changes
     (blood damage, engagement.pressure/control updates, positioning contests) rather than only at end-of-turn; emit
     condition_applied/expired events for whichever set changed so the combat log/UI stay in sync.
  4. Add metadata/payload support. Replace ActiveCondition with something like:

     pub const ConditionState = struct {
         condition: Condition,
         expiration: Expiration,
         payload: ConditionPayload = .none,
         source: ?entity.ID = null,
     };

     pub const ConditionPayload = union(enum) {
         none,
         dot: struct { damage: damage.Kind, amount: f32 },
         fsm: struct { stage: u8, progress: f32 },
         stacks: u8,
     };

     This lets DoTs, adrenaline sequences, or “condition-as-state-machine” features live in one place and be serialized/events-
     loggable. Effects like add_condition would fill payloads; computed entries could set progress metadata (e.g., blood ratio).
  5. Differentiate internal vs relational pipelines. Provide two iterators or a richer context struct:

     pub const ConditionContext = struct {
         engagement: ?*const Engagement = null,
         encounter: ?*const Encounter = null,
         observer: ?*const Agent = null, // for “player vs opponent”
     };

     Conditions could declare whether they need per-engagement data, global encounter data (flanked/surrounded), or neither. This
     avoids misusing null engagements and makes it feasible to iterate “all engagement-specific conditions” when rendering multi-
     target info.
  6. Support richer effect lifecycles. Use the definition table to declare on-gain/on-expire hooks (e.g., emit DoT tick events,
     inject dud cards) with a clean FSM-style pipeline. For example, adrenaline could be defined as a staged condition with
     next_stage metadata rather than hand-written event-processor code.
  7. Strengthen tooling. Replace the fixed-size ConditionSet diff with either a dynamic bitset
     (std.StaticBitSet(@typeInfo(Condition).enum_fields)) or u64 bitmask so you can trivially diff/emit events even as the enum
     grows. Cache CombatModifiers outputs per roll to avoid re-iterating the same set twice and to keep logging in sync with actual
     calculations.

  Natural Next Steps

  1. Prototype a ConditionDefinition table and update ConditionIterator to drive off it (likely in a dedicated module so combat/
     agent stays lean).
  2. Implement a condition cache that tracks dynamic + relational states and fires condition_applied/expired whenever caches change
     (hook into engagement updates, Agent.tick, and damage application).
  3. Extend ActiveCondition to carry payload metadata and update add_condition/tickConditions/log formatting accordingly.

  These steps will make computed conditions first-class citizens—with events, predicates, and UI visibility—while giving plenty of
  room for DoTs, staged states, and other rich mechanics.