# Target Validation Architecture

## Core Principle: Single Path

All "does this card have valid targets?" checks flow through ONE function:

```
targeting.hasAnyValidTarget(card, actor, world) -> bool
```

This function checks ALL expressions in a card's rules, not just technique
expressions. This is intentional - the general case is more flexible and
universally useful.

## Why Single Path Matters

1. **Consistency**: Incapacitation, range, and filters are checked uniformly
2. **Maintainability**: Bug fixes and new checks apply everywhere automatically
3. **Predictability**: Cards behave the same way regardless of context

## What Gets Checked

For each expression in a card, for each potential target:

1. **Incapacitation** (universal) - dead/unconscious targets are skipped
2. **Weapon reach** (technique effects only) - attack_mode determines reach
3. **Expression filters** - advantage thresholds, predicates, etc.

These checks live in `isValidTargetForExpression()` - the SINGLE LOCATION
for target validity logic.

## Key Files

- `src/domain/apply/targeting.zig` - `hasAnyValidTarget()`, `isValidTargetForExpression()`
- `src/domain/query/combat_snapshot.zig` - calls `hasAnyValidTarget()` for UI warnings

## Design Decisions

### General Case by Default

The function checks ALL expressions, not just techniques. If you need narrower
behavior (e.g., "only check technique expressions"), add a filter parameter to
the existing function rather than creating a parallel one.

### Self-Targeting Short-Circuit

`.self` targets return `true` immediately without calling `getTargetsForQuery()`.
This is both semantically correct (you can always target yourself) and avoids
a known stack pointer bug in `getTargetsForQuery(.self, ...)`.

### Technique-Specific Branches Are OK

Weapon reach only applies to combat techniques - this is a justified branch,
not a violation of the single-path principle. The check is still in one place.

## Anti-Patterns to Avoid

- **DON'T** create `hasAnyTargetInRangeForTechniques()` or similar parallel functions
- **DON'T** duplicate incapacitation checks elsewhere
- **DON'T** add target validity logic outside `isValidTargetForExpression()`
- **DON'T** bypass this system for "special" card types

## Extending the System

To add a new validity check (e.g., "target must have condition X"):

1. Add the check to `isValidTargetForExpression()`
2. All cards automatically get the new behavior
3. If it should be optional, use an expression filter predicate instead

## Related

- T009: Original range validation system
- T025: Extended to expression filters (advantage thresholds)
- `expressionAppliesToTarget()`: Evaluates expression filters via predicates
