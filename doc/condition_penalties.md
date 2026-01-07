# Condition Penalties System

> **Status**: Design draft. 2026-01-08.

## Problem Statement

Combat modifiers from conditions are currently hardcoded as switch statements in `CombatModifiers.forAttacker` and `CombatModifiers.forDefender`. Each condition requires explicit handling, and adding new conditions or modifier axes requires code changes in multiple places.

Additionally:
- Blood loss conditions (`lightheaded`, `bleeding_out`, `hypovolemic_shock`) exist but have no combat penalties
- Wound severity on body parts doesn't affect combat ability
- No trauma/shock mechanic for psychological impact of wounds

## Goals

1. **Data-driven**: Condition effects defined declaratively, not in switch statements
2. **Single source of truth**: All condition modifiers in one place
3. **Extensible**: New conditions/modifiers don't require code changes in resolution
4. **Composable**: Multiple conditions combine predictably
5. **Generalizable**: Same pattern works for conditions, wounds, equipment, etc.

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

Body part wounds contribute penalties based on:
- Which part is wounded (arm affects attacks, leg affects mobility)
- Severity of damage (integrity: 1.0 → 0.6 → 0.3 → 0.1)

```zig
pub fn woundPenalties(agent: *const Agent) CombatPenalties {
    var penalties = CombatPenalties{};

    // Weapon arm integrity affects offense
    const weapon_arm = agent.body.partByTag(.arm, agent.dominant_side);
    if (weapon_arm) |arm| {
        const integrity = arm.severity.toIntegrity();
        if (integrity < 1.0) {
            penalties.hit_chance += (1.0 - integrity) * -0.25;
            penalties.damage_mult *= 0.5 + (integrity * 0.5);
        }
    }

    // Leg integrity affects mobility
    const avg_leg_integrity = agent.body.avgIntegrityForTag(.leg);
    if (avg_leg_integrity < 1.0) {
        penalties.dodge_mod += (1.0 - avg_leg_integrity) * -0.30;
        penalties.footwork_mult *= avg_leg_integrity;
    }

    return penalties;
}
```

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
2. **resolution/context.zig**: Replace switch statements with table lookup + combine
3. **body.zig**: Add `woundPenalties()` helper
4. **combat/agent.zig**: Add trauma resource, computed trauma conditions
5. **cards.zig**: Effects can modify trauma (`modify_trauma: f32`)

## Open Questions

1. **Attack mode sensitivity**: Some conditions affect thrust more than swing (blinded). Handle via separate fields or attack-mode multipliers on the penalty?

2. **Context-dependent penalties**: Winded hurts power attacks more. Embed this in the penalty table or keep some switch logic?

3. **Stacking limits**: Should multiplicative penalties have a floor (e.g., never below 0.1x)?

4. **Flanking/surrounded**: Currently special-cased in `forDefender`. Move to computed conditions with penalties?

## Related

- [Blood & Bleeding System](blood.md) - Blood loss conditions
- `src/domain/resolution/context.zig` - Current modifier implementation
- `src/domain/damage.zig` - Condition enum
