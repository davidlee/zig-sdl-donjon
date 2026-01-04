# Focus Design

## Overview

Focus is a new agent resource that governs tactical flexibility during combat. It determines how many cards you draw each turn and can be spent during the commit phase to modify your plays.

## Resource Model

Both Focus and Stamina share a common `Resource` structure. Key distinction:
- `current`: actual resource value
- `available`: uncommitted amount for this turn (≤ current)

This models the commitment flow where stamina is reserved when cards are selected but not actually spent until resolution.

```zig
// stats.zig
pub const Resource = struct {
    current: f32,     // actual value
    available: f32,   // uncommitted for this turn (≤ current)
    default: f32,     // start-of-encounter value
    max: f32,
    refresh: f32,     // per-turn recovery

    /// Commit without spending (stamina on card selection)
    pub fn commit(self: *Resource, amount: f32) bool {
        if (self.available >= amount) {
            self.available -= amount;
            return true;
        }
        return false;
    }

    /// Reverse a commitment (card withdrawn during commit phase)
    pub fn uncommit(self: *Resource, amount: f32) void {
        self.available = @min(self.available + amount, self.current);
    }

    /// Spend immediately (Focus actions, or one-shot costs)
    pub fn spend(self: *Resource, amount: f32) bool {
        if (self.available >= amount) {
            self.available -= amount;
            self.current -= amount;
            return true;
        }
        return false;
    }

    /// Finalize commitments - current catches down to available (stamina at resolution)
    pub fn finalize(self: *Resource) void {
        self.current = self.available;
    }

    /// End of turn refresh
    pub fn refresh(self: *Resource) void {
        self.current = @min(self.current + self.refresh, self.max);
        self.available = self.current;
    }

    /// Start of encounter
    pub fn reset(self: *Resource) void {
        self.current = self.default;
        self.available = self.default;
    }
};
```

**Usage patterns:**

| Resource | Selection | Commit Phase | Resolution | End of Turn |
|----------|-----------|--------------|------------|-------------|
| Stamina | `commit()` | `uncommit()` on withdraw | `finalize()` | `tick()` |
| Focus | - | `spend()` | - | `tick()` |

Agent gains:
```zig
focus: Resource,
stamina: Resource,  // replaces current stamina/stamina_available
```

## Turn Sequence

```
End of Turn N:
  - Focus refreshes: current += refresh, capped at max
  - Stamina refreshes: current += refresh, capped at max

Start of Turn N+1:
  - Draw up to current Focus (see Draw Categories below)

Selection Phase:
  - Choose cards from hand to play

Commit Phase:
  - Spend Focus to modify plays (see Focus Actions below)
  - Simultaneous blind commitment (both agents)

Resolution:
  - Resolve plays
```

Spending Focus during commit phase reduces next turn's draw count (1-turn delayed penalty).

## Draw Categories

Cards belong to one or more draw categories:

```zig
pub const DrawCategory = enum {
    offensive,   // attacks, strikes
    defensive,   // blocks, parries, guards
    manoeuvre,   // footwork, positioning
    special,     // meta: stamina/focus boost, weapon swap, environment
};
```

Cards can be multi-category. Representation on Template:

```zig
draw_categories: []const DrawCategory = &.{},
```

Draw pile remains a single physical ArrayList. Virtual filtered views provide category-specific iteration:

```zig
// deck.zig
pub fn drawableByCategory(self: *Deck, cat: DrawCategory) CategoryIterator
pub fn countByCategory(self: *Deck, cat: DrawCategory) usize
```

## Drawing as Tactical Decision

At start of turn, the agent has Focus draws available. Drawing is interactive:

1. Choose a category (offensive/defensive/manoeuvre/special)
2. Draw one card from that category's virtual pile
3. See the card
4. Repeat until Focus exhausted or choose to stop

This forces pre-commitment to posture (aggressive vs defensive stance) while allowing adaptation based on what you draw.

If Focus = 0, no cards drawn (stuck with current hand).

Focus is replenished after drawing (1 for 1) for the commit phase.

## Focus Actions (Commit Phase)

During commit phase, Focus can be spent (1F each) to:

| Action | Effect |
|--------|--------|
| Withdraw | Remove one of your cards from in_play |
| Add | Add a card from hand as a new play |
| Stack | Place same card on an existing play (reinforcement) |

**Constraint:** Cards added during commit phase cannot be stacked that same turn. Only cards played during selection phase are eligible for stacking. This prevents degenerate Focus loops and makes selection phase commitment meaningful.

Note: You can stack any number of matching cards for 1F

Note: Some cards (with Trigger.on_commit) have a Focus cost to play, dependent on the card.

Spending focus in the commit phase depletes your focus for the next phase (a persistent loss, until it is gained back in refresh).

### Cost Struct Extension

Focus becomes a standard cost type alongside stamina and time:

```zig
pub const Cost = struct {
    stamina: f32,
    time: f32 = 0.3,
    focus: f32 = 0,      // NEW: on_commit cards may cost Focus
    exhausts: bool = false,
};
```

Cost application in `CommandHandler.playActionCard` needs to:
1. Check `card.cost.focus` availability in addition to stamina
2. Use `agent.focus.spend()` for Focus costs (immediate spend, not commit)
3. Validate Focus availability before allowing the play

### Stacking / Reinforcement

Placing multiple copies of the same card on a single play. Effects:
- Increased damage/effect magnitude
- Harder to counter/parry (opponent needs stronger response)
- Represents deeper commitment

Exact mechanics TBD - likely expressed through the rule system.

## Strategic Implications

1. **Draw count as resource**: Spending Focus gives immediate tactical flexibility but limits future options
2. **Forcing Focus spend**: Making opponent react costs them Focus, reducing their next turn's draws
3. **Posture commitment**: Category-based drawing means you can't freely switch between offense and defense
4. **Information asymmetry**: Commitment is simultaneous and blind; Focus spending happens after initial card selection but before resolution

## Rule Representation

### Draw Categories via TagSet

Looking at `cards.TagSet`, it already has `offensive` and `defensive` flags. Rather than a separate DrawCategory enum, we can extend TagSet:

```zig
pub const TagSet = packed struct {
    // existing
    melee: bool = false,
    ranged: bool = false,
    offensive: bool = false,
    defensive: bool = false,
    // ...
    meta: bool = false,      // already exists - use for "special" draw pile

    // add
    manoeuvre: bool = false, // footwork, positioning
};
```

Draw filtering then uses existing tag infrastructure:

```zig
// deck.zig
pub fn drawableByTag(self: *Deck, tag_mask: TagSet) TagIterator {
    return TagIterator.init(self.draw.items, tag_mask);
}
```

Multi-category cards (e.g., a repositioning strike that's both offensive and manoeuvre) naturally work since TagSet is a bitfield.

### Play Modification (Transforms via Effects)

Rather than "swapping" to a different card, transforms like feint *modify* an existing play. This uses composable Effect primitives, not special-case transform types.

**New Effect primitives:**

```zig
pub const Effect = union(enum) {
    // existing...
    combat_technique: Technique,
    modify_stamina: struct { amount: i32, ratio: f32 },
    move_card: struct { from: Zone, to: Zone },
    add_condition: damage.Condition,
    interrupt,
    emit_event: Event,

    // new: play manipulation
    modify_play: struct {
        cost_mult: ?f32 = null,      // multiply cost
        damage_mult: ?f32 = null,    // multiply damage (0 = no damage)
        replace_advantage: ?TechniqueAdvantage = null,  // override advantage profile
    },
    cancel_play: void,  // target determines what gets cancelled
    modify_advantage: AdvantageEffect,  // direct advantage adjustment
};
```

**New trigger and target queries:**

```zig
pub const Trigger = union(enum) {
    on_play,
    on_draw,
    on_tick,
    on_event: EventTag,
    on_commit,  // NEW: fires during commit phase
};

pub const TargetQuery = union(enum) {
    // existing...
    single: Selector,
    all_enemies,
    self,
    body_part: body.PartTag,
    event_source,

    // NEW: target plays (not cards)
    my_play: Predicate,       // my plays matching predicate
    opponent_play: Predicate, // opponent plays matching predicate
};
```

WARNING: triggers are NOT currently checked in the initial play phase, nor in the command handler / AI. Will need to be addressed to ensure cards are only playable at the allowed time.


**Feint as a composed card:**

```zig
const feint = Template{
    .kind = .action,
    .name = "feint",
    .tags = .{ .meta = true },  // goes in special/meta draw pile
    .cost = .{ .stamina = 1.0, .time = 0.1, .focus = 1.0 },  // costs 1F
    .rules = &.{
        .{
            .trigger = .on_commit,
            .valid = .{ .has_play_matching = .{ .has_tag = .{ .offensive = true } } },
            .expressions = &.{
                .{
                    .effect = .{ .modify_play = .{
                        .damage_mult = 0,
                        .cost_mult = 0.33,
                        .replace_advantage = .{
                            // Opponent parried/blocked a feint = wasted their defense
                            .on_parried = .{ .control = 0.25, .pressure = 0.1 },
                            .on_blocked = .{ .control = 0.20 },
                            // Opponent attacked through = called your bluff
                            .on_countered = .{ .control = -0.15, .self_balance = -0.1 },
                            // "Hit" (opponent did nothing) = gained initiative
                            .on_hit = .{ .control = 0.15 },
                            // Dodged = neutral, they repositioned
                            .on_dodged = .{ .position = -0.05 },
                        },
                    } },
                    .target = .{ .my_play = .{ .has_tag = .{ .offensive = true } } },
                    .filter = null,
                },
            },
        },
    },
};
```

**Why this works:**

1. **No explicit cancel needed**: Defense resolves against zero-damage attack. The *outcome* (on_parried, on_blocked) now benefits attacker via replaced advantage profile.

2. **Defensive cost still paid**: Opponent's parry/block consumes their time and stamina, even against a non-damaging attack. This IS the feint's cost to the opponent.

3. **Tactical wheel encoded in data**: Each technique's advantage profile defines its matchups. Rock-paper-scissors emerges from advantage profiles, not hardcoded rules.

4. **Composable**: Feint isn't special - it's just `modify_play` with specific parameters. Other transforms use the same primitives with different values.

### Stacking as Stakes Escalation

Stacking (reinforcing a play with copies of the same card) maps naturally to the existing `Stakes` system:

| Stack Count | Effective Stakes |
|-------------|------------------|
| 1 (base) | guarded |
| 2 | committed |
| 3+ | reckless |

This reuses existing multipliers for damage, hit chance, and advantage effects. No new mechanics needed.

**Alternative**: If per-card tuning is needed, add to Template:

```zig
// On Template (optional, defaults apply if null)
stack_scaling: ?struct {
    damage_per_stack: f32 = 0.4,      // +40% per extra card
    counter_penalty_per_stack: f32 = 0.2,  // +20% harder to counter
} = null,
```

**Recommendation**: Start with Stakes escalation. Add per-card tuning later if needed.

### Play State Extension

To track stacking and stakes during commit phase, extend the play representation:

```zig
pub const PlayState = struct {
    card: *Instance,           // the played card
    stakes: Stakes = .guarded,
    stack: std.ArrayList(*Instance),  // stacked copies (empty = just the base card)

    /// Effective stakes after stacking
    pub fn effectiveStakes(self: PlayState) Stakes {
        return switch (self.stack.items.len) {
            0 => self.stakes,
            1 => .committed,
            else => .reckless,
        };
    }
};
```

This would replace the current simple `in_play: ArrayList(*Instance)` with richer state.

## Encounter State Model

### Problem

Current `Agent.engagement` has limitations:
- Only mobs have it (player has null)
- Assumes player as implicit anchor
- Breaks for N-vs-M encounters (allies, summons, multiple players)
- Zero-sum axes (pressure/control/position) are fundamentally *pairwise*

### Target Model

Engagement and turn state move off Agent, onto Encounter:

```zig
pub const Encounter = struct {
    // All combatants (replaces separate player + enemies)
    combatants: ArrayList(*Agent),

    // Pairwise engagements - canonical key ordering (lower ID first)
    engagements: std.AutoHashMap(AgentPair, Engagement),

    // Per-agent encounter state (turn, history)
    agent_state: std.AutoHashMap(entity.ID, AgentEncounterState),

    // --- API ---
    pub fn getEngagement(self: *Encounter, a: entity.ID, b: entity.ID) ?*Engagement {
        return self.engagements.getPtr(AgentPair.canonical(a, b));
    }

    /// All engagements involving this agent
    pub fn engagementsFor(self: *Encounter, agent: entity.ID) EngagementIterator { ... }

    pub fn stateFor(self: *Encounter, agent: entity.ID) ?*AgentEncounterState { ... }
};

pub const AgentPair = struct {
    a: entity.ID,  // lower
    b: entity.ID,  // higher

    pub fn canonical(x: entity.ID, y: entity.ID) AgentPair {
        return if (x.index < y.index) .{ .a = x, .b = y } else .{ .a = y, .b = x };
    }
};

pub const AgentEncounterState = struct {
    current: TurnState,
    history: TurnHistory,
};
```

### Turn State

Play groupings are ephemeral - exist from commit through resolution:

```zig
pub const Play = struct {
    primary: entity.ID,              // the lead card
    reinforcements: std.BoundedArray(entity.ID, 4),  // stacked copies
    stakes: Stakes = .guarded,
    added_in_commit: bool = false,   // true if added via Focus, cannot be stacked

    // Applied by modify_play effects during commit phase
    cost_mult: f32 = 1.0,
    damage_mult: f32 = 1.0,
    advantage_override: ?TechniqueAdvantage = null,

    pub fn cardCount(self: Play) usize {
        return 1 + self.reinforcements.len;
    }

    pub fn canStack(self: Play) bool {
        return !self.added_in_commit;
    }

    pub fn effectiveStakes(self: Play) Stakes {
        return switch (self.reinforcements.len) {
            0 => self.stakes,
            1 => .committed,
            else => .reckless,
        };
    }

    /// Get advantage profile (override if set, else from technique)
    pub fn getAdvantage(self: Play, technique: *const Technique) ?TechniqueAdvantage {
        return self.advantage_override orelse technique.advantage;
    }
};

pub const TurnState = struct {
    plays: std.BoundedArray(Play, 8),
    focus_spent: f32 = 0,

    pub fn clear(self: *TurnState) void {
        self.plays.len = 0;
        self.focus_spent = 0;
    }
};
```

### Turn History

For sequencing predicates ("if you feinted last turn"):

```zig
pub const TurnHistory = struct {
    recent: std.BoundedArray(TurnState, 4),  // ring buffer

    pub fn push(self: *TurnHistory, turn: TurnState) void {
        if (self.recent.len == self.recent.buffer.len) {
            // Shift out oldest
            std.mem.copyForwards(TurnState, self.recent.buffer[0..], self.recent.buffer[1..]);
            self.recent.len -= 1;
        }
        self.recent.appendAssumeCapacity(turn);
    }

    pub fn lastTurn(self: TurnHistory) ?*const TurnState {
        return if (self.recent.len > 0) &self.recent.buffer[self.recent.len - 1] else null;
    }

    pub fn turnsAgo(self: TurnHistory, n: usize) ?*const TurnState {
        if (n >= self.recent.len) return null;
        return &self.recent.buffer[self.recent.len - 1 - n];
    }

    /// For predicates like "if you used technique X last turn"
    pub fn usedTechnique(self: TurnHistory, turns_ago: usize, tech: TechniqueID) bool {
        const turn = self.turnsAgo(turns_ago) orelse return false;
        for (turn.plays.slice()) |play| {
            // Check primary card's technique (after any modifiers) 
            // NOTE consider Feint example during implementation ..
            // Would need card lookup to check primary's technique
        }
        return false;
    }
};
```

### What This Enables

| Scenario | Support |
|----------|---------|
| 1-vs-1 | One engagement in map |
| 1-vs-N | Player has N engagements, each mob has 1 |
| N-vs-M | Any agent can engage any other |
| Selective engagement | Empty = not engaged |
| Sequencing predicates | "If feinted last turn, riposte bonus" |

### Deferred Complexity

- **Group melees**: 3+ agents in one engagement (model as multiple pairwise for now)
- **Engagement formation/dissolution**: Dynamic engage/disengage mechanics
- **Attention limits**: Max simultaneous engagements per agent
- **Allied AI**: Friendly NPCs with their own turn states
- AI Focus spending heuristics

## Implementation Phases

### Phase 1: Foundation
1. **Resource struct** - Add to stats.zig, update Agent
2. **Encounter state migration** - Move engagement off Agent, add agent_state map
3. **TurnState/TurnHistory/Play** - Add structs, wire into encounter

### Phase 2: Draw System
4. **TagSet extension** - Add `manoeuvre` tag
5. **Draw filtering** - Add iterator/count helpers to Deck

### Phase 3: Commit Phase
6. **on_commit trigger** - New trigger type, execution during commit phase
7. **Play-targeting queries** - `my_play`, `opponent_play` with predicates
8. **modify_play effect** - cost_mult, damage_mult, replace_advantage
9. **Focus spending** - Commit phase actions (withdraw, add, stack)

### Phase 4: Draw Decision
10. **Draw-as-decision** - Interactive drawing by category

### Phase 5: Transform Cards
11. **Feint card** - First transform using modify_play primitives
12. **Tactical wheel balancing** - Tune advantage profiles for rock-paper-scissors

## Open Questions

- Turn history depth (4 turns enough?)

---

# Design Evolution: Technique Pool + Modifier Cards (Model B)

*Added 2026-01-02 after review of Phase 3 implementation*

## Problem Statement

The current design conflates two orthogonal concepts:

1. **Playability window**: When can this card enter play?
2. **Effect trigger**: When do the card's rules fire?

The `on_commit` trigger was intended to mean "this card can only be played during commit phase" (Feint), but the implementation interpreted it as "fire this rule's effects when entering commit phase". Both interpretations are valid for different cards, but they need separate representation.

More fundamentally: should fundamental techniques (thrust, swing, block, feint) be dealt randomly? Or should they always be available, with randomness governing *how* you execute them?

## Model B: Techniques Always Available

### Core Concept

| Layer | Source | Examples |
|-------|--------|----------|
| Techniques | Always available (pool) | thrust, swing, block, parry, feint |
| Tactical modifiers | Dealt from deck | high/mid/low, committed/guarded, press/withdraw |

A turn becomes: choose technique(s) + pair with available modifiers.

You can always thrust, but *how* you thrust depends on what tactical cards you drew.

### What Changes

**Hand contents shift from "what moves you know" to "how you fight":**

- Not: "I drew Thrust, Thrust, Block"
- But: "I drew High, Low, Guarded"

**Draw categories reframe:**

| Old Category | New Category |
|--------------|--------------|
| Offensive technique | Aggressive modifier (Committed, Press, Reckless) |
| Defensive technique | Cautious modifier (Guarded, Withdraw, Patient) |
| Manoeuvre | Positional modifier (High/Mid/Low, Flank, Close) |
| Meta/Special | Resource modifier (Focus recovery, Stamina boost) |

### Modifier Taxonomy (Draft)

**Height modifiers** (target selection):
- `High` - targets head, harder to hit, more damage
- `Mid` - targets torso, baseline
- `Low` - targets legs, easier to hit, less damage

**Commitment modifiers** (risk/reward):
- `Guarded` - defensive posture, reduced damage, bonus on success (reveal enemy card?)
- `Committed` - full commitment, bonus damage, vulnerable on miss
- `Reckless` - maximum commitment, stakes escalation

**Tempo modifiers** (initiative):
- `Press` - maintain pressure, faster execution
- `Withdraw` - create distance, slower but safer
- `Feint` - fake attack, converts to advantage play (this becomes a modifier, not a technique!)

### Technique × Modifier Interaction

**Baseline (no modifier):** Technique executes at default values.

**Single modifier:** Applies its effect to the technique.

**Stacked modifiers:** Combine effects, potentially unlock special interactions.

| Technique | + Modifier | Effect |
|-----------|------------|--------|
| Thrust | +High | Head thrust, accuracy penalty, damage bonus |
| Thrust | +High +Committed | Reckless head thrust, major damage, exposed |
| Block | +Low | Leg block, protects against low attacks |
| Block | +Guarded | Defensive block, reveals enemy card on success |
| Swing | +Press | Fast swing, maintains initiative |
| Thrust | +Feint | Fake thrust, zero damage, advantage on "hit" |

### Stacking Same Modifier

Multiple copies of the same modifier intensify the effect:

| Stack | Effect |
|-------|--------|
| High + High | Improved accuracy OR harder to parry |
| Committed + Committed | Reckless stakes (existing mechanic) |
| Guarded + Guarded | Reveal 2 cards? Extended defensive window? |

This complements the existing reinforcement mechanic (stacking same technique), not replaces it.

### Play Construction

A Play becomes:
```zig
pub const Play = struct {
    technique: entity.ID,              // from pool (always available)
    modifiers: [4]?entity.ID,          // from hand (dealt cards)
    modifier_count: u8 = 0,

    // existing fields...
    stakes: Stakes = .guarded,
    cost_mult: f32 = 1.0,
    damage_mult: f32 = 1.0,
    advantage_override: ?TechniqueAdvantage = null,
};
```

### Storage Model

**Techniques:**
- Live in agent's Pool (always available)
- Can be duplicated on-demand as Play instances
- Not in deck/hand/discard cycle

**Modifiers:**
- Live in agent's Deck (draw/hand/discard cycle)
- Dealt based on Focus
- Consumed when played (go to discard)

This reuses existing `.deck` vs `.pool` infrastructure on `Agent.cards`.

## Playability Phases (Orthogonal Fix)

Regardless of Model B adoption, playability needs separation from triggers.

### TagSet Extension

```zig
pub const TagSet = packed struct {
    // ...existing...
    reaction: bool = false,       // already exists

    // playability phases
    phase_selection: bool = false,  // playable during card selection
    phase_commit: bool = false,     // playable during commit phase
};
```

### Validation

```zig
fn canPlayInPhase(tags: TagSet, phase: GameState) bool {
    return switch (phase) {
        .player_card_selection => tags.phase_selection,
        .commit_phase => tags.phase_commit,
        // reaction window checks .reaction
        else => false,
    };
}
```

### Default Handling

Most cards: `.phase_selection = true` (set via template helper)

Commit-phase cards (like current Feint design): `.phase_commit = true`

## Feint Reconsidered

Under Model B, Feint becomes a **modifier**, not a technique:

```zig
const feint_modifier = Template{
    .kind = .modifier,  // new kind
    .name = "feint",
    .tags = .{ .phase_selection = true },  // played during selection
    .cost = .{ .stamina = 0.5 },  // low stamina, no focus cost
    .rules = &.{
        .{
            .trigger = .on_play,
            .effect = .{ .modify_play = .{
                .damage_mult = 0,
                .cost_mult = 0.33,
                .replace_advantage = .{ /* feint advantage profile */ },
            }},
            .target = .self_play,  // modifies the play it's attached to
        },
    },
};
```

When you play Thrust + Feint, the Feint modifier converts your thrust into a zero-damage probe with favorable advantage outcomes.

## Mastery Progression (Hybrid, Roadmap)

| Mastery Level | Availability |
|---------------|--------------|
| Unlearned | Not available |
| Learned | In deck (dealt randomly) |
| Mastered | In pool (always available) |

**Progression arc:**
1. Find/unlock a new technique (e.g., Mordhau)
2. It enters your deck as a learnable card
3. Use it successfully → gain mastery XP
4. At mastery threshold → becomes metaprogression card
5. Metaprogression card = always in pool

**Classes as starting metaprogression:**
- Swordsman: starts with Thrust, Swing, Block, Feint mastered
- Shieldbearer: starts with Block, Shield Bash, Guard mastered
- etc.

## Impact on Current Implementation

### Likely Preserved

- `Resource` struct (Focus/Stamina) ✓
- `Encounter` state model (engagements, agent_state) ✓
- `Play` struct (with modifications) ✓
- `TurnState`, `TurnHistory` ✓
- `modify_play`, `cancel_play` effects ✓
- Focus spending commands (withdraw/add/stack) - with semantic shift
- `on_commit` trigger - for actual commit-phase-triggered effects

### Needs Modification

- `Play` struct gains `technique` + `modifiers` fields
- Draw system draws modifiers, not techniques
- Validation checks playability phase flags
- Template gains `.kind = .modifier` variant
- Pool usage for techniques (currently mobs only)

### Needs Removal/Rework

- Technique cards in deck (move to pool)
- Draw categories as technique filters (become modifier filters)
- Feint as technique (becomes modifier)

### Open Questions

- Can techniques be played without any modifier? (Baseline version - yes, probably)
- Maximum modifiers per play? (4 seems reasonable)
- Do modifiers stack with reinforcement, or replace it?
- How do multi-technique plays work (if at all)?
- Modifier discard timing (on play? on resolution?)

## Play Struct Design (Model B)

*Added 2026-01-03*

### Technique Instancing

Techniques reference pool IDs directly (not instanced into in_play). Simpler for now. If card upgrades/mutations matter later, can add instance tracking.

### Naming

- `primary` → `technique` (from pool, always available)
- `reinforcements` → `modifier_stack` (different cards from hand, combinable)

### Computed vs Stored Properties

**Decision: Computed approach.**

Rather than storing accumulated modifiers on Play:
```zig
// OLD - stored
cost_mult: f32 = 1.0,
damage_mult: f32 = 1.0,
advantage_override: ?TechniqueAdvantage = null,
```

Compute on-demand from modifier_stack:
```zig
// NEW - computed
pub fn effectiveCostMult(self: *const Play, deck: *const Deck) f32 {
    var mult: f32 = 1.0;
    for (self.modifiers()) |mod_id| {
        const card = deck.entities.get(mod_id);
        mult *= card.template.cost_modifier orelse 1.0;
    }
    return mult;
}
```

**Rationale:**
- Play struct stays lean (just IDs)
- Modifiers applied consistently from source (card templates)
- Reaction cards modifying the stack "just work" - recompute reflects changes
- Context (Agent, Engagement) can be passed to compute methods when conditions influence values

**Context passing (future):**

If conditions influence play effectiveness:
```zig
pub fn effectiveDamageMult(
    self: *const Play,
    deck: *const Deck,
    agent: *const Agent,
    engagement: *const Engagement,
) f32 { ... }
```

Solvable when needed; doesn't require Play to store references.

### Proposed Play Struct

```zig
pub const Play = struct {
    pub const max_modifiers = 4;

    technique: entity.ID,                              // from pool (always available)
    modifier_stack_buf: [max_modifiers]entity.ID = undefined,
    modifier_stack_len: usize = 0,

    stakes: cards.Stakes = .guarded,
    added_in_commit: bool = false,  // Feint etc. still commit-phase plays

    // Accessor
    pub fn modifiers(self: *const Play) []const entity.ID {
        return self.modifier_stack_buf[0..self.modifier_stack_len];
    }

    pub fn addModifier(self: *Play, card_id: entity.ID) error{Overflow}!void {
        if (self.modifier_stack_len >= max_modifiers) return error.Overflow;
        self.modifier_stack_buf[self.modifier_stack_len] = card_id;
        self.modifier_stack_len += 1;
    }

    // Computed properties
    pub fn effectiveCostMult(self: *const Play, deck: *const Deck) f32 { ... }
    pub fn effectiveDamageMult(self: *const Play, deck: *const Deck) f32 { ... }
    pub fn effectiveAdvantage(self: *const Play, deck: *const Deck, technique: *const Technique) ?TechniqueAdvantage { ... }

    pub fn effectiveStakes(self: Play) cards.Stakes {
        // Could factor in modifier effects on stakes
        return self.stakes;
    }
};
```

### Migration Notes

Current Play struct uses stored properties. Migration path:
1. Add modifier_stack alongside reinforcements
2. Add computed methods
3. Update resolution code to use computed methods
4. Remove stored properties
5. Rename reinforcements → modifier_stack (or remove if obsolete)