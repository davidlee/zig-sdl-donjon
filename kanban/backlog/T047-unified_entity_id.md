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

- `src/entity.zig` - ID definition
- `src/domain/world.zig` - CardRegistry, EntityMap
- `src/slot_map.zig` - Underlying storage

### Existing systems

Current registries:
- `world.card_registry: CardRegistry` → `SlotMap(*cards.Instance)`
- `world.entities.agents: *SlotMap(*combat.Agent)`
- `world.entities.weapons: *SlotMap(*weapon.Instance)`

All use the same `entity.ID` type without discrimination.

## Changes Required

See `doc/artefacts/T047-unified_entity_id_implementation.md` for detailed plan.

### Decisions

- Add `kind: EntityKind` field to `entity.ID`
- Keep separate storage (type-specific registries)
- Phase in gradually: optional → required → switch-based lookup

## Tasks / Sequence of Work

### Phase 1: Add optional Kind (backwards compatible)
- [ ] Add `EntityKind` enum to `entity.zig`
- [ ] Add `kind: ?EntityKind = null` field to `ID`
- [ ] Update `ID.eql()` to handle kind comparison
- [ ] All existing code continues to work (kind is null/ignored)

### Phase 2: Populate Kind at creation
- [ ] `CardRegistry.create()` sets `kind = .action`
- [ ] `EntityMap` agent creation sets `kind = .agent`
- [ ] `EntityMap` weapon creation sets `kind = .weapon`
- [ ] Add assertions that kind is set where expected

### Phase 3: Make Kind required
- [ ] Change `kind: ?EntityKind` to `kind: EntityKind`
- [ ] Fix any compilation errors (places that create IDs without kind)
- [ ] Update tests

### Phase 4: Unified lookup
- [ ] Add `World.getEntity(id: entity.ID) ?Entity` that switches on kind
- [ ] Define `Entity` tagged union wrapping the different entity types
- [ ] Migrate any code that would benefit from polymorphic lookup

### Phase 5: Cleanup
- [ ] Rename registries for clarity if needed
- [ ] Add `ItemRegistry` placeholder (empty, for T048)
- [ ] Update memories/docs

## Test / Verification Strategy

### success criteria / ACs
- `entity.ID` has `kind: EntityKind` field
- All IDs created with appropriate kind
- `World.getEntity()` returns correct entity type
- Existing tests pass

### unit tests
- ID equality with same/different kinds
- Registry create/get roundtrip with kind verification

### integration tests
- Combat scenarios still work (agent/card IDs)
- Event system handles entity references

## Quality Concerns / Risks

- **Scope creep**: Don't solve Item entity type here. Just the ID infrastructure.
- **Memory**: Adding a field to every ID. Should be negligible (one u8 or smaller).
- **Breaking changes**: Phase 1-2 are backwards compatible. Phase 3 is a breaking
  change but contained to ID creation sites.

## Progress Log / Notes
