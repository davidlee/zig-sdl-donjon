# Blood & Bleeding System

> **Status**: Implemented (core). 2026-01-08.

## Overview

Blood is modelled as a finite resource that drains through wounds. Unlike stamina/focus, blood does not regenerate during combat. Severe blood loss triggers computed conditions that impair the agent.

## Data Model

### Agent

```zig
blood: stats.Resource,  // init(5.0, 5.0, 0.0) for humanoids
```

- `current`: actual blood volume (litres)
- `max`: species-dependent capacity (human ~5L, dwarf ~4L, buffalo ~30L)
- `per_turn`: 0 in combat (no natural recovery)

### Wound

```zig
bleeding_rate: f32 = 0.0,  // litres per tick
```

Set when wound is created based on:
- **Damage type**: slash (1.0x), pierce (0.6x), bludgeon (0.2x)
- **Severity**: minor (0.2x) → broken (1.0x)
- **Artery hit**: 5x multiplier

A severe arterial slash bleeds ~0.5L/tick. Untreated, fatal in ~10 ticks.

## Mechanics

### Per-Tick Update

`Agent.tick()` performs:
1. Sum `bleeding_rate` across all wounds on all body parts
2. Drain that amount from `blood.current`
3. Tick stamina/focus recovery

Called from combat pipeline (end of each tick) or world simulation.

### Computed Conditions

`ConditionIterator` yields blood loss conditions based on `blood.current / blood.max`:

| Ratio | Condition | Effect |
|-------|-----------|--------|
| < 80% | `lightheaded` | Minor impairment |
| < 60% | `bleeding_out` | Serious impairment |
| < 40% | `hypovolemic_shock` | Critical, near incapacitation |

Conditions are checked worst-first; only the most severe applies.

### Bleeding Rate Calculation

```zig
fn calculateBleedingRate(wound, hit_artery) f32 {
    type_factor = switch (wound.kind) {
        .slash => 1.0,
        .pierce => 0.6,
        .bludgeon, .crush => 0.2,
        .shatter => 0.3,
        else => 0.1,
    };

    severity_factor = switch (wound.worstSeverity()) {
        .minor => 0.2,
        .inhibited => 0.5,
        .disabled => 0.8,
        .broken => 1.0,
        .missing => 0.5,  // severed = less connected
    };

    artery_mult = if (hit_artery) 5.0 else 1.0;

    return 0.1 * type_factor * severity_factor * artery_mult;
}
```

## Integration Points

### Combat Pipeline

Wire `agent.tick()` at end of each combat tick for all agents.

### Body Damage

`Body.applyDamageToPart()` automatically sets `wound.bleeding_rate` based on the damage characteristics and whether a major artery was hit.

### UI

Consider displaying:
- Blood level bar (like stamina/focus)
- Bleeding indicator when `totalBleedingRate() > 0`
- Condition icons for blood loss states

## Future Work

- **Treatment**: Bandaging/healing to reduce `bleeding_rate` on wounds
- **Unconscious/Death**: Trigger at very low blood (< 20%?)
- **Infection**: Untreated wounds may develop sepsis over time
- **Recovery**: Out-of-combat blood regeneration (slow, requires rest/food)
- **Species variation**: Blood volume from body plan rather than hardcoded

## Related

- [Timing, Simultaneity, Positioning](timing_simultaneity_positioning.md) - Combat tick structure
- `src/domain/combat/agent.zig` - Agent.tick(), ConditionIterator
- `src/domain/body.zig` - Wound, calculateBleedingRate
- `src/domain/damage.zig` - Condition enum
