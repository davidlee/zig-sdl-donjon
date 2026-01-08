# Zig Style Conventions for deck_of_dwarf

## Architecture
- Domain modules expose public APIs via `mod.zig` re-exports; SDL imports stay confined to `src/presentation`
- Define explicit error sets (e.g., `ValidationError`) near their modules and propagate them through public functions; keep validation logic pure when possible
- Structs that own memory implement `init`/`deinit` taking an allocator; use `defer`/`errdefer` for cleanup and rollback
- Domain code emits semantic events via `world.events.push` instead of printing; presentation layers consume events for visuals/logs
- Presentation avoids importing domain internals directly; go through the application/query layers (Command service, combat snapshots) rather than calling `apply.*` helpers

## File Documentation
- `///` at top of each file describing scope of responsibilities (and optionally, non-responsibilities)

## Pointers & Mutation
- `*const T` by default; `*T` only when mutation is required
- For accessor pairs: `thing()` returns const view, `thingMut()` for mutable

## Imports
- Block-level `const foo = @import(...)` at file top, grouped: std, then project, then relative
- Test-only imports at top of `test` block, not inline
- Never `@import("foo").bar.baz` inline in expressions

## Error Handling
- `!T` for recoverable failures (IO, validation, external input)
- `?T` for "not found" / legitimate absence
- `assert` / `unreachable` for invariants (programmer error if violated)
- Prefer returning errors over panicking in domain code

## Optionals
- `orelse` for defaults or early return
- `if (x) |val|` when branching on presence
- `.?` only immediately after a check or when it's a true invariant

## Self & Methods
- Always `self`, never `this` or type name
- `*const Self` default, `*Self` when mutating

## Slices & Pointers
- `[]T` is the default for sequences
- `*T` for single items
- `[*]T` only for C interop
- `*[N]T` when compile-time length matters

## Initialization
- Explicit field values; don't rely on defaults silently
- `= undefined` only with immediate initialization and a comment if non-obvious

## Unused Values
- `_` for intentionally discarded captures/returns
- `_`-prefixed params for "unused now but part of interface"

## Comptime
- Use for type-level construction and compile-time config
- Prefer runtime when it works - compile times matter

## Doc Comments
- `///` for public API with non-obvious semantics
- Skip for `init`/`deinit` unless unusual
- Focus on "why" and edge cases, not restating the signature

## Tests
- Inline `test` blocks for unit tests
- Separate files for integration/behavioral tests
- Names describe behavior: `test "damage reduces health to minimum of zero"`
- Test the public interface, not internal state
- Test behaviour, not implementation