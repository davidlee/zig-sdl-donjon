• Spent some time unpacking what “techniques” really mean in the current code so we can gauge whether a schema buys us
  leverage or just churn:

  - Techniques are a tight, fixed table (card_list.zig:50-310). Each entry is a straight cards.Technique struct with
    mostly scalar fields: attack mode, targeting heights, a single damage.Base (instances + scaling ratio), some defense
    multipliers, optional advantage, and, for manoeuvres, simple overlay bonuses. There are only ~10 combat techniques
    (thrust/swing/throw/deflect/parry/block/riposte) plus six footwork manoeuvres. Nothing dynamic is generated at
    runtime; everything is literal Zig data.
  - Cards build on techniques but add much richer declarative behaviour (card_list.zig:341+). A card template is a bundle
    of rules (triggers, filters, expressions) that reference techniques by ID, manipulate resources, add conditions, etc.
    This is where most of the combinatorial complexity lives, not in the technique structs themselves.
  - Why CUE could help here:
      1. We absolutely need technique-level metadata for the G/E/R axis conversion (e.g., draw-cuts trading Energy for
         Geometry, hooks getting leverage bonuses, grip mixins like half-sword). Right now those knobs don’t exist at all,
         so when we add them we either invent a Zig DSL or reuse the same CUE schema that’s already producing materials/
         weapons. Putting conversion factors, grip tags, and overlay bonuses into CUE keeps all the axis math in one
         declarative system.
      2. Techniques are referenced by cards via IDs; exporting them from CUE gives us a single source of truth and makes
         it easy to add validation (e.g., “every technique used by a card must exist,” “no duplicate channel sets”).
      3. Manoeuvre overlay bonuses and defensive multipliers are basically data tables already—schema-driven generation
         means we can attach documentation/comments in one place and avoid retyping the same .instances = &.{.{ .amount =
         0 }} boilerplate repeatedly.
  - Where CUE doesn’t buy much (yet):
      - Cards themselves still need the “rules/expressions” machinery, and today that logic is heavily entwined with Zig
        unions (Effect, Predicate, etc.). Unless we go all-in on a DSL, those remain POZOs for now.
      - If we only mirror the current technique table without adding the new axis metadata, the payoff is small. There are
        so few rows that hand-editing them isn’t painful.

  Recommendation: when we extend the schema to include techniques, focus on the bits we can’t do in Zig yet:

  - Add a techniques.cue dataset that defines the existing Technique fields plus the new axis-conversion metadata (e.g.,
    per-technique { geometry_gain, rigidity_gain, energy_bias }, grip/feature tags, and manoeuvre overlay presets). This
    keeps the Energy/Geometry split declared alongside the weapon data rather than scattered in code.
  - Have cards continue to reference techniques by ID, but keep card templates in Zig until/unless we’re ready to invent a
    higher-level rule language.
  - As part of Phase 1 (data audit) in the plan, explicitly list “capture technique/grip metadata” so the CUE pipeline
    knows about these conversion factors when we start deriving axis magnitudes.

  That keeps CUE scoped to the truly tabular pieces (materials, weapons, techniques, body-part geometry) while we evaluate
  separately whether the richer card logic ever wants its own DSL.