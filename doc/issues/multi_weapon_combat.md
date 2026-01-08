# Multi-Weapon Combat: Design Debt

Created: 2026-01-08
Related: T026 (Natural Weapons in Armament)

## The Problem

We now have `Agent.allAvailableWeapons()` which yields equipped weapons + natural weapons. But the combat system doesn't actually use it - cards heuristically pick the "primary weapon" and ignore everything else.

This works for single-weapon combat but is fundamentally broken for:

- **Dual wielding**: sword + dagger, sword + shield (offhand attacks/blocks)
- **Natural + equipped**: punching with offhand while holding sword
- **Two-handed weapons**: different handling than single-handed
- **Ranged weapons**: drawing, nocking, different action economy
- **Weapon switching**: sheathing/drawing mid-combat

## What's Currently Broken (Untested)

These features exist in data but likely don't work correctly:

1. `Armament.Equipped.dual` - dual wield slot exists, never exercised in combat
2. `Armament.Equipped.compound` - exists for future use, TODO in iterator
3. Ranged weapons - `weapon.Template.ranged` field, no combat integration
4. Shield as secondary weapon - no special blocking logic for offhand shield
5. Natural weapons - newly added, no card/technique can select them yet

## Questions to Answer

### Action Economy
- Does offhand attack cost less time than main hand?
- Can you attack with multiple weapons in one technique?
- Do natural weapons require "hands free" or work while armed?

### Weapon Selection
- Should cards specify which weapon slot they use?
- Should the player choose at play time?
- How does AI select weapons?

### UX
- How does UI show multiple available weapons?
- How does player indicate "use fist instead of sword"?
- Timeline visualization for multi-weapon attacks?

## Suggested Path Forward

1. **Audit existing weapon code paths** - what actually happens with dual wield today?
2. **Design weapon selection model** - card-level, technique-level, or slot-based?
3. **Start with shield as offhand** - simplest case, high value (block with shield)
4. **Then natural weapons** - hook `availableNaturalWeapons()` into unarmed techniques
5. **Then ranged** - different action model, needs separate design

## Key Files

- `src/domain/combat/agent.zig` - `allAvailableWeapons()`, `WeaponRef`
- `src/domain/combat/armament.zig` - `Equipped` union, weapon storage
- `src/domain/cards.zig` - technique/attack definitions
- `src/domain/resolution/` - combat resolution, damage calculation
- `src/domain/species.zig` - natural weapon definitions

## See Also

- `doc/issues/fists.md` - original stub about unarmed combat
- `doc/artefacts/species_design.md` - natural weapon integration notes
