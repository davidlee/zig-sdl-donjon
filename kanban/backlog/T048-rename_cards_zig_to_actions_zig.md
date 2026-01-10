# T048: Rename cards.zig to actions.zig
Created: 2026-01-11

## Problem statement / value driver

With T047's introduction of `entity.EntityKind.action` and the rename of `CardRegistry` → `ActionRegistry`, the term "action" is now the canonical name for what was previously called "cards". The file `cards.zig` and its terminology are now inconsistent with this direction.

### Scope - goals

- Rename `src/domain/cards.zig` to `src/domain/actions.zig`
- Update all imports and references
- Consider renaming types like `cards.Kind`, `cards.Template`, `cards.Instance` to `actions.*`
- Update related documentation/memories

### Scope - non-goals

- Changing game mechanics or card behavior
- Refactoring the action system itself

## Background

### Key files

- `src/domain/cards.zig` - Main file to rename
- `src/domain/card_list.zig` - May need corresponding rename
- All files importing from cards.zig

### Existing systems

T047 established:
- `entity.EntityKind.action` for card/action entity IDs
- `world.ActionRegistry` for action instance storage
- `entity.Entity.action` variant in the union

The codebase currently mixes "card" and "action" terminology.

## Changes Required

### Tasks / Sequence of Work

- [ ] Rename `cards.zig` → `actions.zig`
- [ ] Update all `@import("cards.zig")` to `@import("actions.zig")`
- [ ] Optionally rename `card_list.zig` → `action_list.zig`
- [ ] Consider renaming types (cards.Template → actions.Template, etc.)
- [ ] Review and rationalize `cards.Kind` enum values
- [ ] Update comments/documentation referencing "cards"
- [ ] Update memories

## Test / Verification Strategy

### success criteria / ACs
- All tests pass
- No remaining references to old file names
- Terminology is consistent with T047's direction

## Quality Concerns / Risks

- Large mechanical change with many files touched
- May break external tooling if any expects "cards" terminology
- Consider doing in stages if scope grows

## Progress Log / Notes
