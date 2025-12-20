# Combat System Design

Summary of design decisions from initial exploration.

## Core Loop

Combat uses **simultaneous commitment** with 1-second ticks:

1. **Commit**: both player and mob declare action(s) for this tick
2. **Resolve**: actions execute simultaneously (both attacks land if both attack)
3. **Apply**: damage, stamina costs, state changes
4. **Advance**: ongoing effects progress, draw new hand

Historical duels often ended with both combatants dead. This model preserves that tension.

## Stamina Economy

Stamina is the core strategic resource:

- **Offensive actions cost stamina** - attacking depletes your reserves
- **Defensive options cost stamina** - you can't turtle forever
- **Running empty is dangerous** - can't defend, creates openings
- **Pressing a wounded opponent** - high reward if they're depleted, high risk if they're not
- **Recovery cards exist** - "Catch Breath" recovers stamina but leaves you exposed

The risk/reward calculus: overcommit and you're vulnerable, play too safe and you lose tempo.

## Cards as Options

All combat options are cards. You don't have abstract "attack" or "defend" - you have the cards you drew.

Card properties:
- **Time cost** (in fractions of a second)
- **Stamina cost** (can be negative for recovery)
- **Effects** (damage, block, conditions, etc.)

Key implications:
- **Multi-card plays**: 0.3s + 0.3s + 0.4s = legal "flurry"
- **Hand composition matters**: all offense, no blocks? fight aggressive or stall
- **Defense is a card**: you might not have defensive options

## Player Model

```
deck -> hand (5) -> play -> exhaust/discard -> draw
```

- Draw up to 5 each tick
- Some cards exhaust on use (removed for combat)
- Maybe retain 1-2 cards between draws (TBD)
- Stats and equipment modify card costs/effects
- Opponent effects can disable/exhaust cards

## Mob Model

**Asymmetric by design.** Mobs don't have stats, inventory, or card hands. They have behavior patterns.

Behavior types:
- **Fixed loop**: `[attack, attack, heavy, defend]` repeat
- **State-based**: if HP < 30%, prioritize defense
- **Cooldown-gated**: "big slam" every 4 ticks
- **Weighted options**: probabilities, but learnable tendencies

The "learn the pattern, exploit it" loop is skill expression (Dark Souls model).

## Intent Legibility

How much the player knows about mob actions is a design axis:

- **Dumb mobs**: obvious tells, pattern is learnable, no deception
- **Smart mobs**: feints, lies, misinformation
- **Very smart mobs**: adapt to player patterns, counter-strategies

Legibility might require:
- Spending an action (perception check)
- Interpreting indirect signals
- Meta-knowledge from fighting the mob type before

For prototype: skip this. One dumb mob with fixed loop, no deception layer.

## Determinism

Starting with fully deterministic combat (no dice). Reasons:
- Easier to debug and balance
- Clearer feedback loop for player
- Randomness can be layered in later as modifiers

If randomness is added later:
- RNG draws recorded as events (for replay/determinism)
- Multiple streams (combat, loot, etc.) to isolate effects

## Module Structure

```
src/
  infra.zig      - utilities + 3rd party libs (leaf layer)
  events.zig     - Event union, EventSystem
  world.zig      - World state, owns subsystems
  combat.zig     - tick resolution, simultaneous commit
  cards.zig      - CardDef, CardInst, effects
  mob.zig        - MobBehavior, patterns
  player.zig     - PlayerCombat, hand management
```

Design principle: `infra` is importable by everything (no domain deps). Domain modules import each other directly.

## Prototype Scope

Minimal vertical slice to validate the loop:

- 1 player with stats, stamina, hand of cards
- 1 dumb mob with fixed behavior loop
- 3-5 action cards: Strike, Block, Catch Breath, Quick Jab
- Simultaneous resolution
- Stamina costs and recovery
- Test harness (no UI): "player plays X, mob plays Y, assert state Z"

Out of scope for prototype:
- Equipment/inventory
- Injuries
- Zones/deck manipulation
- Smart mob AI
- Intent legibility system
- Any rendering

## Open Questions

- Exact hand refresh rules (retain how many? draw when?)
- How does Block interact with Strike in simultaneous resolution?
- Stamina regen rate (per tick? only via cards?)
- What happens at stamina 0? (stunned? reduced options? death spiral?)
- Card effect composition (how do modifiers stack?)

These will be answered by building and testing.
