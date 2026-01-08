• Resolution Audit

  - src/domain/resolution/context.zig:37-224 keeps orchestration-free context objects and aggregates modifiers from card
    techniques/manoeuvres, which is great sympathy with the data-driven card model: AttackContext carries pointers to
    cards.Technique, manoeuvre overlays are fetched by scanning timeline slots for .tags.manoeuvre, and condition penalties come
    straight from damage.penaltiesFor. This lets card templates drive most math. However, the modifier loop still special-
    cases .blinded/.winded with hard-coded logic instead of relying entirely on Technique metadata or condition_penalties, so
    extending those behaviors means editing code rather than data. Consider moving those attack-mode adjustments into data (e.g.,
    add metadata to the condition penalty table keyed by attack_mode) to keep sympathy and composability.
  - CombatModifiers.forAttacker/forDefender currently iterate the agent’s computed condition stream twice per resolution (once in
    calculateHitChance, again in resolveOutcome for logging; see src/domain/resolution/outcome.zig:88-130 vs 157-159). This breaks
    DRY/SRP and makes it easy for logging numbers to diverge from actual calculations if future edits forget to update both sites.
    Capturing the CombatModifiers once and threading them through would keep things elegant and reduce redundant iteration over the
    rules/predicate/effect pipeline.
  - calculateHitChance (src/domain/resolution/outcome.zig:66-131) mixes concerns—technique stats, weapon accuracy, stakes,
    engagement/balance math, guard height checks, defender weapon stats, and dodge penalties all in one function. That monolith
    makes it hard to reason about or reuse pieces outside combat (e.g., for simulated sparring or tutorial previews) and increases
    the risk of strangling non-combat concepts. Splitting contributions into reusable helper functions with data descriptors (e.g.,
    Technique.hitProfile, DefenseTechnique.coverageProfile) would support extensions like non-combat contests or magical systems
    without rewriting the resolver.
  - Manoeuvre overlays (context.zig:188-224) are a clean example of emergent complexity: timeline cards tagged as manoeuvres
    contribute Technique.overlay_bonus data, so stacking “advance” + “sidestep” just works and tests capture that (context.zig:287-
    389). This nicely produces tactical depth from simple parts. Keep pushing similar patterns—e.g., let defensive cards contribute
    overlay data instead of bolting on new flags.
  - Interoperation with non-combat systems is mostly clean: resolveTechniqueVsDefense delegates to armour/body modules
    (outcome.zig:223-245), emits events only through w.events (outcome.zig:248-259), and never reaches into UI. One caveat is that
    getOverlayBonuses assumes an encounter timeline (context.zig:190-224); if you ever need to resolve attacks in a non-encounter
    context (training, scripted scenes), the function currently returns zeros rather than letting other systems supply equivalent
    overlays. Consider abstracting the slot source so non-combat timelines can participate.
  - Realism goals are partially met: guard-height coverage (lines 106-117) and weapon parry/deflect stats (line 121) capture
    historical cues, while grasp/mobility penalties depend on body capability scores (context.zig:111-171). Yet certain pieces
    hard-code modern assumptions—for example, .block reuses attack.technique.deflect_mult as a proxy (line 98), and flanking
    penalties are fixed percentages (lines 135-144) rather than derived from engagement data. Encoding these relationships as data
    (e.g., per-technique defense curves, per-engagement-angle tables) would let you dial historical realism up or down or inject
    magical modifiers without more branching.

  Overall, the resolution layer is close to the design goals where it leans on card/technique data and world events. Tightening up
  the remaining imperative patches (condition special cases, monolithic hit chance calculation, duplicated modifier loops) and
  externalizing more of the “why” into data tables will improve composability, keep non-combat reuse viable, and make it easier to
  introduce flavorful historical or magical tweaks via the declarative pipeline.