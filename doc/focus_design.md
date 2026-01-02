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

Each phase builds on the previous. Complete all steps in a phase before moving to the next.

### Phase 1: Foundation

**1.1 Resource struct** (`src/domain/stats.zig`)

Add `Resource` struct as defined in "Resource Model" section above:
- Fields: `current`, `available`, `default`, `max`, `refresh`
- Methods: `commit()`, `uncommit()`, `spend()`, `finalize()`, `refresh()`, `reset()`

**1.2 Update Agent** (`src/domain/combat.zig`)

Replace existing stamina fields on `Agent`:
```zig
// Remove:
stamina: f32,
stamina_available: f32,

// Add:
stamina: stats.Resource,
focus: stats.Resource,
```

Update `Agent.init()` to initialize both resources. Update all call sites that access `agent.stamina` (search for usages).

**1.3 Cost struct extension** (`src/domain/cards.zig`)

Add `focus` field to `Cost`:
```zig
pub const Cost = struct {
    stamina: f32,
    time: f32 = 0.3,
    focus: f32 = 0,
    exhausts: bool = false,
};
```

**1.4 Encounter state migration** (`src/domain/combat.zig`)

Remove `engagement` field from `Agent`. Add to `Encounter`:
```zig
pub const Encounter = struct {
    combatants: ArrayList(*Agent),  // rename from enemies
    engagements: std.AutoHashMap(AgentPair, Engagement),
    agent_state: std.AutoHashMap(entity.ID, AgentEncounterState),
    // ...
};
```

Add `AgentPair` struct with `canonical()` method.
Add `AgentEncounterState` struct (see "Encounter State Model" section).
Add API methods: `getEngagement()`, `engagementsFor()`, `stateFor()`.

Update all code that accesses `agent.engagement` to use `encounter.getEngagement(player_id, agent.id)`.

**1.5 TurnState/TurnHistory/Play structs** (`src/domain/combat.zig` or new file)

Add structs as defined in "Turn State" and "Turn History" sections:
- `Play` with fields: `primary`, `reinforcements`, `stakes`, `added_in_commit`, `cost_mult`, `damage_mult`, `advantage_override`
- `TurnState` with fields: `plays`, `focus_spent`
- `TurnHistory` with methods: `push()`, `lastTurn()`, `turnsAgo()`

Wire `AgentEncounterState.current` and `.history` to use these.

**Acceptance criteria Phase 1:**
- `zig build test` passes
- Game runs without crash
- Stamina/Focus display correctly (if UI exists)
- Engagement lookups work via `encounter.getEngagement()`

---

### Phase 2: Draw System

**2.1 TagSet extension** (`src/domain/cards.zig`)

Add `manoeuvre` tag to `TagSet`:
```zig
pub const TagSet = packed struct {
    // existing...
    manoeuvre: bool = false,
};
```

Update the bitcast size if needed (currently `u12`, may need `u13`+).

**2.2 Draw filtering** (`src/domain/deck.zig`)

Add methods to `Deck`:
```zig
pub fn countByTag(self: *Deck, tag_mask: TagSet) usize
pub fn drawableByTag(self: *Deck, tag_mask: TagSet) TagIterator
```

`TagIterator` iterates `draw` pile, yielding only cards where `card.template.tags.hasAnyTag(tag_mask)`.

**Acceptance criteria Phase 2:**
- Can query draw pile by category (offensive/defensive/manoeuvre/meta)
- Counts match expected values in tests

---

### Phase 3: Commit Phase

**3.1 on_commit trigger** (`src/domain/cards.zig`)

Add to `Trigger` union:
```zig
pub const Trigger = union(enum) {
    on_play,
    on_draw,
    on_tick,
    on_event: EventTag,
    on_commit,  // NEW
};
```

**3.2 Trigger validation** (`src/domain/apply.zig`)

Update `CommandHandler.playActionCard()` (or equivalent) to:
- Check card's trigger against current FSM state
- `on_play` cards only valid in `player_card_selection` state
- `on_commit` cards only valid in `commit_phase` state
- Reject with appropriate error if trigger doesn't match

**3.3 Focus cost validation** (`src/domain/apply.zig`)

Update cost checking to include Focus:
- Check `card.cost.focus <= agent.focus.available`
- Call `agent.focus.spend(card.cost.focus)` when card is played
- Stamina uses `commit()` during selection, Focus uses `spend()` immediately

**3.4 Play-targeting queries** (`src/domain/cards.zig`)

Add to `TargetQuery`:
```zig
my_play: Predicate,
opponent_play: Predicate,
```

Update target resolution logic to iterate `TurnState.plays` and filter by predicate.

**3.5 modify_play effect** (`src/domain/cards.zig`, `src/domain/apply.zig`)

Add to `Effect`:
```zig
modify_play: struct {
    cost_mult: ?f32 = null,
    damage_mult: ?f32 = null,
    replace_advantage: ?TechniqueAdvantage = null,
},
```

Implement effect execution: find targeted Play, apply multipliers and override.

**3.6 Focus actions as commands** (`src/commands.zig`, `src/domain/apply.zig`)

Add commands for commit phase actions:
```zig
pub const Command = union(enum) {
    // existing...
    withdraw_play: entity.ID,     // remove play from TurnState
    add_play: entity.ID,          // add card from hand as new play
    stack_play: struct { play: entity.ID, cards: []const entity.ID },
};
```

Implement handlers that:
- Validate Focus cost (1F for withdraw/add, 1F for stack regardless of count)
- Update `TurnState.plays` accordingly
- Set `added_in_commit = true` for added plays

**Acceptance criteria Phase 3:**
- `on_commit` cards rejected during selection phase
- `on_play` cards rejected during commit phase
- Focus cost deducted when playing on_commit cards
- `modify_play` effect correctly modifies Play fields
- Withdraw/add/stack commands work and cost Focus

---

### Phase 4: Draw Decision

**4.1 Draw phase FSM state** (`src/domain/world.zig`)

Review FSM states. May need to split `draw_hand` into interactive draw if not already.

**4.2 Draw commands** (`src/commands.zig`)

Add command for drawing by category:
```zig
draw_card: struct { category: TagSet },  // or specific enum
```

**4.3 Draw logic** (`src/domain/apply.zig`)

Implement draw:
- Validate Focus available
- Find random card in draw pile matching category
- Move to hand
- Decrement Focus (or track draws for replenishment)

**4.4 Focus replenishment**

After draw phase completes, replenish Focus 1:1 (Focus = number of cards drawn).

**Acceptance criteria Phase 4:**
- Player can choose category when drawing
- Drawing costs/consumes Focus appropriately
- Focus replenished after draw phase

---

### Phase 5: Transform Cards

**5.1 Feint card** (`src/domain/card_list.zig`)

Add feint template as defined in "Feint as a composed card" section:
- `trigger = .on_commit`
- `cost = .{ .focus = 1.0, ... }`
- `modify_play` effect with advantage override

**5.2 Integration test**

Create test that:
- Sets up combat with player having offensive card + feint
- Plays offensive card in selection
- Plays feint in commit phase
- Verifies Play has `damage_mult = 0` and advantage override

**5.3 Tactical wheel balancing**

Review/tune advantage profiles on existing techniques for rock-paper-scissors dynamics.

**Acceptance criteria Phase 5:**
- Feint card can be played during commit phase
- Feint modifies offensive play as expected
- Resolution uses modified advantage profile

---

## Open Questions

- Turn history depth (4 turns enough?)
- Exact values for tactical wheel advantage profiles
- UI for commit phase Focus actions