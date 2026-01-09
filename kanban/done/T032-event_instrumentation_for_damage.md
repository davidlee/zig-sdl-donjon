# T032: Event Instrumentation for Damage Packets
Created: 2026-01-09

## Problem statement / value driver

Phase 1 of the Geometry/Energy/Rigidity data audit (§8.1 & §9.4 of `geometry_momentum_rigidity_review.md`) requires instrumentation to capture real combat packets so we can compare derived axis values against observed wounds. Currently, individual events exist for technique resolution, armour interaction, and wound infliction, but no single event captures the complete packet lifecycle from creation through layer stack to body damage.

### Scope - goals

- Add a `combat_packet_resolved` event capturing the full damage pipeline in one place
- Provide enough data for Phase 1 audit analysis (amounts, penetration, layer outcomes)
- Keep implementation minimal—defer structured logging drain to a follow-up

### Scope - non-goals

- Structured file/JSON logging (audit drain) — that's a separate ticket
- UI integration for richer damage numbers — that can consume this event later
- Modifying the damage/armour resolution logic itself

## Background

### Relevant documents

- `doc/artefacts/geometry_momentum_rigidity_review.md` §9.5 (Event-System Instrumentation Plan)
- `doc/artefacts/geometry_momentum_rigidity_review.md` §8.1 (Data Audit & Instrumentation)

### Key files

- `src/domain/events.zig` — Event union and EventSystem
- `src/domain/resolution/outcome.zig` — `resolveTechniqueVsDefense()` where packet is created, armour resolved, body damaged
- `src/domain/damage.zig` — `Packet` struct
- `src/domain/armour.zig` — `AbsorptionResult` struct

### Existing systems, memories, research, design intent

- `events_system_overview` memory describes the double-buffered event bus
- `combat_resolution_overview` memory describes the resolution pipeline
- Events are already emitted at each phase (`technique_resolved`, `armour_absorbed`, `wound_inflicted`, etc.) but fragmented across the pipeline
- The new event consolidates packet data in one place for easier auditing

## Changes Required

1. Add `combat_packet_resolved` variant to `Event` union in `events.zig`
2. Emit the event in `resolveTechniqueVsDefense()` after body damage is applied (or after armour if no body damage)
3. Tests verifying the event is emitted with correct data

### Event payload (draft)

```zig
combat_packet_resolved: struct {
    attacker_id: entity.ID,
    defender_id: entity.ID,
    technique_id: cards.TechniqueID,
    target_part: body.PartIndex,
    // Input packet
    initial_amount: f32,
    initial_penetration: f32,
    damage_kind: damage.Kind,
    // After armour
    post_armour_amount: f32,
    post_armour_penetration: f32,
    // Layer summary
    armour_layers_hit: u8,
    armour_deflected: bool,
    gap_found: bool,
    // Body outcome
    wound_severity: ?u8, // worst severity as int, null if no wound
},
```

### Challenges / Tradeoffs / Open Questions

1. **Payload size**: Should we embed full `Packet` structs or flatten to primitives? Flattening keeps the event union simpler and avoids pointer/lifetime issues.
2. **Emission point**: Emit once at the end of `resolveTechniqueVsDefense`, or also on misses? → Only emit on hits (when a packet exists).

### Decisions

- Flatten packet fields into primitives (no embedded structs)
- Emit only when `dmg_packet != null` (i.e., on hits)

## Tasks / Sequence of Work

1. [x] Add `combat_packet_resolved` to `Event` union
2. [x] Emit event at end of hit branch in `resolveTechniqueVsDefense()`
3. [x] Add test verifying event emission with expected values
4. [x] Run `just check` (format, test, compile)
5. [ ] Update `events_system_overview` memory if needed (deferred—event follows existing pattern)

## Test / Verification Strategy

### success criteria / ACs

- On a successful hit, `combat_packet_resolved` event is pushed with correct attacker/defender IDs, technique, packet amounts (before/after armour), and wound severity
- Existing tests remain green
- No changes to resolution logic behaviour

### unit tests

- Test in `outcome.zig` or a new test file: set up attack context, call `resolveTechniqueVsDefense`, pop events, assert `combat_packet_resolved` present with expected fields

### integration tests

- Existing combat tests should continue to pass (no breaking changes)

## Quality Concerns / Risks / Potential Future Improvements

- When Geometry/Energy/Rigidity axes land, this event payload will need to expand to include axis values — design should anticipate that
- A follow-up ticket should add the "audit drain" subscriber that writes these events to structured logs

## Progress Log / Notes

- 2026-01-09: Card created from §9.5 of geometry review doc
- 2026-01-09: Implementation complete
  - Added `combat_packet_resolved` event variant to `src/domain/events.zig:142-160`
  - Emitting event in `resolveTechniqueVsDefense()` at `src/domain/resolution/outcome.zig:286-305`
  - Test added: `resolveTechniqueVsDefense emits combat_packet_resolved on hit`
  - All tests pass, build clean
  - Note: `just check` has a pre-existing CUE generation issue (unrelated); verified with `zig build test` and `zig fmt`
