# Combat Resolution Pipeline Overview
- Resolution lives under `src/domain/resolution/`. `context.zig` builds `AttackContext`/`DefenseContext` structs from world state (agents, weapon templates, engagements, timing, stakes). It computes `CombatModifiers` by folding condition-derived penalties, attention focus, grasp strength, mobility, flanking status, stationary state, and manoeuvre overlays (via `getOverlayBonuses`). This keeps every source of advantage expressed as data feeding multipliers instead of bespoke conditionals.
- `outcome.zig` orchestrates the attack cycle: `calculateHitChance` blends technique accuracy, attacker/defender modifiers, overlays, stakes, and randomness to produce roll data. `resolveTechniqueVsDefense` applies advantage effects, emits events (`technique_resolved`, `advantage_changed`), and, on hit, assembles a `damage.Packet`. `resolveOutcome` drives armour absorption, body damage, and returns a `ResolutionResult` with detailed traces (armour result, body result, advantage changes) for downstream systems/UI.
- Supporting modules (`advantage.zig`, `height.zig`, `resolution/damage.zig`) encapsulate specific calculations (reach/height interactions, advantage accumulation, packet construction) so new mechanics can plug in by adjusting data (technique traits, armour materials, agent modifiers) rather than rewriting the resolver.

## 3-Axis Damage Model (T037)
`resolution/damage.zig:createDamagePacket` now populates geometry/energy/rigidity on `damage.Packet`:
- `geometry` = weapon.geometry_coeff × technique.axis_geometry_mult
- `energy` = weapon.reference_energy_j × stat_scaling × stakes × technique.axis_energy_mult
- `rigidity` = weapon.rigidity_coeff × technique.axis_rigidity_mult
Non-physical damage kinds have all axes zeroed. Armour and tissue resolution use these axes (with legacy fallback for backward compat). Events emitted at each phase keep the process observable for AI/UI/logging.