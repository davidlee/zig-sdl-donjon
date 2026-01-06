• Card Primitives

  - src/domain/cards.zig:9-382 defines templates as { tags, cost, rules[] } where each Rule has .trigger, .valid, and .expressions. Predicates include equipment checks, range, advantage
    thresholds, and nested boolean combinators. Expressions cover modify_play, modify_range, add_condition, resource modifiers, etc. This is a solid foundation: cards describe what they
    need (predicates) and what they do (effects) in data, not code.

  Current Execution Flow

  - Validation: src/domain/apply/validation.zig:24-220 evaluates Rule.valid, tags.canPlayInPhase, range/weapon reach, and generic resource checks. Predicates include weapon_category, range,
    advantage_threshold, has_condition, etc. This runs for any agent/card pair, so the rule language is already agent-agnostic—good for equipment/spells.
  - Targeting & play effects: src/domain/apply/targeting.zig:1-210 resolves target queries plus play predicates (my_play, opponent_play). On-commit modifiers go through effects/commit.zig.
    On-resolve effects feed into effects/resolve.zig (resource recovery, conditions) and effects/manoeuvre.zig (range changes). These all use the same rule/expression data.
  - Resolution: src/domain/resolution/* handles technique outcomes, damage, and advantage, but only for expressions that map to “techniques” today. Non-technique effects (conditions,
    resources) are still handled in apply’s resolve phase.

  Consistency & Coverage Observations

  - Triggers: Core triggers exist (on_play, on_commit, on_resolve, passive). However, only commit/resolve triggers are exercised; no dedicated handling for on_draw, on_equip, or on_tick. If
    future equipment/class cards rely on them, the engine needs explicit hook points.
  - Predicate completeness: The current predicate evaluator (apply/validation.zig:225-358) handles equipment, range, and condition checks but leaves weapon_reach and advantage_threshold as
    TODO/false. For generality, these branches must be implemented; otherwise you’ll end up with ad-hoc code (e.g., equipment-specific checks) that bypass predicates.
  - Expression coverage: Expressions support resource adjustments, play modifiers, range changes, condition add/remove, but there isn’t a generic “apply arbitrary effect to agent”
    interface. For items/spells/class talents you likely need sub-actions like “grant card”, “toggle tag”, “spawn minion”, etc., which would require extending Effect enum.
  - Uniform handling: Techniques (offensive actions) go through resolution, but defensive or utility cards rely on bespoke logic in apply (e.g., executeResolvePhaseRules). For future
    features, consider unifying effect application: both offensive and non-offensive expressions could emit a ResolvedEffect struct, and a single executor would interpret them. Right now
    the split means certain effect types only work in specific phases.
  - Rule injection points: There’s no dispatcher for triggers outside combat phases. If equipment wants to fire on equip or when stats change, you need event hooks that feed into the same
    Rule evaluation pipeline. Without them, devs will write special cases (“if card.tags.equipment do X”), undermining the goal.

  Gaps / Risks

  1. Incomplete predicate operators (weapon reach, advantage thresholds) mean the rule language can’t yet express all requirements. Implementing those should be a priority before layering
     new card types.
  2. Limited trigger coverage: Only commit/resolve/permanent passives fire. Add infrastructure for other triggers (on equip, on draw, on tick) so future mechanics don’t require new bespoke
     code paths.
  3. Expression scope: The current Effect union is combat-focused. To handle inventory/class systems, extend it or allow expressions to call named “scripts” so you don’t have to bake every
     new effect into apply.zig.

  Recommendations / Next Actions

  - Flesh out the predicate evaluator and ensure every cards.Predicate variant has a real implementation or deliberate fallback; add tests verifying new ones (range, advantage, equipment
    states).
  - Introduce a generalized effect dispatcher: parse rule expressions into a ResolvedEffect regardless of trigger phase, then have phase-specific executors decide when to apply. This
    removes duplicated logic between commit/resolve and future phases.
  - Add trigger hooks to World/EventProcessor for non-combat events (equip, item use, rest). Each hook should run rulePredicatesSatisfied + expression execution so equipment/spells can ride
    the same pipeline.
  - Expand Effect to include operations you anticipate (grant card, alter stats permanently, give XP). Keep them data-driven to avoid special-case code.

  With those extensions, the core card/rule system remains the single “language” for equipment, spells, class abilities, and so on, and apply/resolution simply become interpreters rather
  than bespoke logic islands.