# CUE-to-Zig Generator Gotchas

## Generator Location
`scripts/cue_to_zig.py` - converts CUE JSON export to Zig static data

## Critical: Topological Ordering for Body Parts
Body parts MUST be output in parent-before-child order because runtime code
like `computeEffectiveIntegrities()` processes parts sequentially and assumes
parent indices are already computed.

The generator uses `topological_sort_parts()` to ensure correct ordering.
Without this, tests like "effective integrity propagates through chain" fail
because parent lookups return uninitialized values.

## Visibility: All Referenced Types Must Be `pub`
If a type is used by other modules (like body_list.zig importing from
generated_data.zig), it must be `pub const`, not just `const`.

Example fix: `TissueLayerDefinition` needed to be public.

## Flag Name Mapping
CUE flag names don't always match Zig field names:
```python
("vital", "is_vital"),
("internal", "is_internal"),
("grasp", "can_grasp"),
("stand", "can_stand"),
("see", "can_see"),
("hear", "can_hear"),
```

## Comptime Branch Limits
With 67+ body parts, comptime operations easily exceed Zig's default limits.
Add `@setEvalBranchQuota()` liberally in functions that iterate over parts
or do string comparisons:
- 10000 for simple lookups
- 100000 for nested loops
- 1000000 for full plan builds

## Regenerating
```bash
just generate  # or just check (which regenerates first)
```

The generator reads CUE via: `cue export data/*.cue --out json | ./scripts/cue_to_zig.py`

## Testing Generator Changes
After modifying the generator:
1. `just generate` - regenerate Zig code
2. `zig build` - check compilation
3. `just check` - run full test suite

Lazy compilation can hide errors in unreferenced code - run tests to surface them.
