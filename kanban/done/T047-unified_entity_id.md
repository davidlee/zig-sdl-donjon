# T047: Unified Entity ID with Kind Discrimination
Created: 2026-01-11

## Problem statement / value driver

`entity.ID` currently has no kind discrimination - it's just `{ index, generation }`
that addresses a slot in some SlotMap. Code "just knows" which registry to look up
based on context. This works but:

- Prevents unified event targeting (can't have `target: entity.ID` that works for
  agents, items, and actions)
- Makes serialization harder (ID alone doesn't tell you what it refers to)
- Blocks the inventory system (Items need to be a distinct entity type)

### Scope - goals

- Add `kind: EntityKind` to `entity.ID`
- Update all registries to work with kind-aware IDs
- Enable polymorphic entity lookup via `World.getEntity(id)`

### Scope - non-goals

- Presentation unification (separate concern, dealt with later)
- Item entity type (T048+, depends on this)
- Physical properties unification (separate track)

## Background

### Relevant documents

- `doc/artefacts/T047-unified_entity_id_implementation.md` - **Implementation guide**
- `doc/issues/unified_entity_wrapper.md` - Design exploration
- `doc/projects/inventory_system.md` - Why this matters

### Key files

- `src/entity.zig` - ID definition, EntityKind enum
- `src/domain/world.zig` - ActionRegistry, EntityMap, Entity union, ItemRegistry
- `src/domain/slot_map.zig` - Underlying storage with kind field

### Existing systems

Registries now include kind:
- `world.action_registry: ActionRegistry` → `SlotMap(*cards.Instance)` with `.action`
- `world.entities.agents: *SlotMap(*combat.Agent)` with `.agent`
- `world.entities.weapons: *SlotMap(*weapon.Instance)` with `.weapon`

## Changes Required

See `doc/artefacts/T047-unified_entity_id_implementation.md` for detailed plan.

### Approach

Direct implementation - no phased optional→required dance. SlotMap gets `kind` at
construction, `insert()` automatically produces correctly-kinded IDs. Fix compiler
errors as they arise.

## Tasks / Sequence of Work

- [x] Add `EntityKind` enum to `entity.zig`
- [x] Add required `kind: EntityKind` field to `ID`, update `eql()`
- [x] Update `SlotMap` to hold kind at construction, use in `insert()`
- [x] Fix all compiler errors (registry inits, test fixtures, ID literals)
- [x] Run `just check`
- [x] Add `World.getEntity()` unified lookup with `Entity` tagged union
- [x] Add test for `World.getEntity()` returning correct types
- [x] Add `ItemRegistry` placeholder (empty, for T048)
- [x] Update memories/docs

## Test / Verification Strategy

### success criteria / ACs
- [x] `entity.ID` has `kind: EntityKind` field
- [x] All IDs created with appropriate kind
- [x] `World.getEntity()` returns correct entity type
- [x] Existing tests pass

### unit tests
- [x] ID equality with same/different kinds (via eql)
- [x] Registry create/get roundtrip with kind verification

### integration tests
- [x] Combat scenarios still work (agent/card IDs)
- [x] Event system handles entity references

## Quality Concerns / Risks

- **Scope creep**: Don't solve Item entity type here. Just the ID infrastructure.
- **Memory**: Adding a field to every ID. Should be negligible (one u8 or smaller).

## Progress Log / Notes

2026-01-11: Implementation complete.
- Added `EntityKind` enum with: action, agent, weapon, armour, item
- Added required `kind: EntityKind` field to `entity.ID`
- Updated `SlotMap.init()` to take kind parameter, `insert()` uses it automatically
- Fixed ~50 call sites (SlotMap inits, ID literals in tests)
- Added `World.getEntity()` with `Entity` tagged union for polymorphic lookup
- Added `ItemRegistry` placeholder for T048
- All tests pass (`just check` green)

2026-01-11: Follow-up naming consistency.
- Renamed `CardRegistry` → `ActionRegistry`
- Renamed `card_registry` → `action_registry` across codebase
- Created T048 card for future `cards.zig` → `actions.zig` rename
