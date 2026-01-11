# Cards/Actions Split Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Separate shared card infrastructure (`cards.zig`) from action-specific types (`actions.zig`), deleting `Kind` enum and folding modifier into `TagSet`.

**Architecture:** Extract action-verb types (TagSet, Trigger, Predicate, Effect, Rule, Template, etc.) to new `actions.zig`. Keep shared types (Rarity, Zone) in `cards.zig`. Delete `Kind` enum entirely, use `tags.modifier` instead.

**Tech Stack:** Zig 0.15.2, sed for bulk changes, `just check` for verification.

**Design doc:** `doc/plans/2026-01-11-cards-actions-split.md`

---

## Phase 1: Add modifier tag and migrate checks

### Task 1.1: Add modifier field to TagSet

**Files:**
- Modify: `src/domain/cards.zig` (TagSet struct, around line 82-125)

**Step 1: Add the modifier field**

In `src/domain/cards.zig`, find the `TagSet` packed struct and add `modifier: bool = false` after `involuntary`:

```zig
    involuntary: bool = false, // status/dud cards (cannot be voluntarily discarded)

    // Card subtypes (replaces Kind enum for modifier detection)
    modifier: bool = false, // modifies another action during commit phase
```

**Step 2: Update the bitcast size**

The TagSet uses `@bitCast` with `u18`. Adding one more bool makes it 19 bits. Update to `u19` or `u32` for alignment:

Find all `u18` in TagSet methods and change to `u32`:
```zig
    pub fn hasTag(self: *const TagSet, required: TagSet) bool {
        const me: u32 = @bitCast(self.*);
        const req: u32 = @bitCast(required);
        return (me & req) == req;
    }

    pub fn hasAnyTag(self: *const TagSet, mask: TagSet) bool {
        const me: u32 = @bitCast(self.*);
        const bm: u32 = @bitCast(mask);
        return (me & bm) != 0;
    }
```

**Step 3: Verify compilation**

Run: `just check`
Expected: All tests pass (no behavioral change yet)

**Step 4: Commit**

```bash
git add src/domain/cards.zig
git commit -m "feat(cards): add modifier field to TagSet

Preparation for Kind enum removal. TagSet bitcast updated to u32."
```

---

### Task 1.2: Add modifier tag to modifier templates

**Files:**
- Modify: `src/domain/card_list.zig` (m_high, m_low, m_feint templates)

**Step 1: Update m_high template**

Find `m_high` (around line 519-540) and add `.modifier = true` to its tags:

```zig
const m_high = Template{
    .id = hashName("high"),
    .kind = .modifier,  // will remove later
    .name = "high",
    // ... other fields ...
    .tags = .{ .phase_commit = true, .modifier = true },
    // ...
};
```

**Step 2: Update m_low template**

Find `m_low` (around line 542-565) and add `.modifier = true`:

```zig
    .tags = .{ .phase_commit = true, .modifier = true },
```

**Step 3: Update m_feint template**

Find `m_feint` (around line 566-600) and add `.modifier = true`:

```zig
    .tags = .{ .phase_commit = true, .modifier = true },
```

**Step 4: Verify compilation**

Run: `just check`
Expected: All tests pass

**Step 5: Commit**

```bash
git add src/domain/card_list.zig
git commit -m "feat(cards): add modifier tag to modifier templates

m_high, m_low, m_feint now have .tags.modifier = true alongside .kind = .modifier"
```

---

### Task 1.3: Migrate .kind == .modifier checks to .tags.modifier

**Files:**
- Modify: `src/domain/query/combat_snapshot.zig` (line ~270)
- Modify: `src/domain/apply/targeting.zig` (line ~342)
- Modify: `src/domain/apply/command_handler.zig` (line ~450)
- Modify: `src/presentation/views/combat/view.zig` (lines ~505, 568, 581)

**Step 1: Use sed to replace equality checks**

```bash
sed -i 's/\.kind == \.modifier/.tags.modifier/g' src/domain/query/combat_snapshot.zig
sed -i 's/\.kind != \.modifier/!.tags.modifier/g' src/domain/query/combat_snapshot.zig
```

**Step 2: Apply to remaining domain files**

```bash
sed -i 's/\.kind == \.modifier/.tags.modifier/g' src/domain/apply/targeting.zig
sed -i 's/\.kind != \.modifier/!.tags.modifier/g' src/domain/apply/targeting.zig

sed -i 's/\.kind == \.modifier/.tags.modifier/g' src/domain/apply/command_handler.zig
sed -i 's/\.kind != \.modifier/!.tags.modifier/g' src/domain/apply/command_handler.zig
```

**Step 3: Apply to presentation files**

```bash
sed -i 's/\.kind == \.modifier/.tags.modifier/g' src/presentation/views/combat/view.zig
sed -i 's/\.kind != \.modifier/!.tags.modifier/g' src/presentation/views/combat/view.zig
```

**Step 4: Verify no remaining .kind modifier checks**

```bash
grep -r "\.kind.*\.modifier" src/
```
Expected: No matches (only template definitions which still have `.kind = .modifier`)

**Step 5: Verify compilation and tests**

Run: `just check`
Expected: All tests pass

**Step 6: Commit**

```bash
git add -A
git commit -m "refactor: migrate .kind == .modifier checks to .tags.modifier

All runtime modifier checks now use TagSet. Kind field still present but unused for modifier detection."
```

---

## Phase 2: Remove Kind enum

### Task 2.1: Remove kind field from Template struct

**Files:**
- Modify: `src/domain/cards.zig` (Template struct, around line 394-450)

**Step 1: Remove kind field from Template**

Find the Template struct and remove the `kind: Kind,` field:

```zig
pub const Template = struct {
    id: ID,
    // kind: Kind,  <- DELETE THIS LINE
    name: []const u8,
    // ... rest unchanged
};
```

**Step 2: Attempt compilation to find all breakages**

Run: `zig build`
Expected: Compilation errors listing all places that set `.kind = ...`

**Step 3: Document the error locations**

Note all files that need `.kind = ...` removed from template literals.

---

### Task 2.2: Remove .kind from card_list.zig templates

**Files:**
- Modify: `src/domain/card_list.zig` (~27 template definitions)

**Step 1: Use sed to remove .kind lines**

```bash
sed -i '/\.kind = \.action,/d' src/domain/card_list.zig
sed -i '/\.kind = \.modifier,/d' src/domain/card_list.zig
```

**Step 2: Verify removal**

```bash
grep "\.kind = \." src/domain/card_list.zig
```
Expected: No matches

**Step 3: Attempt compilation**

Run: `zig build`
Expected: Still errors from other files (cards.zig tests, validation.zig tests)

---

### Task 2.3: Remove .kind from cards.zig test fixtures

**Files:**
- Modify: `src/domain/cards.zig` (test templates around lines 564-610)

**Step 1: Remove .kind from test templates**

Find the test templates (single_target_template, all_enemies_template, empty_template) and remove `.kind = .action,` lines.

**Step 2: Verify with sed**

```bash
sed -i '/\.kind = \.action,/d' src/domain/cards.zig
```

---

### Task 2.4: Remove .kind from validation.zig test fixtures

**Files:**
- Modify: `src/domain/apply/validation.zig` (~9 test templates)

**Step 1: Remove .kind from test fixtures**

```bash
sed -i '/\.kind = \.action,/d' src/domain/apply/validation.zig
```

**Step 2: Verify compilation**

Run: `zig build`
Expected: Should compile now (or reveal remaining issues)

---

### Task 2.5: Delete Kind enum

**Files:**
- Modify: `src/domain/cards.zig` (Kind enum, lines 20-31)

**Step 1: Delete the Kind enum**

Remove the entire Kind enum definition:

```zig
// DELETE THIS ENTIRE BLOCK:
pub const Kind = enum {
    action,
    passive,
    reaction,
    encounter,
    mob,
    // Ally,
    environment,
    resource,
    meta_progression,
    modifier, // enhances another card's action
};
```

**Step 2: Verify compilation and tests**

Run: `just check`
Expected: All tests pass

**Step 3: Commit Phase 2**

```bash
git add -A
git commit -m "refactor: remove Kind enum from cards

Kind enum deleted. Modifier detection uses .tags.modifier.
Other Kind values (passive, reaction, mob, etc.) were unused."
```

---

## Phase 3: Update presentation layer

### Task 3.1: Remove mapKind from card model

**Files:**
- Modify: `src/presentation/views/card/model.zig` (mapKind function around line 85)

**Step 1: Read the file to understand mapKind usage**

Check how mapKind is called and what the presentation Kind enum looks like.

**Step 2: Remove or adapt mapKind**

If presentation needs card type info, derive from tags. Otherwise delete mapKind and any presentation Kind enum that mirrors cards.Kind.

**Step 3: Verify compilation**

Run: `just check`
Expected: All tests pass

**Step 4: Commit**

```bash
git add -A
git commit -m "refactor(presentation): remove mapKind, derive card type from tags"
```

---

## Phase 4: Create actions.zig and split files

### Task 4.1: Create actions.zig with moved types

**Files:**
- Create: `src/domain/actions.zig`
- Modify: `src/domain/cards.zig` (remove moved types)
- Modify: `src/domain/mod.zig` (add actions export)

**Step 1: Create actions.zig**

Create new file with all action-specific types moved from cards.zig:

```zig
//! Action card types - the "verb" grammar for playable actions.
//!
//! Actions are cards that can be played to produce effects. They have:
//! - Triggers: when rules fire
//! - Predicates: conditions for rules
//! - Effects: what rules do
//! - Templates: static definitions
//! - Instances: runtime state

const std = @import("std");
pub const cards = @import("cards.zig");
pub const entity = @import("../entity.zig");
// ... other imports from cards.zig

// Move these types from cards.zig:
// - TagSet (with modifier field)
// - Trigger
// - Predicate
// - Effect
// - Rule
// - Expression
// - Cost
// - PlayableFrom
// - ChannelSet
// - Exclusivity
// - TechniqueID
// - AttackMode
// - Technique
// - OverlayBonus
// - ModifyPlay
// - Stakes
// - Value
// - Comparator
// - TargetQuery
// - Template
// - Instance
// - ID (action template ID)
// - RuneIcon

// Re-export shared types for convenience
pub const Rarity = cards.Rarity;
pub const Zone = cards.Zone;
```

**Step 2: Update cards.zig to only contain shared types**

```zig
//! Shared card infrastructure - types common to all card kinds.
//!
//! Actions, items, agents are all "cards" in this card game.
//! This module contains types shared across all card kinds.

pub const Rarity = enum {
    common,
    uncommon,
    rare,
    epic,
    legendary,
};

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

**Step 3: Update mod.zig**

Add actions export:

```zig
pub const actions = @import("actions.zig");
pub const cards = @import("cards.zig");
```

**Step 4: Verify compilation fails (expected - imports not updated)**

Run: `zig build`
Expected: Many import errors

---

### Task 4.2: Update imports across codebase

**Files:** ~30 files (see design doc for full list)

**Step 1: Files that only use action types**

Change `const cards = @import(...)` to `const actions = @import(...)`:

Domain files:
- `src/domain/events.zig`
- `src/domain/condition.zig`
- `src/domain/ai.zig`
- `src/domain/world.zig`
- `src/domain/tick/committed_action.zig`
- `src/domain/tick/resolver.zig`
- `src/domain/query/combat_snapshot.zig`
- `src/domain/resolution/*.zig`
- `src/domain/combat/*.zig`
- `src/domain/apply/*.zig`

**Step 2: Files that need both**

Add actions import alongside cards:
```zig
const actions = @import("actions.zig");
const cards = @import("cards.zig");
```

**Step 3: Update type references**

`cards.Template` → `actions.Template`
`cards.Instance` → `actions.Instance`
`cards.TagSet` → `actions.TagSet`
etc.

**Step 4: Iterative compilation**

Run `zig build` repeatedly, fixing errors file by file.

**Step 5: Verify all tests pass**

Run: `just check`
Expected: All tests pass

**Step 6: Commit**

```bash
git add -A
git commit -m "refactor: split cards.zig into cards.zig + actions.zig

cards.zig: shared infrastructure (Rarity, Zone)
actions.zig: action-specific types (TagSet, Template, Instance, rules, etc.)"
```

---

### Task 4.3: Rename card_list.zig to action_list.zig

**Files:**
- Rename: `src/domain/card_list.zig` → `src/domain/action_list.zig`
- Modify: `src/domain/mod.zig`
- Modify: All files importing card_list

**Step 1: Rename file**

```bash
git mv src/domain/card_list.zig src/domain/action_list.zig
```

**Step 2: Update mod.zig**

```zig
pub const action_list = @import("action_list.zig");
```

**Step 3: Update imports**

```bash
sed -i 's/card_list/action_list/g' src/domain/mod.zig
sed -i 's/card_list/action_list/g' src/domain/apply/validation.zig
# ... any other files importing card_list
```

**Step 4: Verify compilation and tests**

Run: `just check`
Expected: All tests pass

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename card_list.zig to action_list.zig"
```

---

## Phase 5: Final verification and cleanup

### Task 5.1: Full test suite verification

**Step 1: Run complete check**

Run: `just check`
Expected: All tests pass

**Step 2: Verify no cards.Kind references remain**

```bash
grep -r "cards\.Kind" src/
grep -r "\.kind = \." src/domain/  # should only find entity.ID and damage.Packet
```

**Step 3: Verify import consistency**

```bash
grep -r "const cards = " src/ | head -20
grep -r "const actions = " src/ | head -20
```

---

### Task 5.2: Update Serena memory if exists

**Files:**
- Check: `.serena/memories/cards_data_model_overview.md` (if exists)

**Step 1: Check for relevant memory**

If a cards-related memory exists, update it to reflect the new structure.

---

### Task 5.3: Final commit and PR preparation

**Step 1: Verify clean git status**

```bash
git status
git log --oneline -10
```

**Step 2: Squash or keep commits as-is based on preference**

The incremental commits document the migration path. May squash for cleaner history.

---

## Checkpoint Summary

| Phase | Tasks | Key Verification |
|-------|-------|------------------|
| 1 | 1.1-1.3 | `just check` passes, no `.kind == .modifier` checks |
| 2 | 2.1-2.5 | `just check` passes, Kind enum deleted |
| 3 | 3.1 | `just check` passes, mapKind removed |
| 4 | 4.1-4.3 | `just check` passes, files split and renamed |
| 5 | 5.1-5.3 | Clean verification, ready for merge |

Run `just check` after each task. If tests fail, fix before proceeding.
