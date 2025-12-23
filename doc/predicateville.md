
  ┌─────────────────────────────────────────────────────────────────┐
  │  Predicates need to query...                                    │
  ├─────────────────────────────────────────────────────────────────┤
  │  • card tags/properties     (always present)                    │
  │  • actor stats              (player, humanoid - not ooze)       │
  │  • equipped weapon          (player, humanoid - not ooze)       │
  │  • armor/shield             (player, humanoid - not ooze)       │
  │  • wounds/conditions        (all, but different granularity)    │
  │  • engagement state         (always present in combat)          │
  │  • stamina/resources        (player, humanoid - ooze has budget)│
  └─────────────────────────────────────────────────────────────────┘

  Sketch: Component-flavored design

  // === Shared components (owned by whoever needs them) ===

  const Resources = struct {
      stamina: f32,
      stamina_available: f32,
      time_available: f32 = 1.0,
  };

  const EquipmentSet = struct {
      weapon: ?*const weapon.Template,
      off_hand: ?*const weapon.Template,  // shield, second weapon
      armor: ArmorStack,

      pub fn weaponReach(self: *const EquipmentSet) ?combat.Reach {
          return if (self.weapon) |w| w.reach else null;
      }
  };

  const ConditionSet = struct {
      items: std.ArrayList(damage.Condition),
      // ...
  };

  // === Predicate evaluation context ===

  const PredicateContext = struct {
      card: *const cards.Instance,

      // Required
      engagement: *const Engagement,

      // Optional - null means "predicate fails" for checks requiring it
      stats: ?*const stats.Block = null,
      equipment: ?*const EquipmentSet = null,
      resources: ?*const Resources = null,
      conditions: ?*const ConditionSet = null,

      pub fn fromPlayer(card: *const cards.Instance, p: *const Player, eng: *const Engagement) PredicateContext {
          return .{
              .card = card,
              .engagement = eng,
              .stats = &p.stats,
              .equipment = &p.equipment,
              .resources = &p.resources,
              .conditions = &p.conditions,
          };
      }

      pub fn fromHumanoid(card: *const cards.Instance, h: *const Humanoid, eng: *const Engagement) PredicateContext {
          return .{
              .card = card,
              .engagement = eng,
              .stats = &h.stats,
              .equipment = &h.equipment,
              .resources = &h.resources,
              .conditions = null,  // simpler tracking for AI
          };
      }

      pub fn fromCreature(card: *const cards.Instance, eng: *const Engagement) PredicateContext {
          return .{
              .card = card,
              .engagement = eng,
              // everything else null - ooze has no stats/equipment
          };
      }
  };

  fn evaluatePredicate(p: *const Predicate, ctx: *const PredicateContext) bool {
      return switch (p.*) {
          .always => true,
          .has_tag => |tag| ctx.card.template.tags.hasTag(tag),

          .weapon_category => |cat| blk: {
              const eq = ctx.equipment orelse break :blk false;
              const w = eq.weapon orelse break :blk false;
              break :blk w.category == cat;
          },

          .weapon_reach => |check| blk: {
              const eq = ctx.equipment orelse break :blk false;
              const reach = eq.weaponReach() orelse break :blk false;
              break :blk compare(reach, check.op, check.value);
          },

          .range => |check| compare(ctx.engagement.range, check.op, check.value),

          .advantage_threshold => |check| blk: {
              const val = switch (check.axis) {
                  .pressure => ctx.engagement.pressure,
                  .control => ctx.engagement.control,
                  .position => ctx.engagement.position,
                  .balance => break :blk false,  // need actor ref for this
              };
              break :blk compareF32(val, check.op, check.value);
          },

          .not => |inner| !evaluatePredicate(inner, ctx),
          .all => |preds| for (preds) |pred| {
              if (!evaluatePredicate(&pred, ctx)) break false;
          } else true,
          .any => |preds| for (preds) |pred| {
              if (evaluatePredicate(&pred, ctx)) break true;
          } else false,
      };
  }

  Separate deck concepts:

  // Player: full zone management
  const PlayerDeck = struct {
      // Current Deck implementation - zones, shuffle, draw rules
  };

  // Humanoid AI: simplified pool
  const TechniquePool = struct {
      available: []const *cards.Template,  // what they know
      in_play: std.ArrayList(*cards.Instance),  // committed this tick
      cooldowns: std.AutoHashMap(cards.ID, u8),  // technique -> ticks remaining

      // No hand/draw - AI picks from available based on behavior pattern
      pub fn canUse(self: *const TechniquePool, t: *const cards.Template) bool {
          return (self.cooldowns.get(t.id) orelse 0) == 0;
      }
  };

  // Creature: pure behavior script, no "cards" at all
  const BehaviorScript = struct {
      pattern: []const ScriptedAction,
      index: usize,

      pub fn next(self: *BehaviorScript) ScriptedAction {
          const action = self.pattern[self.index];
          self.index = (self.index + 1) % self.pattern.len;
          return action;
      }
  };

  Actor union ties it together:

  const Actor = union(enum) {
      player: *Player,
      humanoid: *Humanoid,
      creature: *Creature,

      pub fn predicateContext(self: Actor, card: *const cards.Instance, eng: *const Engagement) PredicateContext {
          return switch (self) {
              .player => |p| PredicateContext.fromPlayer(card, p, eng),
              .humanoid => |h| PredicateContext.fromHumanoid(card, h, eng),
              .creature => PredicateContext.fromCreature(card, eng),
          };
      }

      pub fn engagement(self: Actor) *Engagement {
          return switch (self) {
              .player => unreachable,  // player doesn't own engagement
              .humanoid => |h| &h.engagement,
              .creature => |c| &c.engagement,
          };
      }
  };

  This gives you:
  - Shared predicate evaluation with graceful degradation for missing components
  - Different deck/pool systems that don't pretend to be the same thing
  - Clear Actor dispatch for resolution code
  - Components that can be mixed-and-matched as needed

---



  1. Shared struct composition (simplest, idiomatic)
  // Shared "can play cards" capability
  const CardUser = struct {
      deck: *Deck,
      stats: *stats.Block,
      stamina: f32,
      stamina_available: f32,
      time_available: f32,
      state: State,
  };

  const Player = struct {
      cards: CardUser,
      wounds: std.ArrayList(body.Wound),
      // player-only stuff...
  };

  const Humanoid = struct {
      cards: CardUser,
      engagement: Engagement,
      behavior: ?*BehaviorPattern,  // AI decision-making
      // ...
  };

  2. Comptime duck typing (zero-cost abstraction)
  fn validatePlay(actor: anytype, card: *const Instance) !void {
      // Compiler enforces actor has these fields/methods
      if (actor.stamina_available < card.template.cost.stamina)
          return error.InsufficientStamina;
      if (!actor.deck.instanceInZone(card.id, .hand))
          return error.CardNotInHand;
  }

  // Usage: works for Player, Humanoid, anything with the right shape
  try validatePlay(&player, card);
  try validatePlay(&goblin, card);

  3. Tagged union for dispatch (when you need runtime polymorphism)
  const Actor = union(enum) {
      player: *Player,
      humanoid: *Humanoid,

      // Delegate to shared CardUser
      pub fn cardUser(self: Actor) *CardUser {
          return switch (self) {
              .player => |p| &p.cards,
              .humanoid => |h| &h.cards,
          };
      }
  };

  For events, the origin distinction is clean:
  const Event = union(enum) {
      // Player-initiated (via CommandHandler)
      played_action_card: struct { actor: Actor, instance: EntityID, ... },

      // AI-initiated (via BehaviorSystem)
      ai_action_declared: struct { actor: Actor, technique: TechniqueID, ... },

      // Resolution (origin-agnostic)
      technique_resolved: struct { attacker: Actor, defender: Actor, outcome: Outcome, ... },
      advantage_changed: AdvantageEffect,
  };

---

Let me synthesize both sketches and identify the near-term work.

  Unified picture:

  ┌─────────────────────────────────────────────────────────────────┐
  │  DECISION LAYER (who decides what to do)                        │
  ├───────────────────┬───────────────────┬─────────────────────────┤
  │  Player           │  Humanoid         │  Creature               │
  │  PlayerDeck       │  TechniquePool    │  BehaviorScript         │
  │  CommandHandler   │  AIDecider        │  (direct emit)          │
  │                   │                   │                         │
  │  Validity/Query   │  Validity/Query   │  (none needed)          │
  │  predicates       │  predicates       │                         │
  └─────────┬─────────┴─────────┬─────────┴────────────┬────────────┘
            │                   │                      │
            ▼                   ▼                      ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  EVENT SYSTEM                                                   │
  │  action_declared { actor: Actor, technique, commitment, ... }   │
  └─────────────────────────────┬───────────────────────────────────┘
                                ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  RESOLUTION (actor-agnostic)                                    │
  │  • Match opposing actions (simultaneous commitment)             │
  │  • Modifier pipeline (stats → weapon → conditions → ...)        │
  │  • Outcome determination (hit/block/parry/dodge)                │
  │  • Filter predicates per effect per target                      │
  │  • Apply damage, advantages, state changes                      │
  └─────────────────────────────┬───────────────────────────────────┘
                                ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │  RESULT EVENTS                                                  │
  │  technique_resolved, wound_inflicted, advantage_changed, ...    │
  └─────────────────────────────────────────────────────────────────┘

  Three predicate flavors, one context pattern:

  // Shared context - optional fields handle actor variety
  const EvalContext = struct {
      actor: Actor,
      card: *const cards.Instance,
      engagement: *const Engagement,

      // For filter/query predicates
      target: ?Actor = null,
      effect: ?*const Effect = null,

      // Derived accessors (handle Actor dispatch internally)
      pub fn actorStats(self: *const EvalContext) ?*const stats.Block { ... }
      pub fn actorEquipment(self: *const EvalContext) ?*const EquipmentSet { ... }
      pub fn targetStats(self: *const EvalContext) ?*const stats.Block { ... }
      // ...
  };

  Natural weapons/armor - treat as equipment with a source tag:

  const EquipmentSlot = struct {
      template: *const weapon.Template,
      source: enum { equipped, natural, magical },
  };

  // Predicates that check "has sword" work for both equipped and claws-as-slashing

  ---
  Near-term work to stand up an integrated step:

  | Priority | Task                                            | Why                                                                |
  |----------|-------------------------------------------------|--------------------------------------------------------------------|
  | 1        | Extract Resources struct                        | Shared stamina/time tracking. Player embeds it, Humanoid will too. |
  | 2        | Create Actor union                              | player: *Player, mob: *Mob for now. Use in event payloads.         |
  | 3        | Create EvalContext + refactor evaluatePredicate | Currently takes (card, actor, target) as separate args. Unify.     |
  | 4        | Kill Mob.play() and its card hacks              | Remove slot_map/hand/in_play from Mob. Mobs don't play cards yet.  |
  | 5        | Add BehaviorScript stub                         | Mob emits actions from pattern, not from "playing cards".          |
  | 6        | Fix harness + memory cleanup                    | Remove exit(0), fix Encounter.deinit → mob.deinit chain.           |

  The goal: after this, you have:
  - Player playing cards through CommandHandler (existing, cleaned up)
  - Mob emitting scripted actions through BehaviorScript (new, simple)
  - Both producing events with Actor payloads
  - Predicate evaluation uses EvalContext (ready to grow)
  - Resolution can dispatch on Actor when needed

