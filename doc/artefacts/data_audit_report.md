# Data Audit Report

Generated: 2026-01-10 18:36:49

## Summary

| Dataset | Total | With Warnings | With Errors |
|---------|-------|---------------|-------------|
| armour_materials | 3 | 0 | 0 |
| armour_pieces | 2 | 0 | 0 |
| body_plans | 1 | 0 | 0 |
| techniques | 14 | 14 | 0 |
| tissue_templates | 6 | 0 | 0 |
| weapons | 12 | 0 | 0 |

**STATUS: PASSED with warnings** - 14 warning(s)

## Weapons

### Valid Entries

| ID | MoI | Eff.Mass | RefEnergy | Geometry | Rigidity |
|----|-----|----------|-----------|----------|----------|
| swords.knights_sword | 0.593 | 1.40 | 10.7 | 0.60 | 0.70 |
| swords.falchion | 0.210 | 1.30 | 3.7 | 0.55 | 0.70 |
| maces.horsemans_mace | 0.210 | 1.20 | 3.8 | 0.20 | 0.80 |
| axes.footmans_axe | 0.570 | 1.80 | 10.3 | 0.60 | 0.65 |
| axes.greataxe | 4.390 | 3.50 | 79.0 | 0.55 | 0.60 |
| daggers.dirk | 0.003 | 0.40 | 0.1 | 0.70 | 0.60 |
| polearms.spear | 2.880 | 2.00 | 9.0 | 0.75 | 0.50 |
| shields.buckler | 0.046 | 1.50 | 0.8 | 0.10 | 0.80 |
| improvised.fist_stone | 0.002 | 0.50 | 0.0 | 0.25 | 0.40 |
| natural.fist | 0.002 | 0.50 | 0.5 | 0.15 | 0.30 |
| natural.bite | 0.001 | 0.30 | 0.3 | 0.45 | 0.45 |
| natural.headbutt | 0.006 | 1.00 | 1.0 | 0.10 | 0.50 |

## Techniques

### Issues

#### `thrust`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: thrust
  attack_mode: thrust
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'weapon': True}
```

#### `swing`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: swing
  attack_mode: swing
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'weapon': True}
```

#### `throw`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: throw
  attack_mode: ranged
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'weapon': True}
```

#### `block`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: block
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'off_hand': True}
```

#### `riposte`

- WARNING: axis_bias.rigidity_mult not set (default 1.0)

Fields:
```
  name: riposte
  attack_mode: thrust
  axis_geometry_mult: 1.1
  axis_energy_mult: 0.9
  axis_rigidity_mult: 1.0
  channels: {'weapon': True}
```

#### `deflect`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: deflect
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'weapon': True}
```

#### `parry`

- WARNING: axis_bias.geometry_mult not set (default 1.0)
- WARNING: axis_bias.energy_mult not set (default 1.0)

Fields:
```
  name: parry
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.1
  channels: {'weapon': True}
```

#### `advance`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: advance
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'footwork': True}
```

#### `retreat`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: retreat
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'footwork': True}
```

#### `sidestep`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: sidestep
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'footwork': True}
```

#### `hold`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: hold
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'footwork': True}
```

#### `circle`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: circle
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'footwork': True}
```

#### `disengage`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: disengage
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'footwork': True}
```

#### `pivot`

- WARNING: axis_bias not defined (using defaults)

Fields:
```
  name: pivot
  attack_mode: none
  axis_geometry_mult: 1.0
  axis_energy_mult: 1.0
  axis_rigidity_mult: 1.0
  channels: {'footwork': True}
```

## Armour Materials

### Valid Entries

| ID | Defl | Abs | Disp | GeoThr | EnerThr | RigThr |
|----|------|-----|------|--------|---------|--------|
| chainmail | 0.55 | 0.30 | 0.20 | 0.1 | 0.2 | 0.2 |
| gambeson | 0.20 | 0.65 | 0.40 | 0.1 | 0.1 | 0.1 |
| steel_plate | 0.85 | 0.25 | 0.35 | 0.3 | 0.5 | 0.5 |

## Armour Pieces

### Valid Entries

| ID | Material | Coverage Count |
|----|----------|----------------|
| gambeson_jacket | gambeson | 1 |
| steel_breastplate | steel_plate | 1 |

## Tissue Templates

### Valid Entries

| ID | Layers | Thickness Sum |
|----|--------|---------------|
| limb | 6 | 1.000 |
| digit | 5 | 1.000 |
| joint | 5 | 1.000 |
| facial | 4 | 1.000 |
| organ | 1 | 1.000 |
| core | 5 | 1.000 |

## Body Plans

### Valid Entries

| ID | Parts | Height | Mass |
|----|-------|--------|------|
| humanoid | 62 | 175cm | 80.0kg |

