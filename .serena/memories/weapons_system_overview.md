# Weapons System Overview
- `src/domain/weapon.zig` treats weapons as declarative templates split into offensive, defensive, and ranged facets. `Template` aggregates categories (e.g., sword, axe), grip options (one-handed, two-handed, versatile, half-sword, etc.), length/weight/balance, swing vs thrust stats, defensive ratings, ranged metadata, and structural integrity.
- Offensive profiles describe reach, damage types, speed, accuracy, base damage, penetration curve, defender modifiers, and fragility. Defensive profiles capture parry/deflect/block ratings plus reach/fragility. Ranged profiles nest projectile or thrown descriptors with their own range/accuracy/reload data. Feature flags (hooked, spiked, crossguard) allow downstream rules/predicates to key off weapon traits.
- Runtime `Instance` just binds an id to a template; attack resolution queries the template to compute stakes, modifiers, and condition interactions, keeping logic generic.

## Physics Fields (T037)
`Template` now includes 3-axis physics for damage derivation:
- `moment_of_inertia`: kg·m² for swing energy calculation
- `effective_mass`: kg for thrust energy calculation
- `reference_energy_j`: baseline joules at reference stats
- `geometry_coeff`: 0-1, penetration efficiency (blade geometry)
- `rigidity_coeff`: 0-1, structural support of striking surface

These are used by `resolution/damage.zig:createDamagePacket` to derive the `geometry`/`energy`/`rigidity` axes on damage packets. Because all combat-relevant parameters sit in data tables (see also `weapon_list.zig`), adding new weapons or tweaking balance never requires special-case code—card techniques and combat rules pull values through the shared interfaces (`Technique` references weapon templates, predicates check `weapon.Category`, etc.).