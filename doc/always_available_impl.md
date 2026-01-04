# Always Available Pool Implementation

## Overview

Implementing Model B from `focus_design.md`: techniques always available from pool, hand contains modifiers.

## Completed

### Phase 0: Infrastructure

**cards.zig:**
- Added `.modifier` to `Kind` enum
- Added `height_override: ?body.Height` to `Effect.modify_play` struct

**Terminology fix:**
- Renamed `techniques_known` → `always_available` throughout codebase
- Renamed `PlayableFrom.techniques_known` → `PlayableFrom.always_available`
- Renamed constant `PlayableFrom.technique` → `PlayableFrom.always_avail`
- Updated `Agent.always_available` container and all references

**card_list.zig - Modifier templates:**

Modifiers use the rules system with `trigger = .on_commit` and `Effect.modify_play`:

```zig
const m_high = Template{
    .kind = .modifier,
    .cost = .{ .stamina = 0, .time = 0 },
    .tags = .{ .offensive = true, .phase_commit = true },
    .rules = &.{.{
        .trigger = .on_commit,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .modify_play = .{
                .damage_mult = 1.2,
                .height_override = .high,
            } },
            .target = .{ .my_play = .{ .has_tag = .{ .offensive = true } } },
            .filter = null,
        }},
    }},
};
```

Three modifiers created:
- `m_high` - height_override = .high, damage_mult = 1.2
- `m_low` - height_override = .low, cost_mult = 0.8, damage_mult = 0.9
- `m_feint` - damage_mult = 0, cost_mult = 0.5, replace_advantage (costs 1 Focus)

`StarterModifiers` array: 3x High, 3x Low, 2x Feint

**card_list.zig - Technique templates:**

Updated existing and added new technique templates with `playable_from = PlayableFrom.always_avail`:

- `t_thrust` - thrust attack
- `t_slash` - swing attack
- `t_deflect` - gentle redirection, cheap (1.5 stamina), covers adjacent
- `t_parry` - beat aside weapon, creates opening (control gain on success)
- `t_shield_block` - requires shield
- `t_riposte` - requires control advantage >= 0.6

`BaseTechniques` array holds all 6 technique template pointers.

**TechniqueEntries updates:**
- Deflect: guard_height = .mid, covers_adjacent = true, difficulty = 0.8
- Parry: guard_height = .mid, covers_adjacent = false, difficulty = 1.2, advantage profile with control gain

### Design Decisions

1. **Feint is a modifier, not a technique** - It's "always available" in the sense of being known, but mechanically it modifies a play rather than being a combat technique with weapon characteristics.

2. **No separate ModifierEffects struct** - Modifiers use existing `Effect.modify_play` via rules system. More composable, uses existing architecture.

3. **Stakes escalation via stacking** - Per `focus_design.md:332-354`, stacking multiple modifiers escalates stakes (2 = committed, 3+ = reckless). No explicit "Committed" modifier needed.

4. **Height modifiers default mid** - Deflect and Parry guard mid height. High/Low modifiers shift targeting.

## Remaining Work

### Phase 1: Play Struct Refactor

**Files:** `combat.zig`, `tick.zig`, `apply.zig`

1. Rename Play fields:
   - `primary` → `action`
   - `reinforcements_buf` → `modifier_stack_buf`
   - `reinforcements_len` → `modifier_stack_len`
   - `reinforcements()` → `modifiers()`
   - `addReinforcement()` → `addModifier()`

2. Add computed methods to Play:
   ```zig
   pub fn effectiveCostMult(self: *const Play, registry: *const CardRegistry) f32
   pub fn effectiveDamageMult(self: *const Play, registry: *const CardRegistry) f32
   pub fn effectiveHeight(self: *const Play, registry: *const CardRegistry, base: body.Height) body.Height
   pub fn effectiveStakes(self: *const Play, registry: *const CardRegistry) Stakes
   ```

   These iterate `modifier_stack`, look up each card's template, extract `modify_play` effect, and accumulate multipliers.

3. Update call sites:
   - `tick.zig:commitPlayerCards()` - use computed methods
   - `apply.zig:commitStack()` - now attaches modifiers, not same-card reinforcement

### Phase 2: Populate always_available

**Files:** `world.zig`

In `World.init()`:
1. Create technique instances from `BaseTechniques` via `card_registry.createFromTemplates()`
2. Populate `player.always_available` with technique IDs
3. Create modifier instances from `StarterModifiers`
4. Populate `player.deck_cards` with modifier IDs (replacing current technique cards)

### Phase 3: Selection Commands (future)

New commands for technique + modifier selection:
```zig
select_action: ID                              // technique from pool or card from hand
attach_modifier: struct { play_index: usize, modifier_id: ID }
```

### Phase 4: Resolution Integration (future)

- `commitPlayerCards()` uses computed modifiers from Play
- `applyCommittedCosts()` handles zone movement (techniques stay in pool, modifiers to discard)

## Key Files

| File | Status | Changes |
|------|--------|---------|
| `cards.zig` | Done | .modifier Kind, height_override in modify_play |
| `card_list.zig` | Done | Modifier templates, technique templates, BaseTechniques, StarterModifiers |
| `combat.zig` | Partial | always_available renamed; Play struct refactor pending |
| `apply.zig` | Partial | always_available renamed; command handlers pending |
| `tick.zig` | Pending | commitPlayerCards needs computed methods |
| `world.zig` | Pending | Populate always_available pool |

## References

- `doc/technique_pool_integration.md` - Full design plan
- `doc/focus_design.md` - Focus system design, Model B specification (especially lines 280-354)
