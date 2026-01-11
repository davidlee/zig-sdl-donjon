# Contested Roll Resolution

> Revision: 2026-01-11. Detailed specification for contested roll combat resolution.
> Background: [contested_rolls_and_stance_triangle.md](contested_rolls_and_stance_triangle.md)

## Goals

1. Replace single hit-chance roll with attacker-vs-defender contest
2. Integrate stance triangle weights into resolution
3. Unify attack/defense and movement contests under same formula
4. Preserve rollback path via configurable roll mode
5. All tuning constants centralized in `tuning.zig` with documentation

## Non-Goals (v1)

- Data-driven stat weights on techniques (design allows, defer implementation)
- Armour gap interaction with margin
- Combat log presentation overhaul
- AI stance strategy (random for now)

## Contest Formula

All contests (attack/defense, movement) use the same structure:

```
raw_score = base + Σ(factors)
score = raw_score × condition_mult(agent)
final = score + ((roll + calibration) × variance × stance_weight)
margin = aggressor_final - defender_final
```

### Roll Mechanics

| Constant | Type | Default | Effect |
|----------|------|---------|--------|
| `contested_roll_variance` | f32 | 1.0 | Scales randomness magnitude |
| `contested_roll_calibration` | f32 | 0.0 | Shifts roll center (-0.5 = centered) |
| `contested_roll_mode` | enum | `.independent_pair` | Single roll (linear %) or two rolls (triangular distribution) |

Single roll mode:
- One draw, used for both sides
- Linear outcome distribution
- Can present as percentage in logs
- **Rollback path** to current-like behavior

Independent pair mode:
- Each side draws separately
- Triangular distribution (regression to mean)
- Skill dominates luck
- Cannot present as simple percentage

## Attack Score

```
raw_attack_score = attack_score_base
                 + technique.accuracy
                 - technique.difficulty
                 + weapon.offensive.accuracy
                 + stakes.bonus
                 + engagement_advantage
                 + attacker_balance_contribution
                 - simultaneous_defense_penalty (if defending same slice)

attack_score = raw_attack_score × condition_mult(attacker)
```

## Defense Score

```
raw_defense_score = defense_score_base
                  + active_technique_bonus (if any)
                  + weapon.defensive.parry × parry_scaling
                  + movement_technique_bonus
                  + engagement_advantage
                  + defender_balance_contribution

defense_score = raw_defense_score × condition_mult(defender)
```

### Parry Scaling

| Defender's weapon channel | `parry_scaling` |
|---------------------------|-----------------|
| Active defense (parry/block/deflect) | 1.0 |
| Idle (no weapon technique) | `passive_weapon_defense_mult` |
| Attacking | `offensive_committed_defense_mult` |

### Score Constants

| Constant | Default | Purpose |
|----------|---------|---------|
| `attack_score_base` | TBD | Baseline attack score |
| `defense_score_base` | TBD | Baseline defense score |
| `passive_weapon_defense_mult` | 0.5 | Weapon parry when idle |
| `offensive_committed_defense_mult` | 0.25 | Weapon parry when attacking |
| `simultaneous_defense_attack_penalty` | TBD | Attack penalty when also defending |

## Movement Score

Same formula shape, both contestants use `stance.movement`:

```
raw_movement_score = movement_score_base
                   + speed × technique.movement_stats.speed
                   + position × technique.movement_stats.position
                   + balance × technique.movement_stats.balance
                   + footwork_technique_bonus
                   - standing_still_penalty (if holding position)

movement_score = raw_movement_score × condition_mult(agent)
```

### Default Stat Weights

When technique doesn't specify `movement_stats`, use primary stat parameterization:

| Constant | Type | Default | Purpose |
|----------|------|---------|---------|
| `movement_primary_stat` | enum | `.speed` | Which stat dominates by default |
| `movement_primary_weight` | f32 | 0.4 | Weight for primary stat |

Secondary stats split the remainder evenly: `(1.0 - primary_weight) / 2`.

Additional constants:

| Constant | Default | Purpose |
|----------|---------|---------|
| `movement_score_base` | TBD | Baseline movement score |
| `standing_still_penalty` | 0.3 | Penalty for holding position |

### Technique-Specified Weights (Future)

Techniques may override default weights:

```cue
advance: {
  movement_stats: { speed: 0.6, position: 0.2, balance: 0.2 }
}
dodge: {
  movement_stats: { speed: 0.2, position: 0.4, balance: 0.4 }
}
```

## Outcome Interpretation

### Margin Thresholds

| Margin | Outcome | Damage Effect |
|--------|---------|---------------|
| >= `hit_margin_critical` | Critical hit | x `critical_hit_damage_mult` |
| >= `hit_margin_solid` | Solid hit | x 1.0 (full) |
| >= 0 | Partial hit | x `partial_hit_damage_mult` |
| < 0 | Miss | No damage |

### Outcome Constants

| Constant | Default | Purpose |
|----------|---------|---------|
| `hit_margin_critical` | 0.4 | Threshold for critical |
| `hit_margin_solid` | 0.2 | Threshold for solid hit |
| `partial_hit_damage_mult` | TBD | Damage scaling for partial hits |
| `critical_hit_damage_mult` | TBD | Damage bonus for criticals |

### Movement Outcomes

Same structure - positive margin = aggressor succeeds, magnitude determines decisiveness. Specific thresholds TBD (may differ from combat).

### Design Note: Armour Gap

Future consideration: critical hits could improve armour gap chance. Out of scope for v1.

## Condition Multiplier

Both attack and defense scores apply conditions multiplicatively via a shared function:

```zig
/// Returns multiplicative modifier for combat effectiveness based on agent conditions.
/// Values < 1.0 reduce effectiveness, > 1.0 enhance.
/// Used identically for attack and defense score calculation.
pub fn conditionCombatMult(agent: *const Agent) f32 {
    var mult: f32 = 1.0;

    // Negative conditions reduce effectiveness
    if (agent.hasCondition(.winded)) mult *= winded_combat_mult;
    if (agent.hasCondition(.stunned)) mult *= stunned_combat_mult;
    if (agent.hasCondition(.off_balance)) mult *= off_balance_combat_mult;

    // Positive conditions enhance effectiveness
    if (agent.hasCondition(.focused)) mult *= focused_combat_mult;
    if (agent.hasCondition(.adrenaline)) mult *= adrenaline_combat_mult;

    return mult;
}
```

### Condition Constants

| Constant | Default | Purpose |
|----------|---------|---------|
| `winded_combat_mult` | TBD | Fatigue penalty |
| `stunned_combat_mult` | TBD | Stun penalty |
| `off_balance_combat_mult` | TBD | Balance penalty |
| `focused_combat_mult` | TBD | Focus bonus |
| `adrenaline_combat_mult` | TBD | Adrenaline bonus |

Condition list non-exhaustive - extend as conditions are added.

## Stance Integration

Stance weights (from triangle UI) feed directly into contest variance:

```
attack_final = attack_score + ((roll + calibration) × variance × stance.attack)
defense_final = defense_score + ((roll + calibration) × variance × stance.defense)
movement_final = movement_score + ((roll + calibration) × variance × stance.movement)
```

### Effect of Stance Commitment

| Stance | attack | defense | movement | Effect |
|--------|--------|---------|----------|--------|
| Balanced | 0.33 | 0.33 | 0.33 | Moderate variance all contests |
| Pure attack | 1.0 | 0.0 | 0.0 | High attack variance, defense deterministic |
| Pure defense | 0.0 | 1.0 | 0.0 | Defense swingy, attack deterministic |
| Pure movement | 0.0 | 0.0 | 1.0 | Movement swingy, combat deterministic |

High stance weight = more variance = more luck influence = higher ceiling and lower floor.

Low stance weight = deterministic = outcome dominated by raw score.

### AI Stance Selection

For v1: random selection (uniform within triangle).

Future consideration: personality-weighted selection (aggressive NPCs bias toward attack vertex).

## Open Items & Future Work

### Combat Log Presentation

**TODO:** Logs currently show single percentage. Contested rolls need different presentation:

Single roll mode:
```
Dwarf swings at Goblin (62% -> 71 rolled) - Solid hit
```

Independent pair mode:
```
Dwarf swings at Goblin
  Attack: 0.65 -> 0.78 | Defense: 0.48 -> 0.52
  Margin: +0.26 - Solid hit
```

Details deferred to implementation.

### Data-Driven Stat Weights

Future enhancement: techniques specify which agent stats contribute to their contest scores.

```cue
thrust: {
  attack_stats: { accuracy: 0.5, speed: 0.3, perception: 0.2 }
}
power_strike: {
  attack_stats: { strength: 0.6, balance: 0.4 }
}
```

Default weights used when technique doesn't specify. Same pattern as movement stats.

### Armour Gap Interaction

Design note: critical hit margin could improve armour gap chance (finding weak spots). Requires linking margin into `armour.zig` gap roll. Defer to future work.

### Rollback Strategy

The `contested_roll_mode` constant provides the escape hatch:
- `.single` - closer to current single-roll behavior, linear distribution
- `.independent_pair` - full contested system

If playtesting reveals contested rolls don't feel right, switch mode without rewriting formula.

## Constants Summary

All tuning constants for `tuning.zig`, grouped by subsystem:

### Roll Mechanics

| Constant | Type | Default |
|----------|------|---------|
| `contested_roll_variance` | f32 | 1.0 |
| `contested_roll_calibration` | f32 | 0.0 |
| `contested_roll_mode` | enum | `.independent_pair` |

### Score Bases

| Constant | Type | Default |
|----------|------|---------|
| `attack_score_base` | f32 | TBD |
| `defense_score_base` | f32 | TBD |
| `movement_score_base` | f32 | TBD |

### Defense Scaling

| Constant | Type | Default |
|----------|------|---------|
| `passive_weapon_defense_mult` | f32 | 0.5 |
| `offensive_committed_defense_mult` | f32 | 0.25 |
| `simultaneous_defense_attack_penalty` | f32 | TBD |

### Movement Defaults

| Constant | Type | Default |
|----------|------|---------|
| `movement_primary_stat` | enum | `.speed` |
| `movement_primary_weight` | f32 | 0.4 |
| `standing_still_penalty` | f32 | 0.3 |

### Outcome Thresholds

| Constant | Type | Default |
|----------|------|---------|
| `hit_margin_critical` | f32 | 0.4 |
| `hit_margin_solid` | f32 | 0.2 |
| `partial_hit_damage_mult` | f32 | TBD |
| `critical_hit_damage_mult` | f32 | TBD |

### Condition Multipliers

| Constant | Type | Default |
|----------|------|---------|
| `winded_combat_mult` | f32 | TBD |
| `stunned_combat_mult` | f32 | TBD |
| `off_balance_combat_mult` | f32 | TBD |
| `focused_combat_mult` | f32 | TBD |
| `adrenaline_combat_mult` | f32 | TBD |
