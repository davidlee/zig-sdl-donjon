# Species Design

## Problem

Several concerns currently lack a natural home:

1. **Natural weapons** (fists, claws, bite) - don't belong in Body (anatomical structure) or equipped Armament
2. **Base resources** - blood, stamina, focus maximums are hardcoded in Agent.init()
3. **Creature categorisation** - no way to tag an agent as .animal, .undead, .predator for card/condition targeting
4. **Racial body templates** - HumanoidPlan exists but nothing ties "Dwarf" to it

## Proposal

Introduce `Species` as a comptime struct bundling creature-type data:

```zig
pub const NaturalWeapon = struct {
    template: *const weapon.Template,
    required_part: body.PartTag,
};

pub const Species = struct {
    name: []const u8,
    body_plan: []const body.PartDef,
    natural_weapons: []const NaturalWeapon,
    base_blood: f32,
    base_stamina: f32,
    base_focus: f32,
    tags: TagSet,  // bitset over Tag enum
};

pub const Tag = enum {
    // morphology
    humanoid,
    quadruped,

    // biology
    mammal,
    reptile,
    insectoid,

    // behaviour
    predator,
    pack_hunter,

    // supernatural
    undead,
    construct,
    demon,

    // ...
};
```

## Examples

| Species | Body Plan | Natural Weapons | Tags |
|---------|-----------|-----------------|------|
| Dwarf | HumanoidPlan | fist, headbutt | humanoid, mammal |
| Goblin | HumanoidPlan | fist, bite | humanoid, mammal |
| Wolf | UngulantPlan | bite, claw | quadruped, animal, predator, pack_hunter, mammal |
| Skeleton | HumanoidPlan | fist | humanoid, undead, construct |
| Giant Spider | ArachnidPlan | bite, leg_stab | insectoid, predator |

## Integration with Agent

```zig
pub const Agent = struct {
    // ...
    species: *const Species,
    // ...
};
```

Options for resource initialization:
- **A.** Agent.init() derives base resources from species
- **B.** Agent.init() takes overrides, species provides defaults
- **C.** Stats block includes species reference, computes on access

Option B is probably most flexible - allows individual variation (a particularly tough dwarf).

(See "Future: Stat Generation" for longer-term thinking on this.)

## Integration with Armament

Natural weapons merge into Armament with `.natural` slots, populated from species at agent init. Keeps combat resolution unified - it iterates available weapons regardless of source.

Natural weapons are **gated by body state**: no jaw = no bite, no hand = no punch.

### NaturalWeapon struct

Separate from `weapon.Template` to keep the distinction explicit:

```zig
pub const NaturalWeapon = struct {
    template: *const weapon.Template,
    required_part: body.PartTag,  // .jaw, .hand, .claw, etc.
};
```

Species holds `natural_weapons: []const NaturalWeapon`. Armament checks body part integrity when determining weapon availability.

## Card/Condition Targeting

Species tags enable targeting predicates:

```zig
// Card predicate
.requires_target_tag = .undead,  // "Turn Undead" only affects undead

// Condition immunity
.immune_to = &.{ .bleeding },  // constructs don't bleed
.tag_required = .construct,
```

The existing predicate/effect system should handle this - just needs Tag checks added to EvalContext.

## Open Questions

1. **Tag granularity** - how fine-grained? Is `.carnivore` useful or is `.predator` enough?
2. **Body plan reuse** - multiple species share HumanoidPlan. Is that sufficient or do we need size variants (small_humanoid, large_humanoid)?

## Future: Stat Generation

Fixed base resources (`base_blood: f32`) are a placeholder. Eventually species should point to something like a `StatBlockFactory` (name TBD) that can express:

- Ranges (e.g., blood 4.5-5.5 litres)
- Distributions / random generation
- Racial bonuses/penalties
- Derived stats from other attributes

This enables variation within species ("a particularly tough dwarf") without manual overrides at agent creation. Not implementing now - revisit when stat generation becomes a concrete need.

## Decisions

- **Natural weapon availability**: Gated by body state. No jaw = no bite, no hand = no punch.
- **Armament integration**: Merge into Armament with `.natural` slots.
- **NaturalWeapon type**: Separate struct wrapping `weapon.Template` + `body.PartTag`.
- **File location**: `src/domain/species.zig`, importing body.zig and weapon.zig.

## Non-Goals (for now)

- Hybrid species / mixed heritage
- Species evolution / transformation
- Detailed ecology / behaviour AI

---

## Discussion Log

*Initial discussion: 2026-01-08*

- Natural weapons identified as key driver - they don't fit Body or Armament cleanly
- Comptime struct approach preferred over tagged enum (more data-driven, extensible)
- Tags enable card/condition mechanics ("requires .predator", "affects .undead")
