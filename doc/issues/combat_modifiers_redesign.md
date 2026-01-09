# Combat Modifiers Redesign

**Related**:
- `doc/artefacts/damage_lethality_analysis.md` (stakes section)
- `doc/issues/impulse_penetration_bite.md` (three-axis damage model - penetration/impulse/bite)
- `doc/archived/focus_design.md` (draw pile pre-commitment)
- `doc/archived/combat_design.md`

## Problem Statement

The current "stakes" system conflates multiple concepts:
- **Targeting** (high/low) - positional
- **Commitment** (probing→reckless) - risk exposure
- **Damage output** - somehow tied to both

This produces unintuitive results: a "reckless" swing does 2× damage, but physically a sword swing is a sword swing. The damage comes from the weapon, not from "trying harder."

Additionally, the only way to modify combat is by stacking high/low modifiers. This isn't a rich tactical space.

## Current State

### Stakes Enum (cards.zig)

| Stakes | Hit Bonus | Damage Mult | Notes |
|--------|-----------|-------------|-------|
| probing | -0.1 | 0.4 | 5× damage range |
| guarded | 0.0 | 1.0 | is the problem |
| committed | +0.1 | 1.4 | |
| reckless | +0.2 | 2.0 | |

Hit chance: ±0.2 range (tiny)
Damage: 5× range (dominates)

### Height Modifiers

Stacking high/low cards affects hit location weighting, not hit probability. Guard coverage provides defense bonus to guarded zones.

## Design Questions

### 1. What should affect damage?

Candidates:
- **Weapon** - sword vs fist (primary)
- **Technique** - thrust vs swing
- **Stats** - strong vs weak (now ±20-60%, post-T031)
- **Hit quality** - clean hit vs glancing (outcome roll quality?)
- **NOT "commitment"** - you don't hit harder by wanting it more

### 2. What should affect hit/defense chance?

Candidates:
- **Height mismatch** - attacking where they're not guarding
- **Commitment** - overextending increases hit chance but exposes you
- **Card stacking** - strong hand = advantage
- **Technique matchup** - some techniques counter others
- **Positioning** - flanking, reach, terrain

### 3. What creates tactical decisions?

Current: "Do I want 40% damage or 200% damage?" (not interesting)

Better:
- "Do I commit to high and risk being exposed low?"
- "Do I play aggressively and draw more offense cards?"
- "Do I stack this attack or save cards for defense?"

## Proposed Model

### Separate the Concepts

**Targeting (Height)**
- WHERE you're attacking
- WHERE you're defending
- Mismatch = hit bonus
- Stacking high cards = better high attack, worse low defense

**Commitment (Risk)**
- HOW extended you are
- Affects hit% AND vulnerability
- Maybe: emerges from card mix rather than explicit slider
- If kept as slider: compress damage range (0.8-1.2), widen hit range (±0.3)

**Damage**
- From weapon/technique/stats only
- Hit quality might add ±10-20% (exceptional success)
- Remove or heavily compress stakes damage multiplier

### Height Stacking Effects

If you stack 3 high cards:
- +30% hit chance against high targets (head)
- -30% defense against low attacks
- Unlocks head targeting (currently gated?)

This makes height commitment meaningful without magic damage multipliers.

### Pre-Commitment via Draw Piles

From `focus_design.md` - not yet implemented:

```
At start of turn, the agent has Focus draws available:
1. Choose a category (offensive/defensive/manoeuvre/special)
2. Draw one card from that category's virtual pile
3. See the card
4. Repeat until Focus exhausted
```

This creates posture commitment at draw time:
- 5 stamina → draw 5 offensive (all-in aggression)
- 5 stamina → draw 2 offensive, 2 defensive, 1 manoeuvre (balanced)

Your hand composition becomes your "stance" - no separate commitment slider needed.

### Additional Modifier Types

Beyond high/low, potential modifier cards:
- **Feint** - misdirect (see `doc/issues/feint.md`)
- **Press** - maintain pressure, limit opponent options
- **Yield** - defensive reset, recover position
- **Rage/Frenzy** - damage bonus but defensive penalty (explicit tradeoff card)

These would be separate cards you play, not a global "stakes" setting.

## Implementation Phases

### Phase 1: Retune Stakes Numbers ✓

> Completed 2026-01-09

| Stakes | Hit (old→new) | Damage (old→new) |
|--------|---------------|------------------|
| probing | -0.1 → -0.15 | 0.4 → 0.85 |
| guarded | 0.0 → 0.0 | 1.0 → 1.0 |
| committed | +0.1 → +0.15 | 1.4 → 1.1 |
| reckless | +0.2 → +0.30 | 2.0 → 1.2 |

Hit range: ±0.2 → ±0.3 (50% wider)
Damage range: 5× → 1.4× (compressed)

### Phase 2: Height → Hit Chance
- Stacking modifiers affects hit%, not just location weighting
- Add defensive exposure for over-commitment to one height

### Phase 3: Draw Pile Pre-Commitment
- Implement category-based drawing from `focus_design.md`
- UX for choosing offensive/defensive/manoeuvre draws
- State management for virtual piles

### Phase 4: Additional Modifiers
- Design modifier card types
- Integrate with existing card system
- Balance testing

## Open Questions

1. Should "commitment" be an explicit choice or emerge from card mix?
2. How does height stacking interact with guard coverage?
3. What's the right hit% bonus per stacked modifier?
4. Does removing damage multipliers make combat too predictable?
5. How do modifier cards fit into the hand limit / stamina economy?

## References

- `src/domain/cards.zig` - Stakes enum
- `src/domain/resolution/height.zig` - height targeting weights
- `doc/archived/focus_design.md` - draw pile design
- `doc/issues/feint.md` - feint mechanics
