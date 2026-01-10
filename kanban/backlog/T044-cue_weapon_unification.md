# T044: CUE Weapon Unification
Created: 2026-01-10

## Problem statement / value driver
Weapon data is currently split: `weapon_list.zig` contains hand-crafted combat profiles (accuracy, reach, damage), while `GeneratedWeapons` from CUE contains the physics constants (Inertia, Mass, Coeffs). This redundancy makes maintenance difficult and forces the test runner to use brittle mapping tables. We need to unify all weapon data into CUE.

### Scope - goals
- Extend `#Weapon` schema in CUE to include all combat stats (reach, accuracy, speed, damage, profiles).
- Update `cue_to_zig.py` to generate the complete `weapon.Template` struct for every weapon.
- Replace `src/domain/weapon_list.zig` with a generated version (or a registry that loads the generated data).
- Clean up data-driven combat tests to use CUE weapon IDs directly without mapping.

### Scope - non-goals
- Changing the weapon logic itself.
- Redesigning the combat profiles (just migrate them).

## Background
- `doc/artefacts/data_generation_plan.md` outlines the intent for CUE-first data authoring.
- `src/domain/weapon_list.zig` is the current manual source.

## Changes Required

### 1. CUE Schema Expansion
Update `#Weapon` in `data/weapons.cue` to include:
- `categories`: [...string]
- `reach`: enum
- `swing`: #OffensiveProfile
- `thrust`: #OffensiveProfile
- `defence`: #DefensiveProfile

### 2. Generator Updates
Update `cue_to_zig.py` to emit the full nested structs for `weapon.Template`.

### 3. Cleanup
- Remove the ID-to-template mapping in `src/testing/integration/domain/data_driven_combat.zig`.
- Use the generated weapon array as the primary data source.

## Tasks / Sequence of Work
1. [ ] Map `weapon_list.zig` fields into CUE schema.
2. [ ] Port `knights_sword`, `horsemans_mace`, etc., to `data/weapons.cue`.
3. [ ] Update generator to emit full templates.
4. [ ] Wire runtime weapon lookup to use the generated data.
5. [ ] Verify all tests pass with unified data.

## Test / Verification Strategy
- Integration tests should pass without changes (logic is preserved, source is unified).
- Data-driven tests should load weapons by ID `"swords.knights_sword"` seamlessly.