Design Analysis: Passing Flanking to CombatModifiers

  Current Callers of activeConditions

  1. context.zig:63 - CombatModifiers.forAttacker(attack) → attack.attacker.activeConditions(attack.engagement)
  2. context.zig:120 - CombatModifiers.forDefender(defense) → defense.defender.activeConditions(defense.engagement)
  3. agent.zig:208 - Agent.isIncapacitated() → self.activeConditions(null)

  None of these currently have access to Encounter.

  ---
  Option A: Add flanking param to ConditionIterator (task card approach)

  pub fn activeConditions(self, engagement, flanking: FlankingStatus) ConditionIterator

  Pros:
  - Flanking yields as a condition like pressured/weapon_bound
  - Consistent with existing computed condition pattern
  - Card predicates could check .flanked condition

  Cons:
  - API churn: 3 call sites need updating
  - AttackContext and DefenseContext need flanking field added
  - Resolver computes flanking, passes to context, context passes to activeConditions
  - Caller must remember to compute and pass - easy to forget
  - Conceptual mismatch: ConditionIterator operates on agent+engagement, but flanking is agent+encounter

  ---
  Option B: Pass Encounter to ConditionIterator

  pub fn init(agent, engagement, encounter: ?*const Encounter) ConditionIterator

  Pros:
  - Encapsulates flanking computation inside iterator
  - Future encounter-dependent conditions easy to add

  Cons:
  - Circular dependency risk: agent.zig would import encounter.zig
  - Heavier coupling - iterator now knows about multi-opponent concepts
  - Passing more data than most callers need

  ---
  Option C: Handle flanking directly in DefenseContext (not via ConditionIterator)

  pub const DefenseContext = struct {
      // ...existing...
      flanking: FlankingStatus = .none,
  };

  // In forDefender:
  if (defense.flanking == .partial) mods.dodge_mod -= 0.10;
  if (defense.flanking == .surrounded) { ... }

  Pros:
  - No API changes to ConditionIterator or activeConditions
  - Flanking only affects defense - natural fit
  - Explicit about where flanking matters
  - Encounter-level concerns stay at resolver level
  - isIncapacitated() unaffected

  Cons:
  - .flanked/.surrounded conditions exist but aren't yielded by iterator
  - Can't use generic condition-checking for flanking
  - Task card explicitly says "extend ConditionIterator"

  ---
  Option D: Pre-compute as stored condition at tick start

  Pros:
  - No API changes
  - Works everywhere

  Cons:
  - Lifecycle management (add/remove each tick)
  - Conflates ephemeral state with persistent conditions
  - Feels hacky