# Design: Split cards.zig into cards.zig + actions.zig

## Context

The unified entity wrapper (`doc/issues/unified_entity_wrapper.md`) establishes that
Actions, Items, Agents, etc. are all "cards" in this card game. The entity system
already uses `EntityKind.action` to refer to what lives in `cards.zig`.

However, `cards.zig` currently conflates two concerns:
1. **Shared card infrastructure** - concepts that apply to all card types
2. **Action-specific grammar** - triggers, predicates, effects, rules

This conflation will become problematic as we build out instanced items, equipment,
and inventory. The nomenclature should reinforce the conceptual model: everything
is a card, actions are one kind of card.

## Decision

Split `cards.zig`:
- **`cards.zig`** retains shared card infrastructure
- **`actions.zig`** (new) receives action-specific types

Delete `Kind` enum entirely; fold the `modifier` distinction into `TagSet`.

## What Stays in cards.zig

### Rarity
```zig
pub const Rarity = enum {
    common,
    uncommon,
    rare,
    epic,
    legendary,
};
```
Generic across all card types. Items, agents, encounters can all have rarity.

### Zone
```zig
pub const Zone = enum {
    draw,
    hand,
    discard,
    in_play,
    equipped,
    inventory,
    exhaust,
    limbo,
};
```
"Where is this card?" applies to all card types:
- Actions cycle: draw → hand → in_play → discard/exhaust
- Items: inventory → equipped → inventory
- Agents: encounter deck → in_play → defeated

**Note:** Zone is a bet that the unification holds across card types. If item cards
fight with action card ergonomics, we'll revisit. Currently working OK.

## What Moves to actions.zig

### TagSet (with modifier added)
```zig
pub const TagSet = packed struct {
    // Existing tags
    melee: bool = false,
    ranged: bool = false,
    offensive: bool = false,
    defensive: bool = false,
    spell: bool = false,
    item: bool = false,
    buff: bool = false,
    debuff: bool = false,
    reaction: bool = false,
    power: bool = false,
    skill: bool = false,
    meta: bool = false,
    manoeuvre: bool = false,
    phase_selection: bool = false,
    phase_commit: bool = false,
    precision: bool = false,
    finesse: bool = false,
    involuntary: bool = false,

    // NEW: replaces Kind.modifier
    modifier: bool = false,

    // ... methods unchanged
};
```

### Kind (DELETED)

The `Kind` enum is removed entirely:
```zig
// DELETED - was:
// pub const Kind = enum {
//     action, passive, reaction, encounter, mob,
//     environment, resource, meta_progression, modifier,
// };
```

**Rationale:** Kind conflated entity-types (mob, encounter) with action-subtypes
(modifier, passive). Entity-types belong in `entity.EntityKind`. The only runtime
usage was checking `.modifier`, which is a capability/behavior (can attach to
another play during commit) not an exclusive identity. A card could plausibly be
both an action AND a modifier. TagSet's "any number" semantics fits better than
Kind's "exactly one" semantics.

### Everything Else

All action-specific types move to `actions.zig`:

| Type | Purpose |
|------|---------|
| `Trigger` | When rules fire |
| `Predicate` | Conditions for rules |
| `Effect` | What rules do |
| `Rule` | Trigger + predicate + effects |
| `Expression` | Effect + filter + target |
| `Cost` | Stamina, time, focus, exhausts |
| `PlayableFrom` | Where card can be played from |
| `ChannelSet` | Execution channels (weapon, footwork, etc.) |
| `Exclusivity` | Mutual exclusion rules |
| `TechniqueID` | Combat technique identifier |
| `AttackMode` | How technique attacks |
| `Technique` | Combat technique definition |
| `OverlayBonus` | Technique bonuses |
| `ModifyPlay` | Play modification effects |
| `Stakes` | Risk/reward modifiers |
| `Value` | Constant or stat-derived values |
| `Comparator` | Value comparison |
| `TargetQuery` | Target selection |
| `Template` | Action template definition |
| `Instance` | Action instance (runtime) |
| `ID` | Action template ID |
| `RuneIcon` | Action presentation |

## Migration

### Code Changes

1. **Modifier checks**: `template.kind == .modifier` → `template.tags.modifier`

2. **Template struct**: Remove `kind` field, templates just use tags
   ```zig
   // Before
   .kind = .modifier,
   .tags = .{ .phase_commit = true },

   // After
   .tags = .{ .modifier = true, .phase_commit = true },
   ```

3. **Imports**: Files using action types change from `cards` to `actions`
   ```zig
   // Before
   const cards = @import("cards.zig");

   // After
   const actions = @import("actions.zig");
   const cards = @import("cards.zig");  // only if using Rarity/Zone
   ```

4. **Type references**: `cards.Template` → `actions.Template`, etc.

### File Renames

| Before | After |
|--------|-------|
| `card_list.zig` | `action_list.zig` |

Note: `CardRegistry` already renamed to `ActionRegistry` in prior work.

### Presentation Layer

`presentation/views/card/model.zig` has a `mapKind()` function that maps
`cards.Kind` to a presentation `Kind`. This needs updating:
- Remove the domain Kind mapping
- Presentation can define its own display categories if needed
- Or derive display category from tags

## Scope

### Files Importing cards.zig (~30 files)

All will need import updates. Most use action-specific types and will import
`actions` instead of or in addition to `cards`.

**Domain:**
- `mod.zig`, `events.zig`, `condition.zig`, `ai.zig`, `world.zig`
- `tick/committed_action.zig`, `tick/resolver.zig`
- `query/combat_snapshot.zig`
- `resolution/advantage.zig`, `context.zig`, `damage.zig`, `height.zig`, `outcome.zig`
- `combat/agent.zig`, `armament.zig`, `plays.zig`
- `apply/targeting.zig`, `command_handler.zig`, `costs.zig`, `event_processor.zig`, `validation.zig`
- `apply/effects/resolve.zig`, `positioning.zig`, `commit.zig`

**Presentation:**
- `view_state.zig`
- `views/card/model.zig`, `data.zig`
- `views/combat/view.zig`

**Other:**
- `main.zig`
- `testing/integration/harness.zig`

### What This Does NOT Touch

- `entity.zig` - EntityKind stays as-is
- `weapon.zig`, `armour.zig` - separate registries, unaffected
- Combat resolution logic - uses actions, just needs import updates
- Event system - references entities, minimal changes

## Risks

1. **Churn**: ~30 files touched. Mitigated by: mechanical refactor, good test coverage.

2. **Zone abstraction leaks**: If item cards need different zone semantics, we'll
   need to revisit. Mitigated by: keeping Zone simple, watching for friction.

3. **TagSet growth**: Adding `modifier` increases packed struct size. Currently
   18 bits → 19 bits, still fits in u32. Monitor if tags proliferate.

4. **Data pipeline coordination**: Card templates flow through a generation pipeline:
   ```
   data/*.cue → scripts/cue_to_zig.py → JSON → src/gen/generated_data.zig
   ```
   Currently `kind` is set in `card_list.zig` (not CUE), so removing it won't
   require CUE schema changes. However:
   - If TagSet structure changes affect generated templates, the Python generator
     needs updating
   - Future work adding tags via CUE will need schema alignment
   - The `techniques.cue` definitions may need `tags` fields added

   Not a blocker for this refactor, but non-trivial if template structure changes
   propagate to the data layer.

## Test Impact

~359 tests in src/. Most impact is mechanical template field changes.

| Category | Count | Change Required |
|----------|-------|-----------------|
| Templates with `.kind = .action` | ~39 | Remove field |
| Templates with `.kind = .modifier` | 3 | Remove field, add `.tags.modifier = true` |
| Presentation `mapKind()` | 1 | Delete function |

**Not affected** (different `.kind` types):
- `entity.ID{ .kind = ... }` - uses `entity.EntityKind`
- `damage.Packet{ .kind = ... }` - uses `damage.Kind`

**By file:**
- `card_list.zig`: ~27 template changes
- `validation.zig`: ~9 test fixture changes
- `cards.zig`: 3 test fixture changes
- `card/model.zig`: delete `mapKind()`

Tests for ChannelSet, TagSet, Template methods stay with `actions.zig`.

## Replacement Strategy

Given the mechanical nature and substantial scope (~30 files, ~40 template changes,
many import updates), consider tooling beyond manual edits:

### sed (recommended for bulk changes)

Safe because easily recoverable via git (won't touch .git/).

```bash
# 1. Remove .kind field from template literals (multiline-aware)
#    Careful: only match cards.Template contexts, not entity.ID or damage.Packet

# 2. Update modifier templates: add .tags.modifier = true
#    Target: m_high, m_low, m_feint in card_list.zig

# 3. Update checks: .kind == .modifier → .tags.modifier
sed -i 's/\.kind == \.modifier/.tags.modifier/g' src/**/*.zig
sed -i 's/\.kind != \.modifier/!.tags.modifier/g' src/**/*.zig

# 4. Update imports: cards → actions (context-dependent, manual review needed)
```

**Caveats:**
- Multiline template literals need care
- Import changes need manual review (some files need both cards + actions)
- Test after each sed pass, commit incrementally

### LSP/Serena symbol operations

ZLS on 0.15.0 vs codebase on 0.15.2 may cause issues. Serena's `rename_symbol`
would be ideal for `cards.Template` → `actions.Template` but may not work
reliably given version mismatch.

Worth trying for:
- Type renames if ZLS cooperates
- Reference finding (even if rename fails, find_referencing_symbols helps)

### Recommended approach

1. **Phase 1 (sed-friendly):** `.kind == .modifier` → `.tags.modifier` checks
2. **Phase 2 (semi-manual):** Template field removal - sed with careful patterns
3. **Phase 3 (manual):** Import updates - need human judgment on cards vs actions
4. **Phase 4 (file ops):** Create actions.zig, move symbols, rename card_list.zig

Commit after each phase. Run `just check` between phases.

## Sequencing

1. Add `modifier: bool` to TagSet
2. Update all templates to use `.tags.modifier = true` instead of `.kind = .modifier`
3. Update all `.kind == .modifier` checks to `.tags.modifier`
4. Remove `kind` field from Template
5. Delete Kind enum
6. Create `actions.zig`, move types
7. Update all imports
8. Rename `card_list.zig` → `action_list.zig`
9. Update presentation layer
10. Run full test suite, fix any breakage

## Future Considerations

When items get their own templates/instances:
- `items.zig` will define `items.Template`, `items.Instance`
- Items may have their own `items.TagSet` (container, consumable, wearable, etc.)
- Zone should work for items without modification (that's the bet)

When agents/mobs become cards:
- Similar pattern: `agents.TagSet`, `agents.Template` if needed
- Or agents remain simpler (no template system, just instances)

## References

- `doc/issues/verbs_vs_nouns.md` - Actions (verbs) vs Items (nouns) distinction
- `doc/issues/unified_entity_wrapper.md` - Entity system design
- `src/entity.zig` - EntityKind enum
