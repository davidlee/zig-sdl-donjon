# Timing, Simultaneity, and Positioning

> **Status**: Design document. Revision 2026-01-06.

## Problem Statement

The combat system currently supports a **single linear sequence of plays**. Each play occupies a time slice (0.0-1.0 within the tick), resolved in order. This model works for basic combat but has several limitations:

### Current Limitations

1. **No simultaneity**: You cannot thrust while sidestepping. Every action is sequential.

2. **No timing choice**: Plays are appended; you cannot choose *when* in the tick a play resolves. You can remove plays from anywhere but only add to the end.

3. **No deferral**: If opponent commits block→block→attack, you cannot choose to defer your attack to catch their attack window.

4. **Range is decorative**: `Engagement.range` exists but isn't validated during play. Combat starts at "stabbing distance" regardless of weapons.

5. **Reach isn't tactical**: Weapon reach should create meaningful advantage/disadvantage based on distance.

6. **Exclusivity unused**: The `Exclusivity` enum (`weapon`, `hand`, `footwork`, `concentration`) exists but isn't enforced.

### Design Goals

1. **Simultaneity via resource slots**: Plays that use different resources can overlap in time.

2. **Timeline as tactical choice**: Where in the tick you place actions matters.

3. **Range as gating**: Techniques have reach requirements; range must be managed.

4. **Manoeuvres as first-class**: Movement cards change positioning and can overlay arm techniques.

5. **Reactions during resolution**: Windows to respond to revealed plays (deferred, but supported by model).

---

## Current Model Analysis

### TurnState

```zig
pub const TurnState = struct {
    pub const max_plays = 8;
    plays_buf: [max_plays]Play = undefined,
    plays_len: usize = 0;
    // ...
};
```

A flat array of `Play` structs. Timing is derived during `TickResolver.commitPlayerCards` by accumulating `cost.time` values.

### Play

```zig
pub const Play = struct {
    action: entity.ID,                    // lead card
    modifier_stack_buf: [4]entity.ID,     // stacked modifiers
    stakes: cards.Stakes,
    // ...
};
```

No timing field on `Play` itself - timing is computed at commit.

### CommittedAction

```zig
pub const CommittedAction = struct {
    time_start: f32,
    time_end: f32,
    technique: *const Technique,
    // ...
};
```

Timing is assigned when converting plays to committed actions.

### Exclusivity

```zig
pub const Exclusivity = enum {
    weapon,        // keeps one or both arms busy
    primary,       // main hand only
    hand,          // any hand
    arms,          // both arms
    footwork,      // legs, movement
    concentration, // eyes, voice, brain
};
```

Defined but not checked during play validation.

---

## Proposed Model

### Core Insight: Time Slots, Not Time Points

Rather than computing timing as a cumulative sum, model the tick as a **timeline with slots**. Each slot can hold actions as long as they don't conflict on exclusivity.

NOTE: working assumption is that granularity is 0.1s (round up when determining occupancy).

```
Time:     0.0 -------- 0.3 -------- 0.6 -------- 1.0
Arms:     [===Thrust===]
Footwork: [==Sidestep==][===Advance===]
Focus:                  [===Feint applies===]
```

### Exclusivity Channels

Rename "exclusivity" to "channel" for clarity:

```zig
pub const Channel = enum {
    // Physical channels (conflict with each other)
    weapon,        // primary weapon arm(s)
    off_hand,      // off-hand (shield, dagger, etc.)
    footwork,      // legs, stance, movement

    // Mental channels (typically solo)
    concentration, // spells, analysis, taunts

    // Compound (occupies multiple)
    full_body,     // grapples, tackles, some spells
};

pub const ChannelSet = packed struct {
    weapon: bool = false,
    off_hand: bool = false,
    footwork: bool = false,
    concentration: bool = false,

    pub fn conflicts(self: ChannelSet, other: ChannelSet) bool {
        return (self.weapon and other.weapon) or
               (self.off_hand and other.off_hand) or
               (self.footwork and other.footwork) or
               (self.concentration and other.concentration);
    }
};
```

NOTE: weapon here implies both hands if a two handed weapon is equipped (with an aside about versatility of grips for bastard swords, short spears, etc)

### Technique Channel Requirements

Each technique declares which channels it occupies:

```zig
pub const Technique = struct {
    // ...existing fields...

    channels: ChannelSet,  // which channels this occupies

    // Examples:
    // Thrust:     .{ .weapon = true }
    // Sidestep:   .{ .footwork = true }
    // Shield bash: .{ .off_hand = true }
    // Two-hand swing: .{ .weapon = true, .off_hand = true } // ED: off_hand is implied by weapon = true 
    // Spell cast: .{ .concentration = true }
    // Flying kick: .{ .footwork = true, .weapon = true }
};
```

### Timeline Slots

Replace flat play array with timeline-aware structure:

```zig
pub const TimeSlot = struct {
    time_start: f32,
    time_end: f32,
    play: Play,
};

pub const Timeline = struct {
    pub const max_slots = 12;  // more slots since they can overlap

    slots: [max_slots]TimeSlot = undefined,
    slot_count: usize = 0,

    /// Check if a new play can be inserted at the given time range
    pub fn canInsert(
        self: *const Timeline,
        time_start: f32,
        time_end: f32,
        channels: ChannelSet,
    ) bool {
        for (self.slots[0..self.slot_count]) |slot| {
            // Check time overlap
            if (slot.time_end <= time_start or slot.time_start >= time_end) continue;

            // Check channel conflict
            const slot_channels = slot.play.getChannels();  // needs card lookup
            if (channels.conflicts(slot_channels)) return false;
        }
        return true;
    }

    /// Insert a play at specified time (fails if conflict)
    pub fn insert(
        self: *Timeline,
        time_start: f32,
        time_end: f32,
        play: Play,
        channels: ChannelSet,
    ) error{Conflict, Overflow}!void {
        if (!self.canInsert(time_start, time_end, channels)) return error.Conflict;
        if (self.slot_count >= max_slots) return error.Overflow;

        self.slots[self.slot_count] = .{
            .time_start = time_start,
            .time_end = time_end,
            .play = play,
        };
        self.slot_count += 1;
    }

    /// Find available time for a technique starting from a given time
    pub fn findAvailableStart(
        self: *const Timeline,
        after: f32,
        duration: f32,
        channels: ChannelSet,
    ) ?f32 {
        // ... implementation
    }
};
```

### TurnState Update

```zig
pub const TurnState = struct {
    timeline: Timeline,
    focus_spent: f32 = 0,

    // ... methods migrate from plays_buf to timeline
};
```

---

## Range and Reach

### Current State


- `Engagement.range: Reach` exists with values: `clinch`, `dagger`, `mace`, `sabre`, ... , `near`, `medium`, `far`
- `Technique` has no reach requirement 
- Combat starts at `.far` but this isn't enforced

### Range as Gating

Each technique should declare:
1. **Valid ranges**: At which distances can this be used?
2. **Optimal range**: At which distance is this most effective?
3. **Range change**: Does executing this change the range? ED: this feels like the purview of manouevres, not weapon techniques ..

```zig
pub const ReachRequirement = struct {
    min: Reach,
    max: Reach,
    optimal: ?Reach = null,  // bonus if at this range

    pub fn isValid(self: ReachRequirement, current: Reach) bool {
        return @intFromEnum(current) >= @intFromEnum(self.min) and
               @intFromEnum(current) <= @intFromEnum(self.max);
    }
};

pub const Technique = struct {
    // ...existing...

    reach: ReachRequirement = .{ .min = .clinch, .max = .far },  // default: any
    range_change: ?RangeChange = null,  // optional movement effect
};

pub const RangeChange = struct {
    direction: enum { closer, farther },
    magnitude: u8,  // how many steps
    requires_success: bool,  // only on hit?
};
```

### Weapon Reach Integration

Weapons define their effective range:

ED: 'near' is longer than any handheld weapon. longsword would likely span sabre (half-swording / retracted stab ) to .. longsword 

```zig
pub const Template = struct {  // weapon.Template
    // ...existing...

    effective_range: ReachRequirement,  // where this weapon works well

    // Examples:
    // Dagger:    .{ .min = .clinch, .max = .near, .optimal = .clinch }
    // Longsword: .{ .min = .near, .max = .medium, .optimal = .medium }
    // Spear:     .{ .min = .medium, .max = .far, .optimal = .far }
};
```

### Range Validation

During play validation:

```zig
fn canPlayTechnique(
    technique: *const Technique,
    weapon: *const weapon.Template,
    engagement: *const Engagement,
) bool {
    // Technique must be valid at current range
    if (!technique.reach.isValid(engagement.range)) return false;

    // Weapon must be effective at current range
    if (!weapon.effective_range.isValid(engagement.range)) return false;

    return true;
}
```

### Starting Range

Combat should start at the **maximum of both combatants' preferred ranges**:

```zig
fn determineStartingRange(player: *Agent, enemy: *Agent) Reach {
    const player_weapon = player.getEquippedWeapon();
    const enemy_weapon = enemy.getEquippedWeapon();

    const player_max = player_weapon.effective_range.max;
    const enemy_max = enemy_weapon.effective_range.max;

    return @enumFromInt(@max(@intFromEnum(player_max), @intFromEnum(enemy_max)));
}
```

This means:
- Spear vs dagger: combat starts at `far` (spear holder's advantage)
- Sword vs sword: combat starts at `medium`
- Dagger vs dagger: combat starts at `near`

---

## Manoeuvres

### Core Concept

Manoeuvres are techniques that:
1. Use the `footwork` channel (can overlay with `weapon` actions)
2. Change positioning (range, angle, stance)
3. May modify co-occurring arm techniques

### Footwork as Overlay

The channel system naturally supports this:

```zig
// Player commits:
// - Thrust (channels: weapon, time: 0.0-0.3)
// - Sidestep (channels: footwork, time: 0.0-0.2)

// These don't conflict - both execute simultaneously
// Sidestep modifies the thrust's positioning context
```

### Manoeuvre Card Structure

```zig
const sidestep = Template{
    .name = "sidestep",
    .tags = .{ .manoeuvre = true, .defensive = true },
    .cost = .{ .stamina = 1.0, .time = 0.2 },
    .rules = &.{
        .{
            .trigger = .on_play,
            .expressions = &.{
                .{
                    .effect = .{ .modify_engagement = .{
                        .position = 0.1,  // gain position
                    }},
                    .target = .self,
                },
            },
        },
    },
    // Technique info:
    .technique_info = .{
        .channels = .{ .footwork = true },
        .range_change = null,  // doesn't close/open
    },
};

const advance = Template{
    .name = "advance",
    .tags = .{ .manoeuvre = true },
    .cost = .{ .stamina = 1.5, .time = 0.3 },
    .rules = &.{
        .{
            .trigger = .on_play,
            .expressions = &.{
                .{
                    .effect = .{ .modify_range = .{ .closer = 1 }},
                    .target = .engagement,
                },
            },
        },
    },
    .technique_info = .{
        .channels = .{ .footwork = true },
    },
};
```

### Overlay Synergies

Some technique combinations should provide bonuses:

```zig
// In resolution:
fn calculateThrust(attack: AttackContext, overlays: []const *Technique) {
    for (overlays) |overlay| {
        if (overlay.id == .sidestep) {
            // Sidestep + thrust = angled attack, bonus to position
            attack.position_bonus += 0.05;
        }
        if (overlay.id == .advance) {
            // Advance + thrust = momentum bonus
            attack.damage_mult *= 1.1;
        }
    }
}
```

### Manoeuvre-Only Turns

Sometimes the best play is pure movement:
- Close distance against a spear user
- Create distance when wounded
- Circle to flank

This should be viable and not feel like "wasting" a turn.

ED: dodging, disengagement from measure, and stepping inside an attack are also effective ways to avoid getting killed. 
ED: As in real life, staying still while someone is trying to kill you should be actively discouraged by the rules, to the extent that exhausting stamina does not prevent it.

---

## Timeline Interaction Patterns

### Pattern 1: Sequential (Current Model)

```
[Thrust 0.0-0.3][Block 0.3-0.5][Thrust 0.5-0.8]
```

All on weapon channel, sequential by necessity.

### Pattern 2: Parallel Channels

```
Weapon:   [====Thrust 0.0-0.3====]
Footwork: [==Sidestep 0.0-0.2==]
```

Different channels, simultaneous.

### Pattern 3: Staggered Overlay

```
Weapon:   [====Thrust 0.0-0.3====][====Swing 0.3-0.6====]
Footwork:         [====Advance 0.1-0.4====]
```

Advance overlaps both attacks, affecting both.

### Pattern 4: Defensive Timing

```
Weapon: [==Block 0.0-0.3==]              [==Block 0.6-0.9==]
                          (gap: 0.3-0.6)
```

Choosing when to defend based on expected attack timing.

---

## Domain/UI Contract

The domain model must expose clear queries and operations for UI to build against. "Click to play" becomes the exception; most interactions require target + timing decisions.

### Interaction Patterns

| Card Type | Interaction | Domain Query |
|-----------|-------------|--------------|
| Technique (single target) | Select target, then time slot | `validTargetsFor(card)`, `availableSlots(card, target)` |
| Technique (self/no target) | Select time slot only | `availableSlots(card, null)` |
| Manoeuvre (focal) | Select focal target, then time slot | `validFocalTargets(card)`, `availableSlots(card, target)` |
| Manoeuvre (all) | Select time slot only | `availableSlots(card, null)` |
| Modifier | Select play to modify | `validPlaysFor(modifier)` |
| Reaction | Pre-commit (held) | `canHoldReaction(card)` |

### Query: Valid Targets

```zig
pub const TargetingContext = struct {
    card: *const cards.Template,
    actor: *const Agent,
    encounter: *const Encounter,
    current_range: ?Reach,  // for focal manoeuvres
};

pub const TargetOption = struct {
    target: entity.ID,
    validity: TargetValidity,
    range: Reach,
    is_primary: bool,  // is this the current attention focus?
};

pub const TargetValidity = enum {
    valid,              // can target freely
    valid_with_penalty, // can target but awareness penalty applies
    out_of_range,       // too far/close for this technique
    invalid_type,       // target doesn't match (e.g., targeting self with attack)
    blocked,            // something prevents targeting (e.g., ally in way)
};

/// Returns all potential targets with validity status
/// UI can show all but gray out/annotate invalid ones
pub fn getTargetOptions(ctx: TargetingContext) []TargetOption {
    // For each enemy in encounter:
    //   - Check range validity (technique + weapon reach)
    //   - Check target type (enemy/self/ally)
    //   - Check attention (primary vs secondary)
    //   - Return with validity status
}
```

**UI contract**: Domain returns *all* targets with validity info. UI decides how to present (gray out, hide, annotate penalty).

### Query: Available Time Slots

```zig
pub const SlotQuery = struct {
    card: *const cards.Template,
    target: ?entity.ID,
    timeline: *const Timeline,
    weapon: ?*const weapon.Template,  // affects manoeuvre speed
};

pub const SlotOption = struct {
    time_start: f32,      // snapped to 0.1s
    time_end: f32,
    validity: SlotValidity,
    overlaps: []const entity.ID,  // cards this would overlap with
};

pub const SlotValidity = enum {
    valid,              // can place here
    channel_conflict,   // blocked by same-channel card
    exceeds_tick,       // would extend past 1.0
    range_invalid,      // target unreachable at this timing (due to prior manoeuvre)
};

/// Returns all 0.1s slot starts where this card could begin
pub fn getAvailableSlots(query: SlotQuery) []SlotOption {
    // For each 0.1s increment from 0.0 to (1.0 - duration):
    //   - Check channel availability
    //   - Check if card would fit
    //   - Note what it would overlap with
    //   - Return with validity
}
```

**UI contract**: Domain returns slot options. UI can show timeline with valid drop zones highlighted.

### Query: Play Preview

Before committing, UI needs to preview effects:

```zig
pub const PlayPreview = struct {
    stamina_cost: f32,
    time_cost: f32,
    focus_cost: f32,          // if non-default timing

    range_change: ?RangeChange,
    position_change: ?f32,

    overlapping_cards: []const entity.ID,
    synergies: []const SynergyPreview,  // bonuses from overlaps

    warnings: []const PlayWarning,
};

pub const PlayWarning = enum {
    target_not_primary,     // awareness penalty will apply
    standing_still,         // no footwork this tick
    overcommitting,         // >1s of actions
    range_will_change,      // manoeuvre will shift range mid-tick
    low_stamina,            // will be exhausted after this
};

pub fn previewPlay(
    timeline: *const Timeline,
    proposed: ProposedPlay,
    context: PlayContext,
) PlayPreview {
    // Calculate all effects without applying
    // Return preview for UI to display
}
```

**UI contract**: Domain provides rich preview. UI can show costs, warnings, synergies before player confirms.

### Command: Propose Play

The actual mutation when player confirms:

```zig
pub const ProposedPlay = struct {
    card: entity.ID,
    target: ?entity.ID,
    time_start: f32,
    modifiers: []const entity.ID,
};

pub const PlayResult = union(enum) {
    success: struct {
        play_index: usize,
        warnings: []const PlayWarning,
    },
    failure: PlayFailure,
};

pub const PlayFailure = enum {
    invalid_target,
    channel_conflict,
    insufficient_stamina,
    insufficient_focus,
    out_of_range,
    card_not_in_hand,
};

pub fn proposePlay(
    turn_state: *TurnState,
    proposed: ProposedPlay,
    context: PlayContext,
) PlayResult {
    // Validate and apply if valid
    // Return result for UI feedback
}
```

### Focal vs Propagating Targeting

**Key insight**: Most manoeuvres have a *focal* target even when effects propagate.

```zig
pub const TargetingMode = enum {
    single,         // one target, effects apply to it only
    focal,          // one target, but effects propagate (manoeuvres)
    self,           // targets self
    all_enemies,    // no target selection, affects all
    all_in_range,   // affects all enemies within technique's range
};

// On Technique/Template:
targeting: TargetingMode = .single,
```

**Examples:**
- `Thrust`: `.single` — hits one enemy
- `Advance`: `.focal` — toward one enemy, propagates to others
- `Sidestep`: `.self` — affects your position
- `Battle cry`: `.all_enemies` — affects all (concentration channel)
- `Sweep`: `.all_in_range` — hits everyone at current range

**UI flow for focal targeting:**
1. Player selects Advance card
2. UI queries `validFocalTargets()` → shows enemies with range info
3. Player clicks enemy A (at `far`)
4. UI queries `availableSlots()` → shows timeline
5. Player drags to 0.2s
6. UI calls `previewPlay()` → shows "Advance 2 steps toward A, 1 step toward B"
7. Player confirms → `proposePlay()`

### Current Target State

The "primary attention" target should be visible and manipulable:

```zig
// On AgentEncounterState or TurnState:
pub fn getPrimaryTarget(self: *const Self) ?entity.ID;
pub fn setPrimaryTarget(self: *Self, target: ?entity.ID) void;

// UI can show which enemy has focus
// Clicking enemy could switch primary (or require explicit action)
```

**UI contract**: Primary target is domain state, not just UI state. Domain tracks it; UI displays and allows changing.

### Range Display

UI needs current and projected range:

```zig
pub const RangeInfo = struct {
    target: entity.ID,
    current: Reach,
    after_committed: Reach,  // what it will be after current timeline resolves
    weapon_effective: bool,  // is your weapon effective at current range?
    technique_valid: bool,   // is selected technique valid at current range?
};

pub fn getRangeInfo(
    encounter: *const Encounter,
    actor: entity.ID,
    timeline: *const Timeline,
) []RangeInfo {
    // For each engagement, calculate current and projected range
}
```

**UI contract**: Domain provides both current and post-resolution range. UI can show "you'll be at X range after this tick."

### Summary: Domain Responsibilities

| Query | Returns | UI Uses For |
|-------|---------|-------------|
| `validTargetsFor` | Targets + validity | Target selection overlay |
| `availableSlots` | Time slots + validity | Timeline drop zones |
| `previewPlay` | Costs, effects, warnings | Confirmation dialog / inline preview |
| `getRangeInfo` | Current + projected range | Range indicators |
| `getPrimaryTarget` | Current attention focus | Focus indicator |
| `assessFlanking` | Flanking status | Position warnings |

The domain is *opinionated* about what's valid but *informative* about why. UI has flexibility in presentation but domain drives the rules.

---

## Deferral and Reaction Windows

### The Deferral Question

> "If opponent plays block→block→attack, can you defer your attack to their attack window?"

**Recommendation: No pure deferral.**

Reasons:
1. Simultaneous disclosure is core to the game's information asymmetry
2. True deferral creates second-guessing spirals
3. Complexity explosion

**Alternative: Reaction cards.**

Cards with `trigger = .on_opponent_action` that fire during resolution:
- Counter (respond to attack with attack)
- Riposte (respond to parried attack)
- Sidestep (respond to committed attack)

These provide tactical flexibility without undermining simultaneous commitment.

### Reaction Card Model

```zig
const counter = Template{
    .name = "counter",
    .tags = .{ .reaction = true, .offensive = true },
    .cost = .{ .stamina = 3.0, .focus = 1.0 },  // expensive
    .rules = &.{
        .{
            .trigger = .{ .on_event = .opponent_attacks },
            .valid = .{ .advantage_threshold = .{ .axis = .control, .op = .gte, .value = 0.4 }},
            .expressions = &.{
                .{
                    .effect = .{ .combat_technique = counter_technique },
                    .target = .event_source,
                },
            },
        },
    },
};
```

### Reaction Timing

Reactions fire during resolution, not commitment. The timeline model supports this:

```
Committed Timeline:
  Player: [Thrust 0.0-0.3]
  Enemy:  [Block 0.0-0.2][Attack 0.4-0.7]

Resolution with Reactions:
  0.0-0.3: Player thrust resolves vs enemy block
  0.4: Enemy attack begins → Player's Counter reaction triggers
  0.4-0.7: Counter resolves simultaneously with enemy attack
```

### Reaction Limits

To prevent reaction chains:
1. Each agent gets one reaction per tick
2. Reactions cost Focus (limits frequency)
3. Reactions cannot trigger reactions

---

## Opponent AI Implications

### Current AI

Mobs populate `combat_state.in_play` based on behavior patterns.

### Timeline-Aware AI

AI needs to:
1. Choose timing for actions (not just which actions)
2. Overlay footwork with attacks intelligently
3. Respect range constraints
4. Use reactions when advantageous

```zig
pub const AiPlan = struct {
    slots: []TimeSlot,
    held_reaction: ?*Template,  // reaction to use if triggered

    pub fn plan(mob: *Agent, engagement: *Engagement) AiPlan {
        // ... consider range, advantage, available techniques
    }
};
```

### Behavior Pattern Extensions

```zig
pub const BehaviorStep = struct {
    technique: TechniqueId,
    timing: TimingHint,
    overlay: ?TechniqueId,  // optional footwork overlay
};

pub const TimingHint = enum {
    early,      // 0.0-0.3
    mid,        // 0.3-0.6
    late,       // 0.6-1.0
    match_opponent,  // try to match opponent's timing
    gap_seeking,     // look for defensive gaps
};
```

---

## Decisions (2026-01-06 Discussion)

### Resolved

1. **Simultaneity**: Channel-based non-conflict (weapon, off_hand, footwork, concentration).

2. **Range gating**: Via `ReachRequirement` on techniques/weapons.

3. **Overlay bonuses**: Express via **rules on manoeuvre cards**. Stepping in strengthens attack; stepping back aids deflection. Generous defensive bonuses from movement—standing still while being attacked should be actively punished.

4. **Range change timing**: Manoeuvres specify "during" and "after" range effects. Most cases (90%+) don't need mid-tick recalculation; effects apply at resolution boundaries.

5. **Reaction trigger scope**: Any card trigger (`on_play`, `on_resolve`, events) can fire reactions, with per-card constraints/predicates.

6. **Maximum simultaneous techniques**: One per channel. Non-humanoids may have different channel counts but the model remains viable.

7. **Timeline granularity**: 100ms (10 slots per tick). A 0.25s move starting at 0 allows placement at 0.3, 0.4, etc.

8. **Manoeuvre availability**: Like techniques (Model B), some manoeuvres always available (pool), others situationally via draws. Can take modifiers.

### Needs Further Design

9. **Focus cost for timeline manipulation**: Agreed that non-default timing should cost Focus. Open sub-questions:
   - "Non-default" = altered during commit phase? Or any non-left-stacked position?
   - Removing a card: time collapses (current) vs cards stay at assigned positions?
   - Inserting: cost Focus to move existing cards to fit?

10. **Multiple opponents + range + manoeuvres**: How does positioning work when engaged with multiple enemies at different ranges?

11. **Manoeuvre conflicts / positioning contests**: When both combatants advance or both retreat, what resolves? Reuse `resolution.zig`?

12. **Stamina economy**: Baseline movement should be sustainable; flurries/acrobatics should be a gambit.

---

## Multi-Opponent Positioning

### The Real Problem

In any believable multi-opponent fight, 90% of staying alive is controlling positioning:
- Keep only one enemy in striking range at a time
- Use unpredictable movement
- Position so enemies obstruct each other
- Avoid flanking

The model should encourage this behavior, not abstract it away.

### Per-Engagement Range (Retained)

Keep independent `Engagement.range` per pair. There's nothing unrealistic about being at spear range with A and dagger range with B—it just means A is far and B is close. The model needs to handle the *consequences* of that (flanking, divided attention).

### Range Propagation Heuristic

When you manoeuvre toward one opponent, it affects others predictably:

```zig
/// Advancing on a distant enemy brings you somewhat closer to their allies
pub fn propagateRangeChange(
    encounter: *Encounter,
    actor: entity.ID,
    target: entity.ID,
    steps: i8,  // positive = closing, negative = opening
) void {
    // Apply full effect to target
    const target_eng = encounter.getEngagement(actor, target);
    target_eng.range = adjustRange(target_eng.range, steps);

    // Apply reduced effect to others (n-1 steps)
    if (@abs(steps) > 1) {
        const propagated = if (steps > 0) steps - 1 else steps + 1;
        for (encounter.engagementsFor(actor)) |eng| {
            if (eng.other != target) {
                eng.range = adjustRange(eng.range, propagated);
            }
        }
    }
}
```

**Examples:**
- Advance 2 steps on far enemy → also advance 1 step on their allies
- Retreat 3 steps → retreat 2 steps from everyone else
- Small adjustments (1 step) are target-specific—fine positioning

This keeps per-engagement simplicity while respecting spatial coherence.

### Flanking

When engaged with 2+ enemies, at least one is likely flanking. Rather than full 3D positioning, model flanking as an emergent condition:

```zig
pub const FlankingStatus = enum {
    none,           // single opponent or controlled positioning
    partial,        // 2 opponents, some angle
    surrounded,     // 3+ opponents or severe angle disadvantage
};

pub fn assessFlanking(encounter: *Encounter, agent: entity.ID) FlankingStatus {
    const engagements = encounter.engagementsFor(agent);
    const active_count = countActiveEngagements(engagements);

    if (active_count <= 1) return .none;

    // Check if any enemy has strong position advantage
    var flanking_enemies: u8 = 0;
    for (engagements) |eng| {
        if (eng.position < 0.35) flanking_enemies += 1;  // they have angle on us
    }

    if (flanking_enemies >= 2 or active_count >= 3) return .surrounded;
    if (flanking_enemies >= 1) return .partial;
    return .none;
}
```

**Flanking effects:**
- Defense effectiveness reduced (can't watch everyone)
- Hit location distribution shifts (exposed sides/back)
- Some manoeuvres become unavailable or penalized

**Counter-play:**
- Manoeuvres that improve position vs multiple enemies
- "Circle" to line enemies up
- "Disengage" to create space from all
- Prioritize eliminating flanking threat

### Attention vs Focus Cost

Rather than gating target switching with Focus cost, model **attention limits**:

```zig
pub const AttentionState = struct {
    primary: ?entity.ID,      // who we're actively fighting
    awareness: f32,           // 0-1, how much attention on secondaries

    // Acuity determines baseline awareness
    pub fn init(agent: *Agent) AttentionState {
        return .{
            .primary = null,
            .awareness = agent.stats.acuity * 0.1,  // acuity matters!
        };
    }
};
```

**Switching is free, but:**
- Attacks on non-primary target get penalty based on `awareness`
- Being attacked by non-primary: defense penalty based on `awareness`
- High Acuity = better peripheral awareness = smaller penalties

**Acuity payoff**: Finally useful for something other than perception checks!

### Manoeuvres for Multi-Opponent

New manoeuvre types needed:

| Manoeuvre | Effect |
|-----------|--------|
| Circle | Rotate position vs all enemies; try to line them up |
| Disengage | Open range from all enemies simultaneously |
| Pivot | Switch primary without penalty; improve position vs one |
| Hold ground | Accept worse position for stamina recovery |

These should be pool manoeuvres (always available) with situational effectiveness.

### Summary

- **Per-engagement range**: Retained, with propagation heuristic
- **Flanking**: Emergent from engagement count + position values
- **Attention**: Replaces Focus cost; Acuity-driven awareness
- **New manoeuvres**: Circle, Disengage, Pivot for multi-opponent control

---

## Manoeuvre Conflicts (Positioning Contest)

### The Problem

Both combatants play `advance` simultaneously. Or one `advances` while other `retreats`. What happens?

### Principles

1. **Manoeuvres should contest**: Both advancing isn't mutual; someone wins the engagement.
2. **Resolution should feel familiar**: Reuse advantage/stats mechanics from `resolution.zig`.
3. **Footwork skill matters**: Agility, speed, positioning stats influence outcome.

### Proposed Resolution

When conflicting manoeuvres overlap in time, trigger a **positioning contest**:

```zig
pub const ManoeuvreConflict = struct {
    aggressor: *Agent,      // who's closing
    defender: *Agent,       // who's maintaining/opening
    aggressor_move: *const Technique,
    defender_move: ?*const Technique,  // null = standing still
};

pub fn resolveManoeuvreConflict(
    conflict: ManoeuvreConflict,
    engagement: *Engagement,
    rng: *Random,
) ManoeuvreOutcome {
    // Factors:
    // - Engagement.position (who has better ground)
    // - Agent stats: speed, agility
    // - Current balance
    // - Technique-specific bonuses (lunge vs sidestep)

    const aggressor_score = calculateManoeuvreScore(conflict.aggressor, conflict.aggressor_move, engagement);
    const defender_score = if (conflict.defender_move) |dm|
        calculateManoeuvreScore(conflict.defender, dm, engagement)
    else
        calculateStationaryPenalty(conflict.defender, engagement);  // standing still = bad

    // Compare scores → determine outcome
    if (aggressor_score > defender_score + threshold) {
        return .aggressor_succeeds;  // range changes as aggressor wanted
    } else if (defender_score > aggressor_score + threshold) {
        return .defender_succeeds;  // range changes as defender wanted (or stays)
    } else {
        return .stalemate;  // partial effect, or neither gets full benefit
    }
}

pub const ManoeuvreOutcome = enum {
    aggressor_succeeds,
    defender_succeeds,
    stalemate,
    // could add: aggressor_advantage, defender_advantage for partial wins
};
```

### Conflict Categories

| Aggressor | Defender | Contest Type |
|-----------|----------|--------------|
| Advance | Retreat | Chase (speed vs speed) |
| Advance | Advance | Collision (who gets inside) |
| Advance | Sidestep | Angle (position vs agility) |
| Advance | Nothing | Free advance (but standing still penalty) |
| Retreat | Advance | Disengage (position + balance) |
| Retreat | Retreat | Mutual disengage (both get distance) |
| Sidestep | Sidestep | Angle battle (agility vs agility) |

### Standing Still Penalty

Critical design point: **not moving should hurt**. If you commit no footwork:
- Opponent's positioning succeeds automatically
- You get hit chance penalty (predictable target)
- Balance may degrade (reactive vs proactive)

```zig
fn calculateStationaryPenalty(agent: *Agent, engagement: *Engagement) f32 {
    // Base penalty for not moving
    var score: f32 = -0.3;

    // Partial mitigation if you have defensive technique active
    if (hasActiveDefense(agent)) score += 0.1;

    // Worse if opponent has positioning advantage
    score -= (0.5 - engagement.position) * 0.2;

    return score;
}
```

### Integration with resolution.zig

The contest should feel consistent with combat resolution:
- Use similar stat weights (speed, agility, balance)
- Apply engagement advantage modifiers
- Emit events for positioning changes

**Not** a full attack resolution—no damage, no armor—but uses the same framework for calculating scores and outcomes.

---

## Open Questions (Remaining)

### Focus Cost Mechanics (Detailed)

**Sub-question 1: What is "default" timing?**

Options:
- A: Default = immediately after previous card on same channel (left-stacked)
- B: Default = earliest available slot (0.0 if free)
- C: Default = any position during selection phase; commit phase changes cost Focus

**Sub-question 2: Removal behavior**

When removing a card with Focus:
- A: Time collapses (later cards shift left) — current behavior
- B: Cards stay at assigned positions, gap remains
- C: Player choice (collapse free, preserve costs Focus)

**Sub-question 3: Insertion**

When inserting a card:
- A: Must fit in existing gap (or fails)
- B: Can "push" later cards (costs extra Focus per card moved)
- C: Can only append (gaps require removal + re-add)

### Weapon Channel and Hand Count

Current: `weapon` channel implies "however many hands the weapon needs."

Need predicates for techniques that require specific configurations:
- `requires_two_handed`
- `requires_free_off_hand`
- `weapon_category = .blunt` (axe/mace/club)
- etc.

These go on Technique predicates, not channel logic.

### Weapon Speed Impact

Heavier weapons should slow manoeuvres:

```zig
pub fn effectiveManoeuvreTime(
    manoeuvre: *const Technique,
    weapon: ?*const weapon.Template,
) f32 {
    var time = manoeuvre.cost.time;
    if (weapon) |w| {
        // Heavy weapons slow footwork
        time *= w.manoeuvre_penalty;  // e.g., 1.0 for dagger, 1.3 for greatsword
    }
    return time;
}
```

### Stamina Economy

Baseline movement must be sustainable. Proposed:
- Simple footwork (maintain distance): ~1 stamina/tick
- Aggressive movement (advance, close): 1.5-2 stamina
- Acrobatic (sidestep, lunge): 2-3 stamina
- Standing still: 0 stamina but penalty to defense/position

Compare to stamina refresh rate (~2-3 per tick?). Ensures:
- Can always do basic movement
- Sustained aggression depletes stamina
- Pure defense viable but gives ground

---

## Implementation Plan

### Overview

Six phases, each with clear deliverables and test criteria. Later phases depend on earlier ones but can be developed incrementally within each phase.

```
Phase 1: Channel Foundation     [no deps]
Phase 2: Timeline Structure     [depends on 1]
Phase 3: Targeting & Range      [depends on 2]
Phase 4: Manoeuvres             [depends on 3]
Phase 5: Multi-Opponent         [depends on 4]
Phase 6: Reactions              [depends on 3, deferred]
```

---

### Phase 1: Channel Foundation

**Goal**: Establish channel system; prevent invalid simultaneous plays.

#### 1.1 Add ChannelSet type

Location: `src/domain/cards.zig`

```zig
pub const ChannelSet = packed struct {
    weapon: bool = false,
    off_hand: bool = false,
    footwork: bool = false,
    concentration: bool = false,

    pub fn conflicts(self: ChannelSet, other: ChannelSet) bool;
    pub fn isEmpty(self: ChannelSet) bool;
    pub fn merge(self: ChannelSet, other: ChannelSet) ChannelSet;
};
```

#### 1.2 Add channels to Technique

Location: `src/domain/cards.zig` - `Technique` struct

```zig
channels: ChannelSet = .{ .weapon = true },  // default: weapon channel
```

#### 1.3 Populate channels for existing techniques

Location: `src/content/` technique definitions

Audit existing techniques and assign appropriate channels:
- All attacks/parries: `.weapon = true`
- Shield techniques: `.off_hand = true`
- (No footwork techniques exist yet)

#### 1.4 Add channel validation to TurnState

Location: `src/domain/combat.zig`

```zig
pub fn wouldConflictOnChannel(
    self: *const TurnState,
    new_channels: ChannelSet,
    time_start: f32,
    time_end: f32,
    registry: *const CardRegistry,
) bool;
```

Note: Current `TurnState` doesn't track timing per-play. This validates *sequential* conflicts only. Full timeline validation comes in Phase 2.

#### 1.5 Validation in play commands

Location: `src/domain/apply.zig` or command handler

Add channel conflict check when adding plays. For now, reject if same channel as any existing play (conservative; relaxed in Phase 2).

**Tests:**
- `test "cannot play two weapon techniques"`
- `test "channel conflict detection"`
- `test "ChannelSet.conflicts symmetry"`

**Deliverable**: Playing Thrust then Swing in same turn rejected.

---

### Phase 2: Timeline Structure

**Goal**: Replace flat play list with time-aware timeline; enable positioned plays.

#### 2.1 Create TimeSlot and Timeline types

Location: `src/domain/combat.zig` (or new `src/domain/timeline.zig`)

```zig
pub const TimeSlot = struct {
    time_start: f32,
    time_end: f32,
    play: Play,

    pub fn overlaps(self: TimeSlot, other: TimeSlot) bool;
    pub fn overlapsWith(self: TimeSlot, start: f32, end: f32) bool;
};

pub const Timeline = struct {
    pub const max_slots = 12;
    pub const granularity: f32 = 0.1;

    slots: [max_slots]TimeSlot = undefined,
    slot_count: usize = 0,

    pub fn canInsert(self, start: f32, end: f32, channels: ChannelSet, registry: *const CardRegistry) bool;
    pub fn insert(self, start: f32, end: f32, play: Play, channels: ChannelSet, registry: *const CardRegistry) !void;
    pub fn remove(self, index: usize) void;
    pub fn findByCard(self, card_id: entity.ID) ?usize;
    pub fn channelsOccupiedAt(self, time: f32, registry: *const CardRegistry) ChannelSet;
    pub fn nextAvailableStart(self, channels: ChannelSet, duration: f32, registry: *const CardRegistry) ?f32;

    // Iteration
    pub fn slots(self) []const TimeSlot;
    pub fn slotsOverlapping(self, start: f32, end: f32) SlotIterator;
};
```

#### 2.2 Migrate TurnState to use Timeline

Location: `src/domain/combat.zig`

```zig
pub const TurnState = struct {
    timeline: Timeline = .{},
    focus_spent: f32 = 0,
    stack_focus_paid: bool = false,

    // Preserve existing API where possible
    pub fn plays(self) []const TimeSlot;  // was []const Play
    pub fn addPlay(self, play: Play, time_start: f32, registry: *const CardRegistry) !void;
    pub fn removePlay(self, index: usize) void;
    pub fn clear(self) void;
};
```

#### 2.3 Update TickResolver to read from Timeline

Location: `src/domain/tick.zig`

`commitPlayerCards` already calculates `time_start`/`time_end`. Change to read from `Timeline.slots` instead of computing.

```zig
pub fn commitPlayerCards(self: *TickResolver, player: *Agent, w: *World) !void {
    const enc_state = ...;
    for (enc_state.current.timeline.slots()) |slot| {
        try self.addAction(.{
            .time_start = slot.time_start,
            .time_end = slot.time_end,
            // ... rest from slot.play
        });
    }
}
```

#### 2.4 Update commands to provide timing

Location: command handler / `apply.zig`

Commands that add plays need to specify timing. Options:
- A: Default to "next available" (preserves current behavior)
- B: Require explicit timing
- C: Both (default available, explicit optional)

**Recommend C**: Add optional `time_start` to play commands; default to `timeline.nextAvailableStart()`.

#### 2.5 Basic UI timeline indication

Location: `src/presentation/views/combat.zig`

Minimal: Show time_start/time_end for each committed play. No drag-to-position yet.

**Tests:**
- `test "Timeline.canInsert respects channels"`
- `test "Timeline.canInsert respects time overlap"`
- `test "Timeline.nextAvailableStart finds gaps"`
- `test "TurnState migration preserves behavior"`
- `test "TickResolver reads timeline correctly"`

**Deliverable**: Plays have explicit timing; footwork can overlap weapon channel.

---

### Phase 3: Targeting & Range

**Goal**: Range-aware targeting; domain queries for UI.

> **Implementation Note (2026-01-06)**: The original plan below proposed new types (`TargetingMode`, `ReachRequirement`). Code review revealed these duplicate existing primitives:
> - `TargetingMode` ≈ `TargetQuery` (cards.zig:160)
> - `ReachRequirement` ≈ `Predicate.range` (cards.zig:146)
> - `weapon.effective_range` ≈ `weapon.Offensive.reach` (weapon.zig:57)
>
> **Revised approach**: Use existing predicates in card rules. See "Implementation Discovery: Predicate Evaluation Architecture" section below for details on the blocker discovered.

#### ~~3.1 Add TargetingMode to techniques~~ (SUPERSEDED - use TargetQuery)

Location: `src/domain/cards.zig`

```zig
pub const TargetingMode = enum {
    single,
    focal,
    self,
    all_enemies,
    all_in_range,
};

// On Technique:
targeting: TargetingMode = .single,
```

#### ~~3.2 Add ReachRequirement~~ (SUPERSEDED - use Predicate.range)

Location: `src/domain/cards.zig` or `src/domain/combat.zig`

```zig
pub const ReachRequirement = struct {
    min: Reach,
    max: Reach,
    optimal: ?Reach = null,

    pub fn isValid(self, current: Reach) bool;
    pub fn penaltyAt(self, current: Reach) f32;  // 0 at optimal, increases with distance
};

// On Technique:
reach: ReachRequirement = .{ .min = .clinch, .max = .far },

// On weapon.Template:
effective_range: ReachRequirement,
```

#### ~~3.3 Implement targeting queries~~ (SUPERSEDED - predicates handle this)

Location: new `src/domain/targeting.zig`

```zig
pub const TargetOption = struct {
    target: entity.ID,
    validity: TargetValidity,
    range: Reach,
    is_primary: bool,
};

pub const TargetValidity = enum {
    valid,
    valid_with_penalty,
    out_of_range,
    invalid_type,
};

pub fn getTargetOptions(
    card: *const cards.Template,
    actor: *const Agent,
    encounter: *const Encounter,
) []TargetOption;

pub fn getAvailableSlots(
    card: *const cards.Template,
    target: ?entity.ID,
    timeline: *const Timeline,
    context: SlotContext,
) []SlotOption;
```

#### 3.4 Add range validation to play commands (REVISED)

Location: `src/domain/apply.zig`

**Original approach**: Check technique.reach and weapon.effective_range
**Revised approach**: Fix `evaluateValidityPredicate` to handle `Predicate.range` with engagement context

See "Implementation Discovery" section below for the blocker.

#### ~~3.5 Implement starting range calculation~~ (DEFERRED)

Encounters start at `.far`. Manoeuvres (Phase 4) will allow closing distance.
Not blocking for basic range validation.

#### ~~3.6 Wire range into Encounter initialization~~ (DEFERRED)

See 3.5.

#### 3.7 Add Play.target field ✓ DONE

Location: `src/domain/combat.zig` - `Play` struct

```zig
pub const Play = struct {
    action: entity.ID,
    target: ?entity.ID = null,  // NEW: who this targets
    // ... rest unchanged
};
```

**Tests:**
- ~~`test "ReachRequirement.isValid"`~~ (type removed)
- ~~`test "getTargetOptions returns all enemies with validity"`~~ (using predicates)
- `test "play rejected when out of range"` (needs predicate evaluation fix)
- ~~`test "starting range respects weapon reaches"`~~ (deferred)

**Deliverable**: Can't play techniques when out of range (via `Predicate.range` in card rules).

---

### Implementation Discovery: Predicate Evaluation Architecture (2026-01-06)

Investigation during T003 revealed important context about how predicates are evaluated.

#### Two Predicate Evaluators

**1. `evaluateValidityPredicate`** (apply.zig:935)
- Called by `rulePredicatesSatisfied()` during card selection
- Has: `template`, `actor`
- Missing: engagement context, target
- **Current behavior for `.range`/`.weapon_reach`**: returns `false` (TODO comment)

**2. `evaluatePredicate`** (apply.zig:973)
- Called during effect filtering (which targets does effect apply to)
- Has: `card`, `actor`, `target`, `engagement`
- **Actually evaluates `.range`** against `engagement.range`

#### The Problem

Cards with `.range` predicates in `rule.valid` are currently **unplayable** because `evaluateValidityPredicate` returns `false` for range checks. No cards use this yet, so no actual bug—but the feature is unusable.

#### Design Question: Multi-Enemy Range Validation

At card selection time, which engagement(s) should range be checked against?

**Option A: Any enemy in range**
```zig
// Card playable if valid against ANY engagement
for (encounter.engagementsFor(actor.id)) |eng| {
    if (evaluateValidityPredicate(pred, template, actor, eng)) return true;
}
return false;
```
- Pro: Simple mental model ("can I hit anyone?")
- Pro: Works naturally for AoE cards
- Con: Evaluates N engagements × M cards per frame

**Option B: Target-first selection**
- Player selects target, then card selection filters by that target's range
- Pro: Single engagement check per card
- Con: Changes UI flow significantly
- Con: What about self-target or AoE cards?

**Option C: Defer to resolution**
- Allow any card to be selected
- Validate range when play resolves against chosen target
- Pro: Simplest selection logic
- Con: "Whiff" scenarios if target moved/died
- Con: Feels bad to waste a card

**Option D: Cached validity**
- Pre-compute "playable cards" when engagement state changes
- Store per-card validity flags
- Pro: O(1) lookup during selection
- Con: Cache invalidation complexity
- Con: Memory overhead

#### Performance Consideration

Current UI evaluates every potentially playable card every frame. With N enemies:
- Option A: O(cards × enemies × predicates) per frame
- Caching: O(cards × enemies × predicates) on engagement change, O(1) per frame

For typical combat (1-3 enemies, ~20 cards), probably fine. At scale (5+ enemies, 50+ cards), may need caching.

#### Recommendation

**Option A (any enemy)** for correctness, with caching added if profiling shows need. The "any enemy in range" semantic is intuitive and handles edge cases naturally.

Implementation:
1. Add optional `engagement: ?*const Engagement` to `evaluateValidityPredicate`
2. In `rulePredicatesSatisfied`, iterate engagements, short-circuit on first `true`
3. For cards without `.range` predicates, single evaluation (no engagement needed)

#### Related: weapon.Offensive.reach

Weapons already model reach per offensive mode:
```zig
pub const Offensive = struct {
    reach: combat.Reach,
    // ...
};
```

`Predicate.weapon_reach` can compare against this. Need helper to get primary weapon's reach from `Armament` union.

---

### Phase 4: Manoeuvres

**Goal**: Footwork cards that change positioning; overlay with arm techniques.

#### 4.1 Create basic manoeuvre templates

Location: `src/content/cards/` (new file `manoeuvres.zig` or similar)

Start with pool manoeuvres (always available):
- `advance` - close 1 step on focal target
- `retreat` - open 1 step from focal target
- `sidestep` - position improvement, no range change
- `hold` - no movement, stamina recovery

```zig
pub const advance = Template{
    .name = "advance",
    .tags = .{ .manoeuvre = true },
    .cost = .{ .stamina = 1.5, .time = 0.3 },
    .playable_from = .always_available,
    .technique_info = .{
        .channels = .{ .footwork = true },
        .targeting = .focal,
        .reach = .{ .min = .near, .max = .far },  // can't advance from clinch
    },
    .rules = &.{
        .{ .trigger = .on_resolve, .expressions = &.{
            .{ .effect = .{ .modify_range = .{ .steps = -1 }}, .target = .focal_engagement },
        }},
    },
};
```

#### 4.2 Implement range modification effect

Location: `src/domain/cards.zig` - `Effect` union, and effect application

```zig
pub const Effect = union(enum) {
    // ... existing
    modify_range: struct {
        steps: i8,  // negative = closer
        propagate: bool = true,  // apply n-1 to other engagements
    },
};
```

Location: `src/domain/apply.zig` - effect application

```zig
fn applyModifyRange(
    effect: Effect.modify_range,
    actor: entity.ID,
    focal_target: entity.ID,
    encounter: *Encounter,
) void {
    // Apply full steps to focal
    // Apply steps-1 to others if propagate
}
```

#### 4.3 Add manoeuvres to Agent pool

Location: `src/domain/combat.zig` - `Agent` initialization

Ensure basic manoeuvres are in `always_available` for all agents.

#### 4.4 Implement overlay synergy via rules

Location: manoeuvre card definitions

Express bonuses as conditional effects:

```zig
// On advance card:
.rules = &.{
    // Range change
    .{ .trigger = .on_resolve, ... },
    // Synergy: if overlapping offensive technique, damage bonus
    .{
        .trigger = .on_resolve,
        .valid = .{ .has_overlapping = .{ .tags = .{ .offensive = true }}},
        .expressions = &.{
            .{ .effect = .{ .modify_overlapping_play = .{ .damage_mult = 1.1 }}, ... },
        },
    },
};
```

This requires new predicate and effect types:
- `Predicate.has_overlapping: TagSet`
- `Effect.modify_overlapping_play: ModifyPlay`

#### 4.5 Implement standing still penalty

Location: `src/domain/resolution.zig` or tick resolution

During resolution, check if defender has any footwork in timeline:
```zig
fn hasFootworkThisTick(timeline: *const Timeline, registry: *const CardRegistry) bool;

// In hit chance calculation:
if (!hasFootworkThisTick(defender_timeline, registry)) {
    hit_chance += standing_still_penalty;  // e.g., 0.1
}
```

#### 4.6 UI: Allow footwork card placement

Location: `src/presentation/`

Enable dragging footwork cards to timeline. Can overlay with existing weapon plays.

**Tests:**
- `test "advance closes range by 1"`
- `test "advance propagates to other engagements"`
- `test "footwork overlaps weapon channel"`
- `test "advance + thrust gives damage bonus"`
- `test "standing still penalty applied"`

**Deliverable**: Advance + thrust works with bonus; sidestep while attacking works.

---

### Phase 5: Multi-Opponent

**Goal**: Attention system; flanking; positioning contests.

#### 5.1 Add attention tracking

Location: `src/domain/combat.zig` - `AgentEncounterState`

```zig
pub const AttentionState = struct {
    primary: ?entity.ID = null,
    awareness: f32,  // derived from Acuity

    pub fn init(agent: *const Agent) AttentionState;
    pub fn penaltyFor(self, target: entity.ID) f32;
};

// On AgentEncounterState:
attention: AttentionState,
```

#### 5.2 Apply attention penalties

Location: `src/domain/resolution.zig`

When attacking/defending against non-primary target:
```zig
fn getAttentionModifier(
    actor: *const Agent,
    target: entity.ID,
    enc_state: *const AgentEncounterState,
) f32;
```

Apply to hit chance, defense effectiveness.

#### 5.3 Implement flanking assessment

Location: `src/domain/combat.zig`

```zig
pub const FlankingStatus = enum { none, partial, surrounded };

pub fn assessFlanking(encounter: *const Encounter, agent: entity.ID) FlankingStatus;
```

#### 5.4 Apply flanking effects

Location: `src/domain/resolution.zig`

- Defense penalty when flanked
- Hit location shift toward exposed sides (integrate with stance system when ready)

#### 5.5 Implement positioning contests

Location: new `src/domain/positioning.zig`

```zig
pub const ManoeuvreOutcome = enum {
    aggressor_succeeds,
    defender_succeeds,
    stalemate,
};

pub fn resolveManoeuvreConflict(
    aggressor: *const Agent,
    defender: *const Agent,
    aggressor_move: *const Technique,
    defender_move: ?*const Technique,
    engagement: *const Engagement,
    rng: *Random,
) ManoeuvreOutcome;
```

#### 5.6 Integrate positioning contests into tick resolution

Location: `src/domain/tick.zig`

Before resolving attacks, resolve manoeuvre conflicts:
1. Find overlapping footwork from opposing agents
2. Call `resolveManoeuvreConflict`
3. Apply range changes based on outcome
4. Then proceed with attack resolution

#### 5.7 Add multi-opponent manoeuvres

Location: `src/content/cards/manoeuvres.zig`

- `circle` - improve position vs all, try to line up
- `disengage` - open range from all
- `pivot` - switch primary, position bonus vs one

**Tests:**
- `test "attention penalty on non-primary target"`
- `test "Acuity improves awareness"`
- `test "flanking detected with 2+ enemies"`
- `test "positioning contest advance vs retreat"`
- `test "standing still loses positioning contest"`
- `test "circle improves position vs multiple"`

**Deliverable**: Multi-opponent positioning works; attention matters.

---

### Phase 6: Reactions (Deferred)

**Goal**: Cards that trigger during resolution.

#### 6.1 Add reaction slot to commitment

```zig
pub const AgentEncounterState = struct {
    // ...
    held_reaction: ?entity.ID = null,
};
```

#### 6.2 Implement reaction triggers

Extend event system to check for reaction triggers during resolution.

#### 6.3 Handle reaction timing

Reactions insert into timeline at trigger point.

#### 6.4 AI reaction decisions

AI evaluates whether to use held reaction.

**Deferred**: Full design TBD. Foundation (channels, timeline, events) supports it.

---

### Phase Summary

| Phase | Key Deliverable | Est. Scope |
|-------|-----------------|------------|
| 1 | Channel conflicts | Small |
| 2 | Timeline structure | Medium |
| 3 | Targeting + range | Medium |
| 4 | Manoeuvres | Medium-Large |
| 5 | Multi-opponent | Large |
| 6 | Reactions | Deferred |

**Recommended order**: 1 → 2 → 3 → 4 → 5. Phase 6 when needed.

**Parallel opportunities**:
- Content (manoeuvre cards) can be drafted during Phase 2-3
- UI timeline work can start during Phase 2
- AI manoeuvre behavior can be developed during Phase 4

---

### Migration Notes

#### Breaking Changes

- `TurnState.plays_buf` → `TurnState.timeline`
- `Play` gains `target` field
- `Technique` gains `channels`, `targeting`, `reach` fields
- Play commands need timing parameter (optional, defaults available)

#### Backward Compatibility

- Existing techniques default to `.weapon` channel, `.single` targeting, full reach
- Existing plays default to sequential timing
- Tests should continue passing after each phase

#### Content Updates Required

- Phase 1: Assign channels to all techniques
- Phase 3: Assign reach to all techniques; effective_range to weapons
- Phase 4: Create manoeuvre cards
- Phase 5: Create multi-opponent manoeuvres

---

## Compatibility Notes

### Preserved Concepts

- `Play` struct (gains timeline metadata)
- `TurnState` (uses Timeline internally)
- `Engagement` (gains range enforcement)
- `CommittedAction` (unchanged interface)
- `TickResolver` (reads from Timeline)

### Breaking Changes

- `TurnState.plays_buf` → `TurnState.timeline`
- `Technique` gains `channels` field (requires content update)
- Play validation adds range + channel checks

### Migration Path

1. Add new fields with defaults
2. Update content incrementally
3. Enable validation after content is updated

---

## Appendix: Channel Assignment Guidelines

### Weapon Channel

Anything using the primary weapon arm(s):
- All attacks (thrust, swing, etc.)
- Weapon-based defenses (parry, deflect)
- Two-handed techniques (both weapon + off_hand)

### Off-Hand Channel

Off-hand specific actions:
- Shield block
- Off-hand strike
- Buckler punch
- Cloak manipulation

### Footwork Channel

All lower-body and positioning:
- Advance, retreat, sidestep
- Kicks, knee strikes
- Stance changes
- Jump attacks (also weapon)

### Concentration Channel

Mental/sensory focus:
- Spellcasting
- Perception checks
- Feints (the mental component)
- Taunts, battle cries

### Full-Body (Compound)

Occupies multiple channels:
- Grapple (weapon + off_hand + footwork)
- Tackle (footwork + weapon)
- Somersault attack (all physical)