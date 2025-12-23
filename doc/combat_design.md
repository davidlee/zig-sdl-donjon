# Combat System Design

Summary of design decisions from initial exploration.

## Core Loop

Combat uses **simultaneous commitment** with 1-second ticks:

1. **Commit**: both player and mob declare action(s) for this tick
2. **Resolve**: actions execute simultaneously (both attacks land if both attack)
3. **Apply**: damage, stamina costs, state changes
4. **Advance**: ongoing effects progress, draw new hand

Historical duels often ended with both combats dead. This model preserves that tension.

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

passive Metaprogression cards (along with stats) represent your accumulation of skill and knowledge, 
and can give you: 
- broader options (access to new cards - rarer, more difficult, or specialised options) 
- more options to improve your hand (by drawing, or by reacting)
- bonuses & modifiers to specific plays

Card properties:
- **Time cost** (in fractions of a second)
- **Stamina cost** (can be negative for recovery)
- **Effects** (damage, block, conditions, etc.)

Key implications:
- **Multi-card plays**: 0.3s + 0.3s + 0.4s = legal "flurry"
- you can "overcommit" - stacking well beyond 1s worth of moves (risk of interrupt, but reduced cost / 
  increased effect / greater erosion of stance if you pull it off )
- **Hand composition matters**: all offense, no blocks? fight aggressive or stall
- Not playing any cards (or only recovery) might be the most common option: stamina preservation is essential


## Not just combat techniques

cards also represent skills (analyzing opponents for tells or weaknesses; taunting / baiting), 
spells (they tend to be slow and tricky to pull off without an opening, but impactful), etc.

## Card lifecycle

```
deck -> hand (5) -> play -> exhaust/discard -> draw
```

- Draw up to 5 each tick (can be modified)
- some cards draw (or discard / exhaust) additional cards when played, etc
- Some cards exhaust on use (removed for combat)
- some let you retain 1-2 cards between draws, or shape the next draw
- Stats and equipment modify card costs/effects
- Opponent effects can disable/exhaust cards

## core loop

- draw
- put cards into play
- commit 
- (optional / special abilities) react to opponent cards (often at a cost)
- resolve simultaneous sequence; discard, rinse, repeat
  - cards are resolved simultaneously in sequence, counting up in 0.1s increments from the opening of the tick
  - some reactions / interrupts are playable during execution




## Mob Model

**Asymmetric by design.** non-sentient Mobs don't have stats, inventory, or card hands. 
They have behaviour patterns.

Behavior types:
- **Fixed loop**: `[attack, attack, heavy, defend]` repeat
- **State-based**: if HP < 30%, prioritize defense
- **Cooldown-gated**: "big slam" every 4 ticks
- **Weighted options**: probabilities, but learnable tendencies

The "learn the pattern, exploit it" loop is skill expression (Dark Souls model).

There's a gradient - from dumb amoeboids to shrewd tacticians

## Intent Legibility

How much the player knows about mob actions is a design axis:

- **Dumb mobs**: obvious tells, pattern is learnable, no deception
- **Smart mobs**: feints, lies, misinformation
- **Very smart mobs**: adapt to player patterns, counter-strategies (or simulated strategies, 
  with careful orchestration of their options)

Legibility might require:
- Spending an action (perception check)
- Interpreting indirect signals
- Meta-knowledge from fighting the mob type before

## Determinism

Open question how much randomness will be a factor. Aim to start deterministic (besides shuffling) 
and add randomness only as necessary.

- Easier to debug and balance
- Clearer feedback loop for player

- RNG draws recorded as events (for replay/determinism)
- Multiple streams (combat, loot, etc.) to isolate effects

## Open Questions

- Exact hand refresh rules (retain how many? draw when?)
- block/strike/parry/feint/counter interactions
- counter effect on timing
- perhaps: choose n cards across offensive vs defensive decks when you draw (another 
  layer of pre-commitment)
- Stamina regen rate (per tick? only via cards?)
- If you don't play cards from your hand, is there choice in "free" options (eg full recovery / probe for opening / defensive footwork) 
- What happens at stamina 0? (stunned? reduced options? death spiral?)
- Is feinting represented as a "false reveal" or just "simulated" effects?
- How much leeway, at what cost do you get from reactions? Can you react to reactions?
- How do combinations chain?
- Card effect composition (how do modifiers stack?)
- How do "special moves" need to change the predicate grammar? how do special effects need to depend on 
  & interact with "attack rolls" or accuracy?
- how to represent stance / holding initiative / tempo / "controlling the line"? inside vs outside lines?


## other ideas

- 'classes' are slight differences in starting stats & cards.
- everyone starts with a passive that lets you react with a block or attack,
  if you haven't played any cards but the opponent attacks, at stamina cost
- a basic tactic is to bait your opponent with a Feint (stamina cost: 2) to get them ta
  use a reaction (cost: 2) to play a block (cost: 3) and wear them down
- Chains are important: Feint vs Block sets up the next move for Strike (erodes Stance)
- You can overcommit: play more than 1 sec worth of cards in a tick. If they get interrupted, 
  you lose them, but the upside is a bonus to breaking Stance on each successive attack.
- Basic bitch rock paper scissors is Block beats Strike beats Feint beats Block
- Basic combos:
  - Feint Strike Strike 
  - Strike Block Block 
  - Block Feint Feint 

- blocking is a lot better with a shield
- shields can be sundered through use
- some weapons are better than others for busting shields (axe > mace > sword)
- some weapons are better for parrying (sword > axe > mace)
- weapons have durability too - swords get fucked up by a lot of blade on blade smashing

- Manouver is a move - strong vs Feint 

- handling hit distribution: not just a single dimension (high/low). at the
  crunchy end, techniques might have specific weights for the anatomical
  hierarchy (for humans) - but the defender's posture & equipment (spear vs
  basket hilt, etc) matters too.

- weapons and opponents have range (which is abstract). Some weapons might have a max & min reach.
  - far < medium < near < lance < spear < longsword < cutlass < dagger 
  - melee weapons: weapon with most reach holds opponent at its striking distance until they get inside it
  - 2h pole weapons can act as if - 3ft/ 1 stop shorter (hand repositioning)
  - environmental cards can impact reach / cramp polearms
  - the opponent having reach is bad. being inside their reach is good. Manouvering is through card play.
  - some manouver cards can be played simultaneously (as riders) with attack / defence cards.

- still need to handle the 'no opposing card' situation
  - assume weak active defence
  - different to attacking a paralysed foe which is a "free hit"

- unless there's a really good reason otherwise, all the "basic rules" like 
  how many hands you get dealt, reaction draws, etc are 
  represented as Passive or Meta cards in the starting hand
- allows for "class variations" as well as metaprogression

