# Data Generation from Schema Language

**Related**:
- `doc/issues/impulse_penetration_bite.md` (three-axis damage model - primary use case)
- `src/domain/weapon_list.zig`, `src/domain/species.zig`, `src/domain/armour.zig` (current data)

## Problem

Game data (weapons, armour, species, body templates) is currently defined as Zig const structs. This works but has drawbacks:

- **Verbose** - lots of boilerplate per entry
- **Repetitive** - similar weapons repeat most fields
- **No validation** - typos and missing fields caught only at comptime
- **No derivation** - can't compute impulse from weight/length/balance
- **Hard to audit** - data spread across multiple files, no schema overview

As the damage model grows more complex (penetration/impulse/bite axes, matching armour coefficients), the data burden increases.

## Idea: CUE → Zig Generation

Use [CUE](https://cuelang.org/) to define game data with:

1. **Schema** - required fields, types, constraints
2. **Defaults** - base templates for weapon/armour categories
3. **Inheritance** - swords share properties, variants override
4. **Derivation** - compute values from physical properties
5. **Validation** - catch inconsistencies before build

Generate Zig const structs at build time. Keep comptime benefits, improve data ergonomics.

## Example

```cue
#Weapon: {
    name: string
    weight: float & >=0
    length: float & >=0
    balance: float & >=0 & <=1

    // Derived impulse from physics
    _effectiveRadius: length * balance
    impulse: 0.5 * weight * _effectiveRadius * _effectiveRadius

    penetration: float & >=0
    bite: float & >=0 & <=1
    ...
}

swords: {
    _base: #Weapon & {
        penetration: 0.5
        bite: 0.8
    }

    knights_sword: _base & {
        name: "Knight's Sword"
        weight: 1.2
        length: 0.9
        balance: 0.6
    }

    arming_sword: _base & {
        name: "Arming Sword"
        weight: 1.0
        length: 0.8
        balance: 0.55
    }
}
```

## Build Integration

```bash
# justfile
generate-data:
    cue export data/weapons.cue --out json | ./scripts/json_to_zig.py > src/domain/weapon_list.zig
```

Or use `cue cmd` to generate Zig directly.

## Considerations

- **Timing** - nail down the data model (three-axis damage, armour coefficients) before building schema
- **Complexity** - adds build step and tooling dependency
- **Iteration** - during rapid prototyping, direct Zig might be faster; schema pays off once model stabilizes
- **Partial adoption** - could start with weapons only, expand later

## Alternatives

- **Dhall** - Haskell-inspired, strong types, less mainstream
- **Jsonnet** - JSON + functions, weaker typing than CUE
- **Custom DSL** - maximum control, maximum effort
- **Stay in Zig** - use comptime more aggressively for validation/derivation

## Next Steps

1. Finalize three-axis damage model
2. Audit current weapon/armour data
3. Design CUE schema for new model
4. Build generation pipeline
5. Migrate existing data
