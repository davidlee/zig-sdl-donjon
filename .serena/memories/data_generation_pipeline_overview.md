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
- Weapon exports include `moment_of_inertia`, `effective_mass`, and `reference_energy_j`; runtime damage should recompute energy from stats.
- Technique exports include channels, damage instances, scaling, overlays, and axis biases.
- `scripts/cue_to_zig.py` validates technique IDs against the Zig enum before emitting data.
- Armour piece schema stub exists; wiring armour data into runtime is the next step.
