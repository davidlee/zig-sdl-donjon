## Code 

- we're using zig 0.15.2
- IMPORTANT: code quality is more important than rate of progress. If you detect a code smell, it's worth immediately raising it with the user for discussion.
- concern yourself closely with coupling, cohesion, and intent-revealing naming.
- try to minimise the amount of code you add wherever possible - removing code is ideal
- don't make assumptions; stop and clarify the intended design before implementation.
- tests should focus on behaviour, not implementation

### Magic Numbers & Randomness

- **No magic numbers in logic**: All tunable constants (base chances,
  multipliers, thresholds, variance magnitudes) must be named constants with
  doc comments explaining their effect. Group related constants together.
- No magic strings: when two pieces of code must agree on a non-typesafe 
  identifier, it creates brittleness and risks a runtime panic. 
  Prefer enums or shared constants.
- **All RNG via world.drawRandom()**: Never use `std.Random` or
  `rng.float()` directly. All randomness must go through
  `world.drawRandom(stream_id)` for reproducibility, event tracing, and testability.
- **Document tuning impact**: When adding/changing constants that affect game
  balance, note the expected impact (e.g., "increasing this favours attackers").

## Process

Before any serious undertaking, you will engage in a design conversation with
the user and produce a written markdown design document or plan.

There is a light kanban system in `kanban/`, but sometimes you'll work directly
on design docs / plans in `doc/`, appending progress updates as you go. If
unsure, ask the user.

Use `just new-card "some description"` to create a backlog card from template
with the next ID.

### Maxims 

- DO NOT EVER introduce a new concept which could have been better (more
  flexibly, consistently & extensibly) implemented using existing code or
  concepts. 
- In particular: cards (rules, predicates, effects, triggers, etc), weapons and
  armour, bodies, techniques, conditions, events, etc are modelled very
  flexibly. Understand them before you consider adding bespoke extensions.

## Serena 

List the available Serena memories now. Remember them, consult them later if
you need to understand any of the listed topics.

If at any point you notice one of these memories is incomplete, outdated, or
misleading, you should immediately update and correct or improve it as soon as
you are certain the update is correct.

## toolchain

`just -l` will tell you everything you need.

`just check` will format, test and compile all in one command.