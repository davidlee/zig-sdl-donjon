# Stance System Design

> **Revision**: 2025-12-27. Committed to compositional model; enum heights; pipeline synthesis; deferred relative angle. See Open Questions for remaining decisions.

## Problem

Hit location weighting needs to work across body types (humanoids, oozes, centaurs). The current `base_hit_chance` on body parts doesn't capture:

1. **Positional context** - a prone body is "all low" but anatomy hasn't changed
2. **Dynamic positioning** - arms can be high/mid/low depending on guard
3. **Technique interaction** - a spear thrust exposes the hands

## Core Insight

**Stance is positional, not anatomical.**

- Body = pure anatomy (what parts exist, connections, wound capacity)
- Stance = how those parts are arranged in space right now
- Techniques can force stance changes, creating tactical consequences

## Data Model

### Height Representation

**Decision: enum `{ low, mid, high }`**

- Simple for defense matching ("high guard covers high")
- Clean technique targeting ("targets mid")
- Creates clear tactical choices with stamina cost to adjust
- Gradient attacks (slash centered high but tails into mid) modeled as `targets: .high, secondary: ?Height`

Continuous f32 deferred — adds complexity without proportional gameplay benefit. The interface is card-based; players don't need to intuit probability distributions.

### Core Structures

```zig
// body.zig
pub const Height = enum { low, mid, high };

pub const PartExposure = struct {
    tag: PartTag,
    side: Side,           // for L|R matching
    hit_chance: f32,      // base probability
    height: Height,
};

// Part loses base_hit_chance - exposure is now compositional
```

### Attack Height Mechanics

```zig
// cards.zig Technique
target_height: Height = .mid,         // primary target zone
secondary_height: ?Height = null,     // for attacks that span zones (e.g. slash high→mid)

// Resolution:
// - Parts at target_height: full hit_chance
// - Parts at secondary_height (if set): reduced hit_chance (0.5x)
// - Parts at other heights: minimal hit_chance (0.1x)
```

**Example attacks:**
- Downward slash: `target: .high, secondary: .mid` - centered high, can hit mid
- Thrust: `target: .mid, secondary: null` - tight cluster at mid
- Leg sweep: `target: .low, secondary: null` - low only

### Defense Height Mechanics

**TODO: Needs development to fit compositional model.**

Current sketch:
```zig
// Defense technique contributes guard position
guard_height: Height,
covers_adjacent: bool = false,  // if true, partial coverage of adjacent heights

// Resolution:
// - Parts at guard_height: hit_chance reduced (0.3x)
// - Parts at adjacent height (if covers_adjacent): hit_chance reduced (0.6x)
// - Parts at opposite height: full hit_chance (opening)
```

**Reaction cost**: adjusting defense one "step" (low→mid, mid→high) costs stamina. This creates tactical depth — feint high, strike low.

### Resolution Algorithm

The core question: **does defense affect hit chance, hit location, or both?**

**Answer: Both, in sequence.**

```
1. Synthesize attacker's exposures (grip + arm + body contributions)
2. Synthesize defender's exposures (grip + arm + body contributions)

3. Calculate base hit chance:
   - Technique difficulty
   - Weapon accuracy
   - Stakes modifier
   - Engagement advantage (pressure, control, position)
   - Attacker/defender balance

4. Apply defense coverage to hit chance:
   - If defender's guard_height matches attack's target_height: penalty to hit
   - If covers_adjacent and attack is adjacent: smaller penalty
   - If attack targets opening (opposite height): bonus to hit

5. Roll outcome: hit / miss / blocked / parried / deflected / dodged / countered

6. If hit, select location:
   a. Get defender's current stance exposures
   b. Filter by technique's target_height (primary = 1.0x, secondary = 0.5x, other = 0.1x)
   c. Apply technique's target_side preference (lead/rear bonus)
   d. Random selection from weighted distribution

7. Resolve damage through armor to selected location
```

Defense thus provides a **global hit penalty** (covering the targeted zone) AND **influences where you get hit** (via stance exposures). A high guard both makes high attacks harder to land AND shifts your body to expose different targets.

## Compositional Stance Model

Rather than named stances with combinatorial explosion, stance **emerges** from composing two independent axes:

### Contribution Axes

```
Arms/Grip (from weapon + technique)     Legs/Body (from footwork/maneuver)
───────────────────────────────────     ──────────────────────────────────
Grip category (weapon property):        Facing:
  - single_hand                           - squared (direct)
  - two_hand_long                         - bladed (lead side forward)
  - two_hand_polearm / half_grip
  - polearm_extended                    Weight distribution:
  - main_and_off                          - back-weighted (-1)
                                          - neutral (0)
Arm position (technique modifier):        - forward-leaning (+1)
  - height: high / mid / low
  - extension: retracted ↔ extended     Width:
                                          - narrow / normal / wide
```

### Composition Flow

```
1. Weapon grip category → base arm exposure pattern
2. Attack/defense technique → modifies arm height + extension
3. Footwork/maneuver card → body stance (facing, weight, width)
4. Body facing → applies lead/rear modifier to arm exposures
5. Synthesize → effective exposure map for resolution
```

### Facing as Modifier

Bladed stance exposes the lead side more, protects the rear. This is a **modifier** applied to arm exposures after grip/technique resolve:

```zig
pub const BodyContribution = struct {
    facing: Facing,
    weight: f32,              // -1 back, +1 forward
    width: Width,

    // Modifiers applied to arm-side exposures
    lead_exposure_mod: f32,   // e.g., +0.15 for bladed
    rear_exposure_mod: f32,   // e.g., -0.10 for bladed
};

pub const Facing = enum {
    squared,       // 0 modifier both sides
    bladed_left,   // left side leads
    bladed_right,  // right side leads
};
```

Resolution uses `agent.dominant_side` to determine which arm is "lead" vs "rear".

### Grip Categories

Fold similar weapon grips to reduce combinatorics:

| Category | Weapons | Characteristics |
|----------|---------|-----------------|
| `single_hand` | rapier, arming sword, messer, saber | One arm active, off-hand free or incidental |
| `two_hand_long` | longsword, greatsword, katana | Both hands on hilt, full extension |
| `two_hand_short` | half-sword, halberd at guard, shortened spear | Both hands, choked up, more control |
| `polearm_extended` | spear at reach, pike, halberd extended | Maximum reach, hands spread on shaft |
| `main_and_off` | sword+buckler, sword+dagger, rapier+cloak | Primary weapon + active off-hand defense/offense |

Each category defines a base exposure pattern for the arms/hands.

### Technique Contributions

Attack and defense techniques modify the arm configuration:

```zig
// cards.zig Technique
pub const ArmContribution = struct {
    height: ?Height = null,         // high/mid/low override
    extension: ?f32 = null,         // 0.0 retracted ↔ 1.0 full extension
    hand_exposure: ?f32 = null,     // extra exposure for hands (thrust = high)
    target_side: ?SidePreference = null,  // attack side preference
    arc: AttackArc = .level,        // overhead/level/rising
};

pub const SidePreference = enum {
    lead,       // target defender's lead side
    rear,       // target defender's rear side
    either,     // no preference (default)
};

pub const AttackArc = enum {
    overhead,  // downward cuts, hammerfist — can hit .top facing
    level,     // horizontal cuts, thrusts — default
    rising,    // uppercuts, rising cuts — can hit .bottom facing
};

// On Technique:
arm_contribution: ArmContribution = .{},
```

**Examples:**
- Thrust: `{ .height = .mid, .extension = 0.9, .hand_exposure = 0.15 }`
- High guard: `{ .height = .high, .extension = 0.3 }`
- Half-sword thrust: `{ .height = .mid, .extension = 0.6 }` (shorter reach)
- Inside line attack: `{ .height = .mid, .extension = 0.8, .target_side = .lead }`
- Overhead chop: `{ .height = .high, .extension = 0.9, .arc = .overhead }`
- Uppercut: `{ .height = .low, .extension = 0.7, .arc = .rising }`

Side preference affects hit location weighting — parts on the targeted side get bonus hit chance. Not a sniper shot, just a tendency.

### Footwork Contributions

Maneuver cards contribute body stance:

```zig
pub const BodyContribution = struct {
    facing: ?Facing = null,
    weight: ?f32 = null,
    width: ?Width = null,
    crouch: ?f32 = null,          // 0 standing ↔ 1 full crouch
};

// On maneuver card:
body_contribution: BodyContribution = .{},
```

**Examples:**
- Advance: `{ .weight = 0.4, .facing = .bladed_dominant }`
- Retreat: `{ .weight = -0.5 }`
- Sidestep: `{ .facing = .bladed_off }` (switch lead)
- Crouch: `{ .crouch = 0.6, .width = .wide }`

### Synthesis Algorithm

Synthesis is a **pipeline of pure transforms** — each step takes exposures in, returns exposures out, no mutation.

```zig
pub const ExposureTransform = *const fn ([]const PartExposure) []const PartExposure;

/// Pipeline: each transform is a pure function that returns new exposures
pub fn synthesizeExposures(
    grip: GripCategory,
    arm_mods: ArmContribution,
    body_mods: BodyContribution,
    dominant_side: Side,
    allocator: Allocator,
) ![]const PartExposure {
    // Each step is a pure function: []PartExposure → []PartExposure
    const base = grip.baseExposures();

    const with_height = applyArmHeight(base, arm_mods.height, allocator);
    const with_extension = applyArmExtension(with_height, arm_mods.extension, allocator);
    const with_hands = applyHandExposure(with_extension, arm_mods.hand_exposure, allocator);

    const lead_side = resolveLead(body_mods.facing, dominant_side);
    const with_facing = applyFacingMods(with_hands, lead_side, body_mods, allocator);
    const with_crouch = applyCrouch(with_facing, body_mods.crouch, allocator);
    const final = applyWeight(with_crouch, body_mods.weight, allocator);

    return final;
}

// Each transform is independently testable:
fn applyArmHeight(exposures: []const PartExposure, height: ?Height, alloc: Allocator) []const PartExposure;
fn applyArmExtension(exposures: []const PartExposure, extension: ?f32, alloc: Allocator) []const PartExposure;
fn applyHandExposure(exposures: []const PartExposure, delta: ?f32, alloc: Allocator) []const PartExposure;
fn applyFacingMods(exposures: []const PartExposure, lead: Side, body: BodyContribution, alloc: Allocator) []const PartExposure;
fn applyCrouch(exposures: []const PartExposure, crouch: ?f32, alloc: Allocator) []const PartExposure;
fn applyWeight(exposures: []const PartExposure, weight: ?f32, alloc: Allocator) []const PartExposure;
```

**Benefits:**
- Each transform is pure and independently testable
- Order can be reasoned about without hidden state
- Easy to insert/remove transforms
- Allocation strategy is explicit

**Optimization note:** For comptime-known contributions, consider arena allocation or comptime evaluation.

### Conflict Handling

When arm and body contributions conflict:

1. **Impossible pairings**: Some combinations are mechanically invalid
   - Can't do polearm_extended from full crouch
   - System rejects pairing at card-play validation

2. **Disadvantaged pairings**: Some combinations work but poorly
   - High guard + forward lunge = overextended, penalty to recovery
   - Represented as worse exposure or stamina cost

3. **Synergistic pairings**: Some combinations are better than parts
   - Thrust + advance = momentum bonus
   - Could grant damage/accuracy bonus beyond just exposure math

### Data Footprint Comparison

**Named stances approach:**
- N grip types × M body stances × P technique variants = explosion
- 5 grips × 4 facings × 3 heights × 2 extensions = 120 named stances

**Compositional approach:**
- 5 grip base patterns
- ~6 body stance presets (or freeform contribution)
- Per-technique arm modifiers (3-4 floats)
- Synthesis algorithm

Much smaller data footprint, richer expression space.

## Relative Angle and Part Facing

> **Status: DEFERRED.** This section validates that the compositional model can support flanking/rear attacks. Implementation priority is lower than core height/side mechanics. The model is sound; defer until height targeting is working.

Stance composition tells us how the *attacker* is positioned. We also need to model *relative angle* — whether the attacker has flanked or gotten behind the defender.

### Angle as Engagement Property

Angle is relational (between two combatants), so it lives on `Engagement`:

```zig
// combat.zig Engagement gains:
pub const RelativeAngle = enum {
    frontal,        // facing each other directly
    inside,         // attacker on defender's weapon side (~30-45°)
    outside,        // attacker on defender's off-hand side (~30-45°)
    flank,          // ~90° - full side
    rear,           // behind (~135-180°)
};

angle: RelativeAngle = .frontal,
```

### Part Facing (One Field, No Duplication)

Each body part has a primary facing — the direction it naturally presents from:

```zig
pub const PrimaryFacing = enum {
    front,   // torso, face, kneecap, front of thigh
    back,    // spine, back of head, back of knee
    outer,   // outer arm/leg surfaces (combines with side)
    inner,   // armpits, inner thighs
    top,     // top of head, shoulders - accessible from overhead
    bottom,  // soles of feet, underside of chin - rarely accessible
};

// On PartDef (one new field):
facing: PrimaryFacing = .front,
```

**No "any" facing.** Previously this was a cop-out for parts like groin/crown. Better solutions:
- **Crown of head**: `facing = .top` — accessible from overhead attacks or when target is prone/crouching
- **Groin**: `facing = .front` with low height — already modeled by height system

The combination of height + facing + attack angle provides sufficient discrimination without a catch-all.

**No part duplication.** The knee is one part. Attack angle determines whether you're hitting the kneecap or the back of the knee — same part, different accessibility and armor coverage.

### Accessibility Derivation

```zig
pub const AccessLevel = enum {
    full,      // 1.0x hit chance
    partial,   // 0.5x hit chance
    grazing,   // 0.2x hit chance
    none,      // 0 (or tiny lucky-hit chance)
};

fn deriveAccess(
    part_facing: PrimaryFacing,
    part_side: Side,
    attack_angle: RelativeAngle,
    attack_arc: AttackArc,  // new: overhead/level/rising
    defender_dominant: Side,
) AccessLevel {
    return switch (part_facing) {
        .front => switch (attack_angle) {
            .frontal => .full,
            .inside, .outside => .partial,
            .flank => .grazing,
            .rear => .none,
        },
        .back => switch (attack_angle) {
            .rear => .full,
            .flank => .partial,
            .inside, .outside => .grazing,
            .frontal => .none,
        },
        .outer => blk: {
            const part_is_lead = (part_side == defender_dominant);
            break :blk switch (attack_angle) {
                .inside => if (part_is_lead) .full else .grazing,
                .outside => if (!part_is_lead) .full else .grazing,
                .flank => .partial,
                .frontal, .rear => .grazing,
            };
        },
        .inner => blk: {
            // Inverse of .outer logic
            const part_is_lead = (part_side == defender_dominant);
            break :blk switch (attack_angle) {
                .inside => if (!part_is_lead) .partial else .grazing,
                .outside => if (part_is_lead) .partial else .grazing,
                .flank => .grazing,
                .frontal, .rear => .none,
            };
        },
        .top => switch (attack_arc) {
            .overhead => .full,
            .level => .grazing,
            .rising => .none,
        },
        .bottom => switch (attack_arc) {
            .rising => .partial,  // rare but possible (uppercut)
            .level, .overhead => .none,
        },
    };
}
```

`AttackArc` is defined on `ArmContribution` (see Technique Contributions). Most attacks default to `.level`.

### Armor Integration

Totality determines if armor covers this angle on this part:

```zig
// Armor layer specifies which facings it covers:
pub const ArmorCoverage = packed struct {
    front: bool = true,
    back: bool = false,
    sides: bool = false,
};

// On armor piece:
coverage: ArmorCoverage,
```

Resolution:
1. Attack angle + part facing → which "side" of the part is hit
2. Check if armor's coverage includes that side
3. If not covered → armor bypassed (gap hit, or just skin/padding)

**Examples:**
- Breastplate: `{ .front = true }` - protects front-facing parts from frontal attacks
- Full cuirass: `{ .front = true, .back = true }` - protects front and back
- Mail hauberk: `{ .front = true, .back = true, .sides = true }` - full Totality

### Hooked Weapons

Weapons already have `Features.hooked: bool`. When combined with appropriate technique, grants a chance to hit from a non-facing angle. Hook success is tied to **control advantage** — you can only hook effectively when you've established blade control.

```zig
// Resolution: if hooked weapon + hooking technique, check control for angle bypass
fn resolveHitAngle(
    engagement: *const Engagement,
    weapon: *const Weapon,
    technique: *const Technique,
    rng: *Random,
) RelativeAngle {
    if (weapon.features.hooked and technique.can_hook) {
        // Hook chance scales with control advantage
        // control 0.5 = neutral = 0% chance
        // control 0.8 = dominant = 60% chance
        // control 1.0 = full control = 100% chance
        const control_bonus = @max(0, engagement.control - 0.5) * 2.0;
        if (rng.float() < control_bonus) {
            return .rear;  // hits back-facing surface
        }
    }
    return engagement.angle;
}
```

**Examples:**
- Axe beard hooks behind knee → greaves only cover front, back of knee exposed
- Billhook pulls rider → bypasses frontal armor
- Bec de corbin spike reaches around shield

**On Technique:**
```zig
can_hook: bool = false,  // enables hook resolution when weapon.features.hooked
```

Simple boolean combo, no need to specify which angle — hooking hits the "back" of whatever part is selected. The control requirement means you can't just fish for hooks; you have to earn the position first.

### Techniques That Create Angle

Footwork/maneuver cards can shift the engagement angle:

```zig
// On maneuver technique:
angle_change: ?struct {
    direction: enum { inside, outside, either },
    magnitude: enum { step, full },  // step = one level, full = to flank
} = null,
```

**Examples:**
- Sidestep inside: `{ .direction = .inside, .magnitude = .step }`
- Circle to flank: `{ .direction = .either, .magnitude = .full }`

Gaining angle becomes a tactical objective alongside pressure/control. Angle converts advantage into exposed targets and armor gaps.

### Inside vs Outside Trade-offs

| Angle | Risk | Reward |
|-------|------|--------|
| Inside (weapon side) | Closer to defender's weapon, easier to counter | Shorter path to vitals, better control |
| Outside (off-hand side) | Off-hand may have shield/dagger | Safer from main weapon, back access easier |

This interacts with `main_and_off` grip - sword+buckler defender is harder to outside-angle than sword-alone.

## Comptime Stance Expansion

Stance definitions should stay compact - no need to author entries for every finger and toe. Child parts are expanded at comptime.

### Authored Format (Compact)

```zig
const standing_frontwise_src = [_]ExposureEntry{
    // Major parts only - children auto-expand
    .{ .tag = .head,  .side = .center, .hit_chance = 0.10, .height = .high },
    .{ .tag = .hand,  .side = .left,   .hit_chance = 0.015, .height = .mid },
    .{ .tag = .hand,  .side = .right,  .hit_chance = 0.015, .height = .mid },
    .{ .tag = .foot,  .side = .left,   .hit_chance = 0.015, .height = .low },
    .{ .tag = .foot,  .side = .right,  .hit_chance = 0.015, .height = .low },
    // ... other major parts
    // No finger, thumb, toe entries - expanded from parent
};
```

### Child Weight Tables (Per Species)

```zig
const HumanoidChildWeights = struct {
    pub fn hand() []const ChildWeight {
        return &.{
            .{ .tag = .hand,   .weight = 0.80 },  // hand proper
            .{ .tag = .finger, .weight = 0.15 },  // fingers (pooled or per-finger)
            .{ .tag = .thumb,  .weight = 0.05 },
        };
    }

    pub fn foot() []const ChildWeight {
        return &.{
            .{ .tag = .foot, .weight = 0.85 },
            .{ .tag = .toe,  .weight = 0.15 },
        };
    }

    pub fn head() []const ChildWeight {
        return &.{
            .{ .tag = .head, .weight = 0.70 },
            .{ .tag = .eye,  .weight = 0.10 },
            .{ .tag = .ear,  .weight = 0.08 },
            .{ .tag = .nose, .weight = 0.07 },
            .{ .tag = .neck, .weight = 0.05 },  // if neck is child of head
        };
    }
};
```

### Expansion Logic

```zig
fn expandStance(
    comptime src: []const ExposureEntry,
    comptime body_plan: []const PartDef,
    comptime child_weights: type,
) []const ExposureEntry {
    comptime {
        var result: []const ExposureEntry = &.{};

        for (src) |entry| {
            // Check if this part has children NOT in src
            const children_in_src = hasChildrenInList(entry.tag, src, body_plan);

            if (!children_in_src) {
                // Look up child weights for this part type
                if (getChildWeights(child_weights, entry.tag)) |weights| {
                    // Expand: split hit_chance among parent and children
                    for (weights) |cw| {
                        result = result ++ .{ExposureEntry{
                            .tag = cw.tag,
                            .side = entry.side,
                            .hit_chance = entry.hit_chance * cw.weight,
                            .height = entry.height,
                            .facing = entry.facing,
                        }};
                    }
                } else {
                    // No expansion defined - keep as-is
                    result = result ++ .{entry};
                }
            } else {
                // Children explicitly listed - no expansion
                result = result ++ .{entry};
            }
        }

        return result;
    }
}
```

### Detection Rule

A part expands to children when:
1. The part has children in the body plan
2. Those children are *not* explicitly listed in the stance source

**Example - torso doesn't expand:**
```zig
// If stance includes:
.{ .tag = .torso, ... },
.{ .tag = .abdomen, ... },  // child of torso, explicitly listed
// Then torso does NOT expand - children are authored
```

**Example - hand expands:**
```zig
// If stance includes:
.{ .tag = .hand, ... },
// And no .finger or .thumb entries
// Then hand DOES expand using HumanoidChildWeights.hand()
```

### Expanded Result (Static)

```zig
// standing_frontwise after comptime expansion:
const standing_frontwise = [_]ExposureEntry{
    // Head expanded:
    .{ .tag = .head, .side = .center, .hit_chance = 0.070, .height = .high },
    .{ .tag = .eye,  .side = .left,   .hit_chance = 0.005, .height = .high },
    .{ .tag = .eye,  .side = .right,  .hit_chance = 0.005, .height = .high },
    .{ .tag = .ear,  .side = .left,   .hit_chance = 0.004, .height = .high },
    .{ .tag = .ear,  .side = .right,  .hit_chance = 0.004, .height = .high },
    .{ .tag = .nose, .side = .center, .hit_chance = 0.007, .height = .high },
    .{ .tag = .neck, .side = .center, .hit_chance = 0.005, .height = .high },

    // Hand expanded:
    .{ .tag = .hand,   .side = .left, .hit_chance = 0.0120, .height = .mid },
    .{ .tag = .finger, .side = .left, .hit_chance = 0.0023, .height = .mid },
    .{ .tag = .thumb,  .side = .left, .hit_chance = 0.0008, .height = .mid },
    // ... right hand same pattern

    // Torso not expanded (abdomen listed separately):
    .{ .tag = .torso,   .side = .center, .hit_chance = 0.30, .height = .mid },
    .{ .tag = .abdomen, .side = .center, .hit_chance = 0.15, .height = .mid },

    // ...
};
```

### Benefits

- **Compact authoring**: Only specify major parts per stance
- **No runtime branching**: Full resolution at comptime
- **Species-specific**: Each blueprint has its own child weight tables
- **Explicit control**: Override by listing children in stance source

## Open Questions

### Resolved

1. ~~**Enum vs f32 for height**~~: **Enum.** Gradient attacks use `secondary_height`.

2. ~~**Flexible parts**~~: **Handled by arm_contribution.** Technique modifies arm height/extension.

3. ~~**Mirror implementation**~~: **`dominant_side` + `Facing.leadSide()` at synthesis time.**

4. ~~**Defense coverage**~~: **Affects both hit chance and location.** See Resolution Algorithm.

5. ~~**"any" facing**~~: **Replaced with `top`/`bottom`.** Height + facing + arc provides discrimination.

6. ~~**Attack arc integration**~~: **Field on `ArmContribution`.** Defaults to `.level`; techniques specify `.overhead` or `.rising` as needed.

### Open

7. **Stamina cost for defense adjustment**: Derive from delta between current and target contributions? Or flat per-step cost?

8. **Stance terminology**: Research HEMA/fechtbuch terms for flavor (separate task).

9. **Conflict detection UX**: How to communicate invalid pairings to player? Gray out cards? Error message on play?

10. **Synergy bonuses**: Worth tracking explicitly, or let the exposure math handle it implicitly?

11. **Angle momentum** (deferred): Should repeated same-direction movement grant easier angle gain?

## Non-Humanoid Examples

Non-humanoids demonstrate the model's flexibility. They use **base exposure patterns** (analogous to grip base patterns for humanoids) rather than compositional synthesis.

**Ooze:**
```zig
// Simple creatures use static exposure patterns — no stance changes
const ooze_base_exposures = [_]PartExposure{
    .{ .tag = .core,    .side = .center, .hit_chance = 0.80, .height = .low },
    .{ .tag = .nucleus, .side = .center, .hit_chance = 0.20, .height = .low },
};
// All low, amorphous — no grip, no facing, no composition needed
```

**Centaur (front-facing):**
```zig
// Centaurs have unique grip categories (lance from horseback, etc.)
// but can use similar composition for upper body
const centaur_base_exposures = [_]PartExposure{
    // Human upper body - high/mid (can use humanoid arm contributions)
    .{ .tag = .head,       .side = .center, .hit_chance = 0.08, .height = .high },
    .{ .tag = .torso,      .side = .center, .hit_chance = 0.20, .height = .mid },
    // ...arms at mid, modified by grip/technique...

    // Horse body - low/mid (static, no arm contribution applies)
    .{ .tag = .horse_body, .side = .center, .hit_chance = 0.35, .height = .low },
    .{ .tag = .foreleg,    .side = .left,   .hit_chance = 0.05, .height = .low },
    .{ .tag = .foreleg,    .side = .right,  .hit_chance = 0.05, .height = .low },
    // ...etc
};
// Body contributions apply to horse body (facing, weight)
// Arm contributions apply to humanoid upper body
```

The compositional model gracefully degrades: simple creatures use static patterns, complex creatures use full composition.
