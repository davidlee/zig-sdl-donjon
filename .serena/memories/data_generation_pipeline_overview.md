# Data Generation Pipeline (CUE)

## Status
- We now author materials, weapons, techniques, and initial armour pieces in `data/*.cue`.
- `scripts/cue_to_zig.py` exports these via `cue export ... | ./scripts/cue_to_zig.py > src/gen/generated_data.zig`.
- `Justfile`'s `generate` recipe (run by `just check`) regenerates data automatically.
- `src/domain/card_list.zig` imports `generated_data.zig` and builds `TechniqueEntries` from the generated definitions.

## Usage
1. Edit/extend `data/materials.cue`, `data/weapons.cue`, `data/techniques.cue`, or `data/armour.cue`.
2. Run `just generate` (or `just check`) to refresh `src/gen/generated_data.zig`.
3. Include the generated structs by importing `@import("../gen/generated_data.zig")` and using helper builders.

## Notes
- Weapon exports (T044) include complete combat profiles: `OffensiveProfileDefinition`, `DefensiveProfileDefinition`, physics coefficients, grip/features, and ranged data. `weapon_list.zig` builds runtime `weapon.Template` from generated `WeaponDefinition` structs.
- Technique exports include channels, damage instances, scaling, overlays, and axis biases.
- `scripts/cue_to_zig.py` validates technique IDs against the Zig enum before emitting data.
- Armour piece exports include 3-axis shielding/susceptibility; `armour_list.zig` builds runtime types.
