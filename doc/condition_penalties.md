# Condition Penalties System

> **Status**: Phase 1 implemented. 2026-01-08.

## Current Implementation

**`src/domain/damage.zig`**:
- `CombatPenalties` struct: `hit_chance`, `damage_mult`, `defense_mult`, `dodge_mod`, `footwork_mult`
- `combine()` method: additive fields sum, multiplicative fields compound
- `condition_penalties` comptime table indexed by `@intFromEnum(Condition)`
- `penaltiesFor(condition)` convenience lookup

**`src/domain/resolution/context.zig`**:
- `forAttacker`: iterates conditions, combines penalties from table
- `forDefender`: same pattern
- Special cases kept inline: `blinded` (attack-mode dependent), `winded` (stakes dependent), `stationary`/`flanking` (computed state)

**Conditions with penalties**:
- Physical: `stunned`, `prone`, `unbalanced`
- Mental: `confused`, `shaken`, `fearful`
- Incapacitation: `paralysed`, `surprised`, `unconscious`, `comatose`
- Engagement: `pressured`, `weapon_bound`
- Blood loss: `lightheaded`, `bleeding_out`, `hypovolemic_shock` ✓ (newly added!)

## Problem Statement

Combat modifiers from conditions were hardcoded as switch statements in `CombatModifiers.forAttacker` and `CombatModifiers.forDefender`. Each condition required explicit handling, and adding new conditions or modifier axes required code changes in multiple places.

Additionally:
- ~~Blood loss conditions (`lightheaded`, `bleeding_out`, `hypovolemic_shock`) exist but have no combat penalties~~ ✓ Fixed
- Wound severity on body parts doesn't affect combat ability
- No trauma/shock mechanic for psychological impact of wounds

## Goals

1. **Data-driven**: Condition effects defined declaratively, not in switch statements
2. **Single source of truth**: All condition modifiers in one place
3. **Extensible**: New conditions/modifiers don't require code changes in resolution
4. **Composable**: Multiple conditions combine predictably
5. **Generalizable**: Same pattern works for conditions, wounds, equipment, etc.

## Design Principle: Reuse Body Primitives

`body.zig` already provides capability queries via `PartDef.Flags` (`can_grasp`, `can_stand`, `can_see`, `can_hear`) and helper methods:

| Method | Flag | Returns |
|--------|------|---------|
| `graspStrength(part_idx)` | `can_grasp` | Integrity × (functional children / total) |
| `mobilityScore()` | `can_stand` | Average effective integrity |
| `visionScore()` (to add) | `can_see` | Average effective integrity |
| `hearingScore()` (to add) | `can_hear` | Average effective integrity |

**Do not invent parallel capability tracking.** Wound penalties, computed conditions (`.blinded`, `.deafened`), and equipment requirements should call into these existing primitives.

## Proposed Design

### Modifier Struct

```zig
pub const CombatPenalties = struct {
    // Offensive
    hit_chance: f32 = 0,       // additive: -0.15 = 15% less likely to hit
    damage_mult: f32 = 1.0,    // multiplicative: 0.8 = 80% damage

    // Defensive
    defense_mult: f32 = 1.0,   // active defense effectiveness
    dodge_mod: f32 = 0,        // passive evasion modifier

    // Mobility
    footwork_mult: f32 = 1.0,  // manoeuvre score multiplier

    // Resource
    stamina_cost_mult: f32 = 1.0,  // actions cost more when impaired

    /// Combine two penalty sets (additive stack, multiplicative compound)
    pub fn combine(self: CombatPenalties, other: CombatPenalties) CombatPenalties {
        return .{
            .hit_chance = self.hit_chance + other.hit_chance,
            .damage_mult = self.damage_mult * other.damage_mult,
            .defense_mult = self.defense_mult * other.defense_mult,
            .dodge_mod = self.dodge_mod + other.dodge_mod,
            .footwork_mult = self.footwork_mult * other.footwork_mult,
            .stamina_cost_mult = self.stamina_cost_mult * other.stamina_cost_mult,
        };
    }

    pub const none = CombatPenalties{};
};
```

### Condition Penalty Table

```zig
// Indexed by @intFromEnum(Condition) for O(1) lookup
pub const condition_penalties = init: {
    var table: [condition_count]CombatPenalties = undefined;
    for (&table) |*p| p.* = .{};  // default: no penalty

    // Sensory
    table[@intFromEnum(.blinded)] = .{
        .hit_chance = -0.25,
        .defense_mult = 0.6,
        .dodge_mod = -0.20
    };

    // Physical impairment
    table[@intFromEnum(.stunned)] = .{
        .hit_chance = -0.20,
        .damage_mult = 0.7,
        .defense_mult = 0.3,
        .dodge_mod = -0.30
    };
    table[@intFromEnum(.prone)] = .{
        .hit_chance = -0.15,
        .damage_mult = 0.8,
        .dodge_mod = -0.25
    };
    table[@intFromEnum(.winded)] = .{
        .damage_mult = 0.85,
        .stamina_cost_mult = 1.3
    };
    table[@intFromEnum(.unbalanced)] = .{
        .hit_chance = -0.10,
        .dodge_mod = -0.15
    };

    // Mental
    table[@intFromEnum(.confused)] = .{ .hit_chance = -0.15 };
    table[@intFromEnum(.shaken)] = .{ .hit_chance = -0.10, .damage_mult = 0.9 };
    table[@intFromEnum(.fearful)] = .{ .hit_chance = -0.10, .damage_mult = 0.9 };

    // Incapacitation
    table[@intFromEnum(.paralysed)] = .{
        .defense_mult = 0.0,
        .dodge_mod = -0.40
    };
    table[@intFromEnum(.unconscious)] = .{
        .defense_mult = 0.0,
        .dodge_mod = -0.50
    };

    // Engagement pressure
    table[@intFromEnum(.pressured)] = .{ .defense_mult = 0.85 };
    table[@intFromEnum(.weapon_bound)] = .{ .defense_mult = 0.7 };

    // Blood loss
    table[@intFromEnum(.lightheaded)] = .{
        .hit_chance = -0.05,
        .damage_mult = 0.9
    };
    table[@intFromEnum(.bleeding_out)] = .{
        .hit_chance = -0.15,
        .damage_mult = 0.8,
        .defense_mult = 0.9
    };
    table[@intFromEnum(.hypovolemic_shock)] = .{
        .hit_chance = -0.30,
        .damage_mult = 0.6,
        .defense_mult = 0.75,
        .dodge_mod = -0.20,
        .footwork_mult = 0.5
    };

    break :init table;
};
```

### Application in Combat Resolution

```zig
// In CombatModifiers.forAttacker - replaces switch statement
pub fn forAttacker(attack: AttackContext) CombatModifiers {
    var penalties = CombatPenalties{};

    var iter = attack.attacker.activeConditions(attack.engagement);
    while (iter.next()) |cond| {
        penalties = penalties.combine(condition_penalties[@intFromEnum(cond.condition)]);
    }

    return .{
        .hit_chance = penalties.hit_chance - attack.attention_penalty,
        .damage_mult = penalties.damage_mult,
    };
}
```

## Extension: Wound Penalties

> **Design Principle**: Use existing `Body` capability primitives. Do not add parallel capability tracking.

Body part wounds contribute penalties via existing helpers in `body.zig`:

| Primitive | Flag | Purpose |
|-----------|------|---------|
| `graspStrength(part_idx)` | `can_grasp` | Part integrity × (functional children / total children) |
| `mobilityScore()` | `can_stand` | Average effective integrity of standing parts |
| `visionScore()` | `can_see` | Average effective integrity of visual parts (to add) |
| `hearingScore()` | `can_hear` | Average effective integrity of auditory parts (to add) |

These primitives already handle:
- Effective integrity propagation (severing, parent chain)
- Child contribution (fingers → hand grasp strength)
- Flag-based part selection

```zig
pub fn woundPenalties(body: *const Body, weapon_hand_idx: PartIndex) CombatPenalties {
    var penalties = CombatPenalties{};

    // Grasping ability affects offense (hand integrity + finger contribution)
    const grasp = body.graspStrength(weapon_hand_idx);
    if (grasp < 1.0) {
        penalties.hit_chance += (1.0 - grasp) * -0.25;
        penalties.damage_mult *= 0.5 + (grasp * 0.5);
    }

    // Standing ability affects footwork (averages leg/foot integrity)
    const mobility = body.mobilityScore();
    if (mobility < 1.0) {
        penalties.dodge_mod += (1.0 - mobility) * -0.30;
        penalties.footwork_mult *= mobility;
    }

    return penalties;
}
```

### Sensory Scores (to add to Body)

Following the `mobilityScore()` pattern:

```zig
pub fn visionScore(self: *const Body) f32 {
    // Average effective integrity of can_see parts (eyes)
    // Returns 0..1; used to derive .blinded condition threshold
}

pub fn hearingScore(self: *const Body) f32 {
    // Average effective integrity of can_hear parts (ears)
    // Returns 0..1; used to derive .deafened condition threshold
}
```

Computed conditions in `ConditionIterator` can then yield `.blinded` when `visionScore() < threshold` rather than duplicating sensor logic.

## Extension: Trauma Resource

Trauma accumulates from psychological shock and doesn't regenerate in combat.

```zig
// In Agent
trauma: stats.Resource,  // init(0.0, 10.0, 0.0) - starts empty, no regen

// Trauma sources (in damage resolution)
fn traumaFromWound(wound: Wound, hit_artery: bool) f32 {
    var trauma: f32 = 0;

    // Severity contributes
    trauma += switch (wound.worstSeverity()) {
        .minor => 0.5,
        .inhibited => 1.0,
        .disabled => 2.0,
        .broken => 3.0,
        .missing => 5.0,  // losing a limb is traumatic
        .none => 0,
    };

    // Artery hit is shocking
    if (hit_artery) trauma += 2.0;

    return trauma;
}

// Computed conditions from trauma level
// < 30% capacity: shaken
// < 60% capacity: fearful
// < 80% capacity: panicked (new condition)
```

## Integration Points

1. **damage.zig**: Define `CombatPenalties` struct and `condition_penalties` table
2. **resolution/context.zig**: Replace switch statements with table lookup + combine; call `body.graspStrength()`, `body.mobilityScore()` for wound penalties
3. **body.zig**: Add `visionScore()` and `hearingScore()` following `mobilityScore()` pattern
4. **combat/agent.zig**: Add trauma resource, computed trauma conditions
5. **cards.zig**: Effects can modify trauma (`modify_trauma: f32`)

## Open Questions

1. **Attack mode sensitivity**: `blinded` affects thrust more than swing (-30% vs -20% vs -45% ranged). Options:
   - Separate fields: `hit_thrust`, `hit_swing`, `hit_ranged`
   - Modifier function that takes attack context
   - Keep as special case outside table

2. **Context-dependent penalties**: `winded` only hurts committed/reckless stakes. Options:
   - Separate fields: `damage_mult_power` for power attacks
   - Keep as special case outside table

3. **Stacking limits**: Should multiplicative penalties have a floor (e.g., never below 0.1x)?

4. **Flanking/surrounded**: Currently computed from positioning state, not yielded by ConditionIterator. Options:
   - Move to computed conditions (phases in ConditionIterator)
   - Keep as separate combat state check

5. **Stationary**: Same as flanking - computed from timeline, not condition iterator.

## Implementation Notes

**Phase 1** ✓ Complete:
- `CombatPenalties` struct and `condition_penalties` table in `damage.zig`
- `forAttacker`/`forDefender` use table lookup + combine
- Blood loss conditions now have combat penalties

**Skipped (special cases remain inline)**:
- `blinded` (attack-mode dependent)
- `winded` (stakes dependent)
- `stationary`, `flanked`, `surrounded` (computed from combat state, not conditions)

**Phase 2** (future):
- Wound penalties via `body.graspStrength()` and `body.mobilityScore()`
- Add `body.visionScore()` and `body.hearingScore()` following same pattern
- Computed `.blinded`/`.deafened` from sensory scores in `ConditionIterator`
- Trauma resource and computed conditions

**Phase 3** (future):
- Resolve open questions about context-dependent modifiers
- Consider moving flanking/stationary to computed conditions

## Related

- [Blood & Bleeding System](blood.md) - Blood loss conditions
- `src/domain/resolution/context.zig` - Current modifier implementation
- `src/domain/damage.zig` - Condition enum
