# Test Infrastructure Improvements

## Test Taxonomy

- **Unit tests**: Single module in isolation, mocking/stubbing collaborators. Live next to their modules.
- **Integration tests**: Multiple units working together (imports collaborators). Exist at various scales - from testing two local collaborators up to exercising the entire domain layer. Organized by feature/functionality, not arbitrary component labels.
- **System tests**: The whole application running together, end-to-end.

Integration tests may have subfolders by layer (`domain/`, `presentation/`, `rendering/`) but within those, tests are named for what they exercise (e.g., `card_flow.zig`, `damage_resolution.zig`), not for which "component" they touch.

---

## 1. Test Fixtures: Personas

**Goal:** Stop cloning weapon/agent setup logic in every unit test. Currently 6+ duplicate `makeTestAgent` implementations across the codebase.

### Philosophy

Rather than generic builders with override bags, define a small set of **memorable, named personas** - characters and items with personality that cover common test scenarios. Think of them as the "test cast" for the game.

These live in `src/data/personas.zig` (or similar) and are **shared comptime registries with the game proper** - so test personas can also appear as actual game content. Double bang for buck.

### Example Personas

```zig
// src/data/personas.zig - shared between game and tests

pub const Agents = struct {
    /// Naked dwarf with a rock. Baseline melee combatant, minimal equipment.
    pub const grunni_the_desperate = AgentTemplate{
        .name = "Grunni the Desperate",
        .body_plan = &body.DwarfPlan,
        .armament = .{ .single = &weapons.thrown_rock },
        .armour = null,  // loincloth doesn't count
        .stamina = stats.Resource.init(8, 8, 1),
        .focus = stats.Resource.init(2, 3, 1),
        // ...
    };

    /// Cowardly goblin archer. Ranged, low stats, will flee.
    pub const snik = AgentTemplate{
        .name = "Snik",
        .body_plan = &body.GoblinPlan,
        .armament = .{ .single = &weapons.shortbow },
        .director = .cowardly,
        // ...
    };

    /// Veteran human swordsman. Well-rounded baseline for "competent enemy".
    pub const ser_marcus = AgentTemplate{
        .name = "Ser Marcus",
        .body_plan = &body.HumanoidPlan,
        .armament = .{ .single = &weapons.knights_sword },
        .armour = &armour.chain_hauberk,
        // ...
    };
};

pub const Weapons = struct {
    /// Garbage magic sword. Tests magic weapon code paths without being OP.
    pub const maybe_haunted = weapon.Template{
        .name = "Maybe Haunted",
        .reach = .sabre,
        .damage_type = .slash,
        .damage_base = 3,
        .tags = .{ .magic = true },
        .flavor = "Hums tunelessly. Probably fine.",
    };

    /// Basic rock. For when you need the simplest possible weapon.
    pub const thrown_rock = weapon.Template{
        .name = "Rock",
        .reach = .dagger,
        .damage_type = .blunt,
        .damage_base = 1,
    };
};

pub const Encounters = struct {
    /// 1v1 at sword range. Most common test scenario.
    pub const duel_at_sword_range = EncounterTemplate{
        .player = &Agents.ser_marcus,
        .enemies = &.{&Agents.snik},
        .initial_range = .sabre,
    };

    /// Player outnumbered by archers.
    pub const goblin_ambush = EncounterTemplate{
        .player = &Agents.grunni_the_desperate,
        .enemies = &.{ &Agents.snik, &Agents.snik, &Agents.snik },
        .initial_range = .spear,  // they're keeping distance
    };
};
```

### Test Usage

```zig
const personas = @import("data/personas.zig");
const fixtures = @import("testing/fixtures.zig");

test "thrust beats no-defense at sword range" {
    const alloc = std.testing.allocator;
    var world = try fixtures.worldFromEncounter(alloc, &personas.Encounters.duel_at_sword_range);
    defer world.deinit();

    // test proceeds with memorable, known entities
}
```

### Allocator & Teardown Policy

All fixture helpers accept an explicit `std.mem.Allocator` (typically `std.testing.allocator`). Fixtures that allocate memory return a handle struct with a `deinit()` method. Callers use `defer handle.deinit()`.

### Fixture API

```zig
// src/testing/fixtures.zig

/// Instantiate an agent from a persona template.
pub fn agentFromTemplate(alloc: Allocator, template: *const AgentTemplate) !AgentHandle

/// Instantiate a full encounter from a template.
pub fn worldFromEncounter(alloc: Allocator, template: *const EncounterTemplate) !WorldHandle

/// Add a card to an agent's hand by template name.
pub fn giveCard(world: *World, agent: *Agent, template_name: []const u8) !entity.ID
```

### Deliverables

- `src/data/personas.zig` with ~5-8 agent personas, ~3-4 weapon/item personas, ~3 encounter setups.
- `src/testing/fixtures.zig` with instantiation helpers and teardown.
- Update `apply/validation.zig` (6 skipped tests) and `combat/plays.zig` as proof of concept.

---

## 2. Integration Tests

**Goal:** Exercise collaborating units at various scales, organized by feature.

### Location

`src/testing/integration/` with subfolders by layer:

```
src/testing/integration/
  domain/
    card_flow.zig         # play → timeline → tick → events
    damage_resolution.zig # hit → armour → wound → conditions
    positioning.zig       # manoeuvres, range changes, flanking
  presentation/
    combat_log.zig        # events → log entries → formatting
  mod.zig                 # includes all
```

Tests are named for the **feature or flow** being exercised, not the "component under test".

### Harness (for domain integration)

A lightweight harness for driving combat flows:

```zig
pub const Harness = struct {
    alloc: std.mem.Allocator,
    world: *World,

    pub fn init(alloc: Allocator, encounter: *const EncounterTemplate) !Harness { ... }
    pub fn deinit(self: *Harness) void { ... }

    // --- Card Management ---
    pub fn giveCard(self: *Harness, agent: *Agent, name: []const u8) !entity.ID
    pub fn playCard(self: *Harness, card_id: entity.ID, target: ?entity.ID) !void
    pub fn stackModifier(self: *Harness, play_idx: usize, name: []const u8) !void
    pub fn cancelPlay(self: *Harness, play_idx: usize) !void

    // --- Phase Control ---
    pub fn transitionTo(self: *Harness, phase: combat.TurnPhase) !void
    pub fn commitPlays(self: *Harness) !void
    pub fn resolveTick(self: *Harness) !void
    pub fn resolveAllTicks(self: *Harness) !void

    // --- Inspection ---
    pub fn player(self: *Harness) *Agent
    pub fn enemy(self: *Harness, idx: usize) *Agent
    pub fn getPlays(self: *Harness) []const combat.Play
    pub fn getTimeline(self: *Harness) *const combat.Timeline

    // --- Events ---
    pub fn expectEvent(self: *Harness, tag: events.EventTag) !void
    pub fn expectNoEvent(self: *Harness, tag: events.EventTag) !void
    pub fn drainEvents(self: *Harness) []const events.Event
};
```

### Example Scenarios

**card_flow.zig:**
- "Player plays thrust, enemy blocks" → selection → commit → tick → stamina deducted, blocked event
- "Pool card clone lifecycle" → clone created, cooldown set, destroyed after resolution
- "Modifier stacking & cancel" → stack, cancel, verify lifecycle

**damage_resolution.zig:**
- "Slash hits unarmoured limb" → wound severity, bleeding condition
- "Thrust blocked by shield" → stamina cost, no wound
- "Critical to vital organ" → incapacitation check

**positioning.zig:**
- "Advance closes range" → range change event
- "Retreat from dagger vs spear" → now out of range for dagger
- "Flanking bonus" → advantage applied

---

## 3. Test Execution Strategy

### Build Targets

In `build.zig`:

```zig
const unit_tests = b.addTest(.{
    .root_source_file = b.path("src/domain/mod.zig"),
});
const unit_step = b.step("test-unit", "Run unit tests");
unit_step.dependOn(&b.addRunArtifact(unit_tests).step);

const integration_tests = b.addTest(.{
    .root_source_file = b.path("src/testing/integration/mod.zig"),
});
const integration_step = b.step("test-integration", "Run integration tests");
integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

const all_tests = b.step("test", "Run all tests");
all_tests.dependOn(unit_step);
all_tests.dependOn(integration_step);
```

### Justfile

```just
test-unit:
  zig build test-unit

test-integration:
  zig build test-integration

test: test-unit test-integration
```

---

## 4. Documentation & Style Guide Updates

- Update `style_conventions` memory:
  - "Use personas from `data/personas.zig` for test setup; don't reinvent agents inline"
  - "Integration tests go in `testing/integration/<layer>/`, named by feature"
- Add `doc/testing.md` documenting personas and fixture usage.

---

## Next Steps

1. Define initial personas in `src/data/personas.zig` (~5-8 agents, ~3-4 weapons, ~3 encounters).
2. Implement `src/testing/fixtures.zig` with instantiation helpers.
3. Migrate `apply/validation.zig` skipped tests as proof of concept.
4. Set up `src/testing/integration/domain/card_flow.zig` with first scenario.
5. Wire up `build.zig` and `Justfile`.

# Preliminary audit

High-Value Areas Without Coverage

  - Command stack (apply/command_handler.zig, apply/event_processor.zig): No tests exercising play/cancel/commit workflows, pending
    targets, or event emission. These are high-risk because they mutate game state and route user commands.
  - World lifecycle (world.zig): Card registry has tests, but world transitions (start encounter, turn FSM, tick pipeline) and
    cleanup paths are untested.
  - Timeline selection refactor: plays during selection design isn’t covered. No tests ensure plays are created with timing/channels
    during selection phase or that buildPlaysFromInPlayCards replacements behave.
  - Domain ↔ presentation query boundary: query/combat_snapshot.zig only has a couple of tiny tests; nothing verifies it stays in
    sync with world state or supports modifier attachability, targeting DTOs, etc.
  - Integration flows: Nothing runs a full “play card → commit → tick resolve → apply costs” scenario. Many bugs will hide until we
    add integration tests in src/tests/integration.

  ———

  Brittle / Duplicated Tests

  - Fixtures ad hoc everywhere: Each test re-creates weapons, agents, world state (copy/paste of makeTestAgent, manual card registry
    setup). When templates or agent fields change, dozens of tests break. We need shared object mothers (tests/fixtures.zig).
  - Redundant coverage: Unit tests sprinkled across apply.zig, apply/validation.zig, and apply/targeting.zig duplicate the same
    predicate/targeting scenarios after the file split. We can consolidate them into the new module-specific tests and delete the
    legacy ones in apply.zig.
  - Brittle assumptions: Tests that expect exact event ordering or rely on global state (e.g., std.debug.print output) will fail with
    minor refactors. We should focus on invariants (cards returned to hand, clones destroyed) instead of specific log strings.

  ———

  Pseudo-Integration Tests Still in Unit Files

  Several test blocks pull in half the domain via imports, effectively running multi-module flows inside unit files:

  - apply/targeting.zig tests instantiate World, call world.card_registry.create, and use real combat.Play objects. These are closer
    to integration cases and would be better in a dedicated suite.
  - combat/plays.zig tests exercise TurnState, Timeline, AgentEncounterState, etc., often needing multiple modules. They’re
    legitimate but highlight the need for fixtures.
  - resolution/context.zig and resolution/outcome.zig tests drive the full resolution pipeline (advantage, events, damage). These
    should either be simplified to pure math helpers or moved to integration tests that call TickResolver.

  ———

  Actionable Plan

  1. Create shared fixture module (tests/fixtures.zig) providing helper builders for agents, worlds, cards. Update a few existing
     tests to use it.
  2. Introduce an integration test harness under src/tests/integration/ covering at least:
      - Play/cancel lifecycle for hand vs. pool cards
      - Commit phase + tick resolution for a simple duel
      - Range/manoeuvre interactions
  3. Audit tests per module:
      - Remove duplicate tests from src/domain/apply.zig now that modules have their own test blocks.
      - Add missing coverage for command handler, world transitions, and query snapshots.
  4. Document expectations in doc/issues/test_setup.md: list the gaps above, note the brittle patterns (manual setup, copy/paste
     fixtures), and outline the integration-test plan so contributors know where to add new cases.

  This brings clarity to what’s missing, reduces duplication, and sets the stage for the upcoming integration test suite.
