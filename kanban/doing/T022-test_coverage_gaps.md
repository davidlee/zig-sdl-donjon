# T022: Test Coverage Gaps
Created: 2026-01-08

## Problem statement / value driver

Audit identified high-risk areas without test coverage. These are critical paths that mutate game state or form the boundary between domain and presentation.


### Scope - goals

Add test coverage for:
- Command handler (`apply/command_handler.zig`, `apply/event_processor.zig`)
- World lifecycle (`world.zig` - transitions, turn FSM, tick pipeline)
- Query boundary (`query/combat_snapshot.zig` - sync with world state)

### Scope - non-goals

- Exhaustive coverage - focus on high-risk paths identified in audit
- Presentation layer tests
- New harness infrastructure (T020 built that)

## Background

### Relevant documents

- `doc/issues/test_setup.md` - Audit section (line 270+)

### Key files

- `doc/issues/test_coverage_audit.md` - IMPORTANT - READ THIS and keep up to date.

- `src/domain/apply/command_handler.zig` - play/cancel/commit workflows
- `src/domain/apply/event_processor.zig` - event emission
- `src/domain/world.zig` - world transitions, cleanup
- `src/domain/query/combat_snapshot.zig` - domain→presentation boundary

### Existing systems, memories, research, design intent

From audit:
> Command stack: No tests exercising play/cancel/commit workflows, pending targets, or event emission. These are high-risk because they mutate game state and route user commands.

> World lifecycle: Card registry has tests, but world transitions (start encounter, turn FSM, tick pipeline) and cleanup paths are untested.

> Domain ↔ presentation query boundary: query/combat_snapshot.zig only has a couple of tiny tests; nothing verifies it stays in sync with world state.

## Changes Required

### 1. Command Handler Tests

- Play workflow: hand card → play created → in pending
- Cancel workflow: play removed → card returned to source
- Commit workflow: plays moved to timeline
- Event emission for each action

### 2. World Lifecycle Tests

- Start encounter: world state initialized correctly
- Turn FSM: phase transitions in correct order
- Tick pipeline: ticks processed, events emitted
- Cleanup: resources freed, no leaks

### 3. Query Snapshot Tests

- Snapshot reflects current world state
- Modifier attachability computed correctly
- Targeting DTOs accurate
- Snapshot updates after world mutations

### Challenges / Tradeoffs / Open Questions

- Some of these may need T019 fixtures or T020 harness
- World lifecycle tests may blur into integration territory
- Decide: unit test with mocks, or wait for T020 harness?

## Tasks / Sequence of Work

### Phase 1: Command Handler Integration Tests (card_flow.zig)

Uses T020 harness since these require World + Encounter + combat state.

1. ✓ Add `cancelCard` helper to harness
2. ✓ Test: cancel pool card clone → clone destroyed, stamina returned
3. ✓ Test: cancel hand card → card returned to hand, time returned
4. ✓ Test: commitWithdraw → card removed from timeline, focus cost applied
5. ✓ Test: commitStack → modifier stacked on play

### Phase 2: Event Processor Tests (integration)

6. ✓ Test: full turn cycle (selection → commit → resolve)
7. ✓ Test: tick resolution emits technique_resolved event

### Phase 3: Combat Snapshot Tests

8. ✓ Test: buildSnapshot resolves play targets correctly
9. ✓ Test: buildSnapshot card status reflects playability

### Phase 4: World Lifecycle

10. ✓ FSM transitions tested via full turn cycle test

## Test / Verification Strategy

### success criteria / ACs

- Each identified gap has at least one test covering the happy path
- `just check` passes
- No new skipped tests

### Test locations

| Area | Location | Rationale |
|------|----------|-----------|
| Command handler | `src/testing/integration/domain/card_flow.zig` | Requires World + Encounter + combat state |
| Event processor | `src/testing/integration/domain/card_flow.zig` | Same - needs full game state |
| Combat snapshot | `src/domain/query/combat_snapshot.zig` (inline) + integration | Simple lookups unit-testable; buildSnapshot needs World |
| World lifecycle | `src/testing/integration/domain/card_flow.zig` | FSM + tick pipeline = integration |

## Quality Concerns / Risks / Potential Future Improvements

- Start with unit tests where possible; escalate to integration if setup too complex
- Document any deferred items for T020

## Progress Log / Notes

- 2026-01-08: Task created from audit in doc/issues/test_setup.md
- Depends on: T019 (fixtures), T020 (harness)
- 2026-01-08: Reviewed audit, updated task breakdown into 4 phases.
- 2026-01-08: Completed Phase 1-2, partial Phase 3-4. Added 7 new integration tests:
  - Cancel pool card clone, cancel hand card
  - Withdraw play in commit phase, stack modifier
  - Full turn cycle, tick resolution events
  - Harness helpers: cancelCard, withdrawCard, stackModifier, playerFocus, playerHand, isInHand, isOnCooldown
- 2026-01-08: Completed Phase 3 (Combat Snapshot Tests):
  - Fixed memory leak in `filterTargetsByMeleeRange` (targeting.zig) - two early returns weren't freeing `target_ids`
  - Added 2 buildSnapshot integration tests: play target resolution, card status playability
  - Tests require player with thrusting weapon (player_swordsman persona) and enemy at melee range