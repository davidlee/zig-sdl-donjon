 Card Modeling Review

  - src/cards.zig:19 defines Rule { trigger, predicate, effects } plus Effect = union { Op, If, ForEach, Custom }, but Op itself is just an enum
    with no parameters (src/cards.zig:40). That means every effect either needs a bespoke “custom” branch or gets forced through IfEffect/
    ForEachEffect wrappers even when you simply want “op + optional predicate + optional query.” It also duplicates concerns: both Rule and
    Effect.If carry predicates, and ForEach bakes targeting into control flow. You can simplify the surface area and make behavior clearer by
    turning Effect into a single struct:

    pub const Effect = struct {
        op: OpSpec,             // tagged union with payload (damage, draw, etc.)
        predicate: ?Predicate,  // optional guard
        target: TargetQuery,    // query returning one or many entities/parts
        mods: ModifierHooks,    // optional extra data (e.g., use stamina pipeline)
    };
    can just be expressed as data in Predicate/TargetQuery rather than separate union tags.
  - Predicate and Query are empty stubs right now (src/cards.zig:46), so it isn’t clear how you planned to express “target has Blind” vs. “loop
    over all enemies”. The docs in doc/card_game.md:287 outline a small expression language and query system; I’d model these as simple ASTs:

    pub const Predicate = union(enum) {
        AlwaysTrue,
        CompareStat: struct { lhs: StatAccessor, op: CmpOp, rhs: Value },
        HasTag: Tag,
        Not: *Predicate,
        And: []const Predicate,
        Or: []const Predicate,
    };
    pub const TargetQuery = union(enum) {
        Single: Selector,          // e.g. explicit target chosen during play
        AllEnemies,
        Self,
        BodyPart: BodyPartTag,
        EventSource,
    };

    Each effect then runs predicate.eval(context) before invoking the op and uses target.execute(context) to produce one or more entities for the
    op to mutate. This keeps “control flow” separate from the low-level ops while still being purely data.
  - The ops themselves currently have no payloads (ApplyDamage, InterruptAction, etc.). To make stats/equipment modifiers meaningful, each op needs
    a parameter struct that describes the base packet before modifiers run. Example:

    pub const OpSpec = union(enum) {
        ApplyDamage: struct {
            base: DamagePacket,         // numbers derived from card definition
            scaling: ScalingSpec,       // e.g. { stat = .power, ratio = 0.6 }
            damage_kind: DamageKind,
            action_ref: ActionRef,      // optional, for logging/interrupt
        },
        StartAction: ActionSpec,
        ModifyStamina: struct { amount: i32 },
        MoveCard: struct { from: Zone, to: Zone },
        AddModifier: ModifierSpec,
        EmitEvent: Event,
    };

    When you resolve the effect, you build a DamageContext (card id, actor id, targets) and feed it through the modifier pipeline described in doc/
    card_game.md:434. That’s where stats, equipment, passives, wounds, encounter effects, etc., get a chance to rewrite time costs, damage, or
    legality, and the op stays a clean “mutate via apply.zig” request.
  - Right now TriggerKind stores either built-in triggers or an on_event: EventTag branch (src/cards.zig:19). That’s good, but you’ll want a level
    of indirection between Event and trigger subscriptions if you ever need predicates on the event payload (e.g. “when this action finishes”).
    Consider storing TriggerKind.OnEvent as { kind: EventTag, filter: ?EventPredicate }, where EventPredicate is a tiny struct that can reference
    fields inside the event (like ActionCompleted.action == this_card_action). That keeps the event union unchanged while giving cards fine-grained
    filters.
  - To connect stats/equipment/passives with card resolution (per your question), define explicit compute hooks that every op goes through before
    reaching apply. For example:

    fn resolve_damage(base: DamagePacket, ctx: DamageContext) DamagePacket {
        var packet = base;
        packet += ctx.actor.stats.scale(base.scaling);
        packet = modifiers.apply(.damage, ctx.actor, ctx.targets, packet);
        return packet;
    }

    fn resolve_action_cost(base: ActionCost, ctx: ActionContext) ActionCost {
        var cost = base;
        cost = modifiers.apply(.action_time, ctx.actor, cost);
        cost = modifiers.apply(.stamina_cost, ctx.actor, cost);

    Cards only specify base values; equipment, passives, wounds, environment, and temporary buffs register modifiers in scope-specific lists. When
    an effect runs, you gather modifiers from relevant scopes (global → encounter → party → unit → body parts → cards in play) in deterministic
    order (see doc/card_game.md:434). This ensures that adding a passive doesn’t require touching every card definition and keeps the pipeline
    uniform.
    the actual effect packet. This separation makes interrupt handling straightforward and matches the simultaneous-commit design in doc/
    
  --
     To handle single vs multi-strike cards, complex targeting, and mixed damage types, we don’t need to ditch the overall structure—just make sure
  the data we store in Effect/Op (and the modifier pipeline around them) can express those cases cleanly:

  - Multi-target selection: let Effect.target be a small query AST rather than a boolean “everyone or single.” Include selectors
    like .single_target, .all_enemies, .random_targets { count: u8 }, .event_source, .chosen_body_part, etc. If a card needs the player to pick two
  - Multiple strikes per card: model each strike as either separate effects under the same rule or as an OpSpec.ApplyDamage with count metadata.
    Example:

    .effects = &.{
        .{ .op = .StartAction(.{ ... base_cost ... }) },
        .{ .op = .ApplyDamage(.{
              .packet = DamagePacket{
                  .instances = &.{ .{ .amount = 6, .types = &.{ .Slash } } },
                  .repeat = RepeatSpec{ .count = 3, .per_target = true },
              },
          }),
        },
    };

    The resolver can interpret repeat as “apply 3 sequential hits to each target,” and modifiers (equipment, passives) get a chance to alter
    counts/targeting.
  - Damage packet structure: instead of a single enum tag, store an array of “damage instances,” each with an amount and one or more types.

    const DamageInstance = struct {
        amount: i32,
        types: []const DamageType, // e.g. &.{ .Slashing, .Fire }
    };
    const DamagePacket = struct {
        instances: []const DamageInstance,
        distribution: TargetDistribution, // same target, split, random, chain, etc.
    };

    The modifier pipeline can then adjust amounts per type, convert slashing to bleed, add bonus instances, etc. When the packet hits a target, you
    compute resistances per type and stack wounds accordingly. Multiple damage types in one swing (e.g., “flaming sword” = slashing + fire) drop
    naturally out of this structure.
  - Random target selection: handled at the query level. TargetQuery.RandomEnemies { count = 2, distinct = true } would internally pull from
    RandomStreamDict.drawRandom(.combat) for reproducibility. Record those draws via events (already done in random.zig), so replays know which
    enemies were selected.
  - Player choosing multiple targets: the command/resolver path needs to capture all required target choices before resolving effects. Since
    commands are being simplified, have the UI gather []EntityID as part of the “play card” intent when the card’s TargetQuery demands it. Store
    those IDs in the effect context so modifiers and ops know which entities they’ll hit.

  With these tweaks, the existing Rule→Effect→Op pipeline still works:

  1. Rule triggers when appropriate.
  2. Each Effect evaluates its predicate, runs the target query (which may invoke RNG or use pre-selected IDs), and produces a list of targets/body
     parts.
  3. OpSpec.ApplyDamage builds a DamageContext containing the base packet, strike counts, and target list.
  4. Modifier pipeline adjusts the packet per scope (global, encounter, actor, equipment, passives).
  5. apply.zig mutates health/wounds using the typed packet, handling resistances or multi-hit sequencing.

  So nothing fundamentally breaks—just ensure Effect carries enough metadata (target query, repeat spec, damage packet) so a single data-driven op
  can express “hit everyone,” “hit two random foes,” or “slash three times with mixed damage.”