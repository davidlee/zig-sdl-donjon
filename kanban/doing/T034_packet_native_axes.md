# T034: Packet-Native 3-Axis Derivation

Created: 2026-01-09

## Problem statement / value driver

Currently `resolveThroughArmour` derives axis values (geometry/momentum/rigidity) from packet fields within resolution. This works but means:
- Axis values aren't available to other systems (combat log, UI, conditions)
- Derivation logic is duplicated if other code needs axes
- Natural weapons use the same crude `deriveRigidity(kind)` as manufactured weapons

Moving axis derivation to `createDamagePacket` makes axes first-class citizens of the damage pipeline, enabling richer combat feedback and consistent physics across weapons, natural attacks, and future systems.

### Scope - goals

- Extend `damage.Packet` with geometry/momentum/rigidity fields
- Derive axes in `createDamagePacket` from weapon template + technique + grip
- Update `resolveThroughArmour` to use packet axes directly
- Add axis derivation for natural weapons (species data)

### Scope - non-goals

- Tissue/body 3-axis migration (separate task)
- Combat log/UI integration (can follow once axes are in packet)
- Grip system overhaul (use existing grip data)

## Background

### Relevant documents

- `doc/artefacts/geometry_momentum_rigidity_review.md` - design spec, especially §4 (weapon/technique interplay)
- `kanban/T033_armour_3axis_migration.md` - completed armour migration, Option B notes
- `doc/artefacts/data_generation_plan.md` - CUE→Zig pipeline

### Key files

- `src/domain/damage.zig` - Packet struct, Kind enum
- `src/domain/resolution/damage.zig` - `createDamagePacket` function
- `src/domain/weapon.zig` - weapon Template
- `src/domain/species.zig` - natural weapons
- `src/gen/generated_data.zig` - generated weapon data
- `data/weapons.cue`, `data/techniques.cue` - source definitions

### Existing systems

- CUE weapon schema already defines: `base_geometry`, `base_rigidity`, `moment_of_inertia`, `effective_mass`, `reference_energy`, `curvature`
- CUE techniques define `axis_bias` multipliers
- `deriveRigidity(kind)` in armour.zig provides fallback derivation from damage kind
- Memory: `weapons_system_overview` - current weapon architecture

## Changes Required

### Phase 1: Extend Packet

```zig
pub const Packet = struct {
    // Existing fields
    amount: f32,
    kind: Kind,
    penetration: f32,

    // 3-axis physics (Option B)
    geometry: f32 = 0,   // concentrated force along narrow contact
    momentum: f32 = 0,   // total energy in the attack
    rigidity: f32 = 0,   // structural support of striking surface
};
```

Default to 0 for backward compatibility - existing code creating packets without axes will still work (resolution falls back to derivation).

### Phase 2: Axis derivation formulas

From design doc §4:

**Geometry** (penetration efficiency):
```
geometry = weapon.base_geometry
         * technique.geometry_bias
         * grip.geometry_modifier
         + curvature_adjustment
```

**Momentum** (energy):
```
momentum = weapon.reference_energy
         * technique.power_scaling
         * stat_ratio
         * stakes_multiplier
```

**Rigidity** (structural support):
```
rigidity = weapon.base_rigidity
         * technique.rigidity_bias
         * grip.rigidity_modifier
```

For swings: energy = ½ I ω² (moment of inertia × angular velocity²)
For thrusts: energy = ½ m v² (effective mass × velocity²)

### Phase 3: Update createDamagePacket

Current signature (approx):
```zig
pub fn createDamagePacket(
    technique: *const Technique,
    weapon: *const weapon.Template,
    attacker: *const Agent,
    // ...
) Packet
```

Add axis derivation after computing amount/penetration:
```zig
return .{
    .amount = computed_amount,
    .kind = technique.damage_kind,
    .penetration = computed_penetration,
    .geometry = deriveGeometry(weapon, technique, grip),
    .momentum = computed_amount, // already have this
    .rigidity = deriveRigidity(weapon, technique, grip),
};
```

### Phase 4: Natural weapons

Species natural weapons need axis data. Options:
1. Add axis fields to `NaturalWeapon` struct
2. Derive from anatomical properties (jaw strength → rigidity, claw sharpness → geometry)

Prefer option 2 for consistency with the physics model.

### Phase 5: Update resolution

In `resolveThroughArmour`, change:
```zig
// Before (Option A - derive within resolution)
const geometry = remaining.penetration;
const momentum = remaining.amount;
const rigidity = deriveRigidity(remaining.kind);

// After (Option B - use packet axes)
const geometry = if (remaining.geometry > 0) remaining.geometry else remaining.penetration;
const momentum = if (remaining.momentum > 0) remaining.momentum else remaining.amount;
const rigidity = if (remaining.rigidity > 0) remaining.rigidity else deriveRigidity(remaining.kind);
```

Fallback ensures backward compatibility during transition.

### Challenges / Open Questions

1. **CUE data completeness**: Do all weapons have proper axis coefficients? Need audit.
2. **Technique axis_bias**: Currently in CUE but may not be wired to runtime.
3. **Grip modifiers**: Where do these live? weapon.zig? technique?
4. **Stat interaction**: How do attacker stats affect axes? (Power → momentum? Precision → geometry?)
5. **Attack mode**: Swing vs thrust affects energy calculation - is this technique-level or separate?

### Decisions (to be made)

- [ ] Stat-to-axis mapping
- [ ] Grip modifier source
- [ ] Natural weapon derivation approach

## Tasks / Sequence of Work

- [ ] **1.1** Add axis fields to `damage.Packet` with defaults
- [ ] **1.2** Audit CUE weapon data for axis coefficient completeness
- [ ] **2.1** Wire weapon axis data through generation pipeline to runtime
- [ ] **2.2** Wire technique axis_bias through generation pipeline
- [ ] **3.1** Implement `deriveGeometry(weapon, technique, grip)`
- [ ] **3.2** Implement `deriveRigidity(weapon, technique, grip)` (weapon-aware version)
- [ ] **3.3** Update `createDamagePacket` to populate axis fields
- [ ] **4.1** Add axis derivation for natural weapons
- [ ] **5.1** Update `resolveThroughArmour` to use packet axes with fallback
- [ ] **5.2** Remove `deriveRigidity(kind)` from armour.zig once all packets have axes

## Test / Verification Strategy

### Success criteria

- `just check` passes
- Packets created via `createDamagePacket` have populated axis fields
- Resolution uses packet axes when available, falls back when not
- Natural weapon attacks have sensible axis values

### Unit tests

- Axis derivation formulas produce expected values for known weapon/technique combos
- Packet with/without axes both resolve correctly
- Natural weapon axis derivation

### Integration tests

- Full combat flow: technique → packet with axes → armour resolution → wound
- Compare sword thrust vs hammer swing axis profiles

## Quality Concerns / Risks

- Formula tuning may require iteration for good gameplay feel
- Grip system may need expansion to support axis modifiers
- Stats integration could get complex

## Progress Log / Notes

**2026-01-09**: Task created as follow-up to T033 (armour 3-axis migration).
- Armour resolution now uses 3-axis internally (Option A complete)
- This task promotes axes to packet-level (Option B)
- CUE scaffolding for weapon axes exists but needs audit
