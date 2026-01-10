# T044: CUE Weapon Unification - Design

## Problem Statement

Weapon data is split across two sources:
- `weapon_list.zig`: Hand-crafted combat profiles (Offensive, Defensive, reach, accuracy, damage, etc.)
- `GeneratedWeapons` from CUE: Physics constants (MoI, effective mass, coefficients)

This violates the "CUE-first data authoring" principle established in the 3-axis physics work (see `doc/artefacts/geometry_momentum_rigidity_review.md` §9 decisions). The `data_driven_combat.zig` test runner uses a brittle mapping table (`lookupWeaponById`) to bridge CUE IDs to weapon_list entries.

## Goal

Unify all weapon data in CUE, following the `armour_list.zig` pattern:
1. CUE defines complete weapon specifications
2. Generator emits `WeaponDefinition` structs with all combat data
3. `weapon_list.zig` becomes a loader that builds runtime `weapon.Template` at comptime
4. Data-driven tests use generated weapons directly (no mapping table)

## Design

### 1. CUE Schema Extension

Extend `data/weapons.cue` with combat profile schemas:

```cue
#DefenderModifiers: {
  reach: #Reach
  parry: float & >=0 & <=2
  deflect: float & >=0 & <=2
  block: float & >=0 & <=2
  fragility: float & >=0 & <=5
}

#OffensiveProfile: {
  name: string
  reach: #Reach
  damage_types: [...#DamageType]
  accuracy: float & >0 & <=1.5
  speed: float & >0 & <=2
  damage: float & >0
  penetration: float & >=0
  penetration_max: float & >=0
  fragility: float & >=0
  defender_modifiers: #DefenderModifiers
}

#DefensiveProfile: {
  name: string
  reach: #Reach
  parry: float & >=0 & <=1.5
  deflect: float & >=0 & <=1.5
  block: float & >=0 & <=1.5
  fragility: float & >=0
}

#Grip: {
  one_handed: bool | *false
  two_handed: bool | *false
  versatile: bool | *false
  bastard: bool | *false
  half_sword: bool | *false
  murder_stroke: bool | *false
}

#Features: {
  hooked: bool | *false
  spiked: bool | *false
  crossguard: bool | *false
  pommel: bool | *false
}

#Reach: "clinch" | "dagger" | "mace" | "sabre" | "longsword" | "spear" | "near" | "medium" | "far"

#DamageType: "slash" | "pierce" | "bludgeon" | "crush"

#Category: "sword" | "axe" | "mace" | "club" | "dagger" | "polearm" | "shield" | "improvised" | "natural"

#ProjectileType: "arrow" | "bolt" | "dart" | "bullet" | "stone"

#Thrown: {
  throw: #OffensiveProfile
  range: #Reach
}

#Projectile: {
  ammunition: #ProjectileType
  range: #Reach
  accuracy: float & >0 & <=1.5
  speed: float & >0
  reload: float & >=0
}

#Ranged: {
  projectile?: #Projectile
  thrown?: #Thrown
}

#Weapon: {
  name: string
  categories: [...#Category]
  features: #Features | *{}
  grip: #Grip

  // Physical dimensions
  length_cm: float & >0
  weight_kg: float & >0
  balance: float & >=0 & <=1
  integrity: float & >0

  // Combat profiles
  swing?: #OffensiveProfile
  thrust?: #OffensiveProfile
  defence: #DefensiveProfile

  // Ranged (thrown or projectile)
  ranged?: #Ranged

  // Physics (derived or explicit)
  moment_of_inertia: float & >=0
  effective_mass: float & >0
  reference_energy_j: float & >=0
  geometry_coeff: float & >=0 & <=1
  rigidity_coeff: float & >=0 & <=1
}
```

### 2. Generator Updates (`cue_to_zig.py`)

Add new emitter functions following existing patterns:

```python
def format_reach(reach: str) -> str:
    """Map CUE reach string to combat.Reach enum."""
    valid = {"clinch", "dagger", "mace", "sabre", "longsword", "spear"}
    if reach in valid:
        return f"combat.Reach.{reach}"
    raise ValueError(f"Invalid reach: {reach}")

def format_damage_kind(kind: str) -> str:
    """Map CUE damage type to damage.Kind enum."""
    mapping = {"slash": "slash", "pierce": "pierce", "bludgeon": "bludgeon", "crush": "crush"}
    return f"damage.Kind.{mapping[kind]}"

def format_category(cat: str) -> str:
    """Map CUE category to weapon.Category enum."""
    return f"weapon.Category.{cat}"
```

Update `emit_weapons()` to produce full combat definitions:

```python
def emit_weapons(weapons: List[Tuple[str, Dict[str, Any]]]) -> str:
    # Emit DefenderModifiersDefinition
    # Emit OffensiveProfileDefinition
    # Emit DefensiveProfileDefinition
    # Emit GripDefinition
    # Emit FeaturesDefinition
    # Emit WeaponDefinition with all nested structs
    ...
```

The generated output structure:

```zig
pub const DefenderModifiersDefinition = struct {
    reach: combat.Reach,
    parry: f32,
    deflect: f32,
    block: f32,
    fragility: f32,
};

pub const OffensiveProfileDefinition = struct {
    name: []const u8,
    reach: combat.Reach,
    damage_types: []const damage.Kind,
    accuracy: f32,
    speed: f32,
    damage: f32,
    penetration: f32,
    penetration_max: f32,
    fragility: f32,
    defender_modifiers: DefenderModifiersDefinition,
};

pub const DefensiveProfileDefinition = struct {
    name: []const u8,
    reach: combat.Reach,
    parry: f32,
    deflect: f32,
    block: f32,
    fragility: f32,
};

pub const WeaponDefinition = struct {
    id: []const u8,
    name: []const u8,
    categories: []const weapon.Category,
    features: weapon.Features,
    grip: weapon.Grip,
    length: f32,
    weight: f32,
    balance: f32,
    integrity: f32,
    swing: ?OffensiveProfileDefinition = null,
    thrust: ?OffensiveProfileDefinition = null,
    defence: DefensiveProfileDefinition,
    // Physics
    moment_of_inertia: f32,
    effective_mass: f32,
    reference_energy_j: f32,
    geometry_coeff: f32,
    rigidity_coeff: f32,
};

pub const GeneratedWeapons = [_]WeaponDefinition{ ... };
```

### 3. Loader (`weapon_list.zig`)

Transform to follow `armour_list.zig` pattern:

```zig
//! Weapon definitions - data-driven weapon templates loaded from CUE.

const std = @import("std");
const generated = @import("../gen/generated_data.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const damage = @import("damage.zig");

// Re-export generated definition types
pub const WeaponDef = generated.WeaponDefinition;
pub const OffensiveDef = generated.OffensiveProfileDefinition;
pub const DefensiveDef = generated.DefensiveProfileDefinition;

// Re-export generated table
pub const weapon_defs = generated.GeneratedWeapons;

// Runtime types
pub const Template = weapon.Template;
pub const Offensive = weapon.Offensive;
pub const Defensive = weapon.Defensive;

/// Build runtime Offensive from generated definition.
fn buildOffensive(comptime def: *const OffensiveDef) Offensive {
    return .{
        .name = def.name,
        .reach = def.reach,
        .damage_types = def.damage_types,
        .accuracy = def.accuracy,
        .speed = def.speed,
        .damage = def.damage,
        .penetration = def.penetration,
        .penetration_max = def.penetration_max,
        .fragility = def.fragility,
        .defender_modifiers = .{
            .reach = def.defender_modifiers.reach,
            .parry = def.defender_modifiers.parry,
            .deflect = def.defender_modifiers.deflect,
            .block = def.defender_modifiers.block,
            .fragility = def.defender_modifiers.fragility,
        },
    };
}

/// Build runtime Defensive from generated definition.
fn buildDefensive(comptime def: *const DefensiveDef) Defensive {
    return .{
        .name = def.name,
        .reach = def.reach,
        .parry = def.parry,
        .deflect = def.deflect,
        .block = def.block,
        .fragility = def.fragility,
    };
}

/// Build runtime Template from generated definition.
pub fn buildTemplate(comptime def: *const WeaponDef) Template {
    return .{
        .name = def.name,
        .categories = def.categories,
        .features = def.features,
        .grip = def.grip,
        .length = def.length,
        .weight = def.weight,
        .balance = def.balance,
        .swing = if (def.swing) |s| buildOffensive(&s) else null,
        .thrust = if (def.thrust) |t| buildOffensive(&t) else null,
        .defence = buildDefensive(&def.defence),
        .ranged = null, // TODO: wire up when CUE schema supports it
        .integrity = def.integrity,
        .moment_of_inertia = def.moment_of_inertia,
        .effective_mass = def.effective_mass,
        .reference_energy_j = def.reference_energy_j,
        .geometry_coeff = def.geometry_coeff,
        .rigidity_coeff = def.rigidity_coeff,
    };
}

/// Comptime-built runtime templates.
pub const Templates = blk: {
    var tmpls: [weapon_defs.len]Template = undefined;
    for (&weapon_defs, 0..) |*def, i| {
        tmpls[i] = buildTemplate(def);
    }
    break :blk tmpls;
};

/// Look up a runtime template by CUE ID (e.g., "swords.knights_sword").
pub fn getTemplate(comptime id: []const u8) *const Template {
    for (&Templates, 0..) |*tmpl, i| {
        if (std.mem.eql(u8, weapon_defs[i].id, id)) {
            return tmpl;
        }
    }
    @compileError("Unknown weapon ID: '" ++ id ++ "'");
}

/// Runtime lookup by string ID.
pub fn getTemplateRuntime(id: []const u8) ?*const Template {
    for (&weapon_defs, 0..) |*def, i| {
        if (std.mem.eql(u8, def.id, id)) {
            return &Templates[i];
        }
    }
    return null;
}

// Legacy compatibility: named exports for existing code
pub const knights_sword = getTemplate("swords.knights_sword");
pub const horsemans_mace = getTemplate("maces.horsemans_mace");
// ... etc for all 9 weapons
```

### 4. Data Migration

Port all 9 weapons from `weapon_list.zig` to `data/weapons.cue`:

| weapon_list.zig | CUE ID |
|-----------------|--------|
| horsemans_mace | maces.horsemans_mace |
| footmans_axe | axes.footmans_axe |
| greataxe | axes.greataxe |
| knights_sword | swords.knights_sword |
| falchion | swords.falchion |
| dirk | daggers.dirk |
| spear | polearms.spear |
| buckler | shields.buckler |
| fist_stone | improvised.fist_stone |

Existing `swords.knights_sword` and `improvised.fist_stone` already have physics; extend them with combat profiles. Others need full definitions.

### 5. Test Cleanup

Remove `lookupWeaponById()` mapping from `data_driven_combat.zig`. Replace with direct calls:

```zig
// Before:
const template = lookupWeaponById(attacker.weapon_id) orelse {
    reporter.addResult(test_def.id, .skip, "Unknown weapon", ...);
    continue;
};

// After:
const template = weapon_list.getTemplateRuntime(attacker.weapon_id) orelse {
    reporter.addResult(test_def.id, .skip, "Unknown weapon", ...);
    continue;
};
```

### 6. Backward Compatibility

Existing code referencing `weapon_list.knights_sword` etc. continues to work via the named exports. Gradually migrate callers to use `weapon_list.getTemplate("swords.knights_sword")` for consistency with the data-driven pattern.

## Implementation Sequence

1. **Extend CUE schema** - Add #OffensiveProfile, #DefensiveProfile, etc.
2. **Update generator** - New emit functions for full weapon structs
3. **Migrate one weapon** - Port `knights_sword` fully to CUE, verify generation
4. **Update weapon_list.zig** - Transform to loader pattern
5. **Migrate remaining weapons** - Port all 9 to CUE
6. **Update data_driven_combat.zig** - Remove mapping, use `getTemplateRuntime`
7. **Run full test suite** - Verify no regressions
8. **Update audit report** - Ensure new weapon fields are validated

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| CUE schema errors | Incremental migration, validate each weapon |
| Generator complexity | Follow existing patterns (techniques, armour) |
| Comptime issues | Test with `just check` after each change |
| Test regressions | Run `just test-combat` throughout |

## Non-Goals

- Changing weapon logic or combat resolution
- Redesigning combat profiles (just migrate data)

## Checklist

- [x] CUE schema extended with combat profiles
- [x] Generator emits full WeaponDefinition
- [x] weapon_list.zig converted to loader pattern
- [x] All 12 weapons migrated to CUE (9 original + 3 natural)
- [x] data_driven_combat.zig mapping removed
- [x] All tests pass
- [ ] Audit report updated (optional follow-up)
