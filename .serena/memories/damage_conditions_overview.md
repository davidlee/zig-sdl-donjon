# Damage & Conditions Overview

## Damage System
- `src/domain/damage.zig` defines the shared damage taxonomy. `Kind`/`Category` enumerate physical/magical/elemental/biological families, while `Instance` and `Packet` describe concrete attacks (amount, type mix, penetration). Scaling metadata and helper functions (`afterLayer`, `penaltiesFor`) keep math reusable.
- Armour/body resistance is encoded via `Resistance`, `Vulnerability`, `Susceptibility`, and `Immunity` structs so mitigation tweaks remain data-driven.

## Condition Framework (T018)
- `src/domain/condition.zig` provides a declarative, data-driven condition framework:
  - `ConditionDefinition` describes each condition's computation type and category
  - `ComputationType` union: `.stored`, `.resource_threshold`, `.balance_threshold`, `.sensory_threshold`, `.engagement_threshold`, `.positional`, `.any`
  - `Category` enum: `.stored`, `.internal`, `.relational`, `.positional`
  - `condition_definitions` table drives the `ConditionIterator` - adding conditions = adding rows
  - Comptime validation ensures resource thresholds are ordered worst-first

## Condition Caching & Querying
- `Agent.condition_cache` caches internal computed conditions (blood, pain, trauma, balance, sensory)
- `Agent.invalidateConditionCache()` recomputes cache and emits `condition_applied`/`condition_expired` events
- `Agent.hasCondition()` checks stored conditions + cache
- `Agent.hasConditionWithContext()` additionally checks relational conditions (requires engagement)
- `ConditionIterator` walks stored conditions then computed conditions from the definitions table

## Condition Event Emission (T016)
- `condition_applied`/`condition_expired` events defined in `events.zig`, formatted in `combat_log.zig`
- Computed conditions (pain/trauma thresholds): emit via `invalidateConditionCache()` after resource changes
- Stored conditions: emit directly when added (e.g., adrenaline_surge in `outcome.zig`)
- Key call site: `outcome.zig` after pain/trauma infliction calls `invalidateConditionCache()`
- Dud card injection (T015) consumes `condition_applied` events via `event_processor.zig`

## Pain & Trauma Conditions (T012)
- Pain conditions (accumulate toward 1.0): `distracted` (>30%), `suffering` (>60%), `agonized` (>85%)
- Trauma conditions (accumulate toward 1.0): `dazed` (>30%), `unsteady` (>50%), `trembling` (>70%), `reeling` (>90%)
- `incapacitated` triggers at >95% pain OR >95% trauma via `.any` computation type
- Thresholds use `.gt` comparator (contrast with blood's `.lt` since blood drains toward 0)

## Adrenaline Response (T013)
- `adrenaline_surge`: triggered on first significant wound (severity >= inhibited), lasts 8 ticks
- `adrenaline_crash`: successor to surge via `ConditionMeta.on_expire`, lasts 12 ticks
- Surge suppresses pain conditions via `ConditionMeta.suppresses = &.{.pain}`
- `ConditionIterator.isResourceSuppressed()` checks stored conditions' metadata before yielding resource conditions
- Successor transitions handled in `resolve.zig tickConditions()` on expiry

## Penalty System
- `Condition` enum in `damage.zig` enumerates all conditions
- `condition_penalties` table maps conditions to `CombatPenalties` (hit chance, damage mult, defense mult, dodge mod)
- `CombatModifiers.forAttacker/forDefender` iterates conditions and applies penalties
- Cards reference conditions via `Predicate.has_condition`/`.lacks_condition`, effects via `Effect.add_condition`/`remove_condition`
