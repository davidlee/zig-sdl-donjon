# Test Infrastructure Improvements

## 1. Test Fixture Toolkit

**Goal:** Stop cloning weapon/agent setup logic in every unit test. Currently there are 6+ duplicate `makeTestAgent` implementations across the codebase (agent.zig, positioning.zig, apply.zig, outcome.zig, damage.zig, context.zig).

### Location

Create `src/testing/fixtures.zig` with helper builders. Keep fixtures in their own module so domain files don't accidentally import them.

### Allocator & Teardown Policy

All fixture helpers accept an explicit `std.mem.Allocator` (typically `std.testing.allocator`). Fixtures that allocate memory return a handle struct with a `deinit(alloc)` method. Callers are responsible for calling `defer handle.deinit(alloc)`.

Pattern:
```zig
const TestAgentHandle = struct {
    agent: *Agent,
    agents_map: *SlotMap(*Agent),  // owned
    sword: *weapon.Instance,       // owned

    pub fn deinit(self: *TestAgentHandle, alloc: std.mem.Allocator) void {
        self.agent.deinit();
        alloc.destroy(self.sword);
        self.agents_map.deinit();
        alloc.destroy(self.agents_map);
    }
};

pub fn testAgent(alloc: std.mem.Allocator, overrides: TestAgentOverrides) !TestAgentHandle { ... }
```

### API Surface

```zig
// Agent builders
pub fn testAgent(alloc: Allocator, overrides: TestAgentOverrides) !TestAgentHandle
pub fn testAgentWithArmament(alloc: Allocator, armament: Armament, overrides: TestAgentOverrides) !TestAgentHandle

// World builder (owns card registry, encounter, player)
pub fn testWorld(alloc: Allocator, opts: TestWorldOptions) !TestWorldHandle

// Card helpers
pub fn testCard(world: *World, template_name: []const u8) !entity.ID

// Common stat defaults (for TestAgentOverrides)
pub fn defaultStamina() stats.Resource { ... }
pub fn defaultFocus() stats.Resource { ... }
pub fn defaultBlood() stats.Resource { ... }

// Engagement helpers
pub fn withEnemyAtRange(world: *World, range: combat.Reach) !*Agent
```

### TestAgentOverrides

```zig
pub const TestAgentOverrides = struct {
    director: ?combat.Director = null,
    stamina: ?stats.Resource = null,
    focus: ?stats.Resource = null,
    blood: ?stats.Resource = null,
    body_plan: ?*const body.Plan = null,
};
```

### Deliverables

- Shared fixture file with agent/world/card builders and cleanup routines.
- Update representative unit tests (e.g., `apply/validation.zig` which has 6 skipped tests, `combat/plays.zig`) to use these helpers as proof of concept.

---

## 2. Integration Test Harness

**Goal:** Exercise real card flows end-to-end (play → timeline → tick → events), not just isolated helpers.

### Location

Add `src/testing/integration/` with top-level `integration.zig` that includes scenario tests.

### Harness API

The harness provides granular control over turn phases and state inspection:

```zig
pub const Harness = struct {
    alloc: std.mem.Allocator,
    world: *World,

    pub fn init(alloc: Allocator, opts: HarnessOptions) !Harness { ... }
    pub fn deinit(self: *Harness) void { ... }

    // --- Card Management ---
    pub fn addToHand(self: *Harness, template_name: []const u8) !entity.ID { ... }
    pub fn playCard(self: *Harness, card_id: entity.ID, target: ?entity.ID) !void { ... }
    pub fn stackModifier(self: *Harness, play_idx: usize, modifier_name: []const u8) !void { ... }
    pub fn cancelPlay(self: *Harness, play_idx: usize) !void { ... }

    // --- Phase Control (granular) ---
    pub fn transitionTo(self: *Harness, phase: combat.TurnPhase) !void { ... }
    pub fn commitPlays(self: *Harness) !void { ... }  // selection → commit
    pub fn resolveTick(self: *Harness) !void { ... }  // runs one tick of resolution
    pub fn resolveAllTicks(self: *Harness) !void { ... }  // drains timeline

    // --- State Inspection ---
    pub fn getHand(self: *Harness) []const entity.ID { ... }
    pub fn getPlays(self: *Harness) []const combat.Play { ... }
    pub fn getTimeline(self: *Harness) *const combat.Timeline { ... }
    pub fn getEncounter(self: *Harness) *combat.Encounter { ... }

    // --- Event Assertions ---
    pub fn expectEvent(self: *Harness, expected: events.EventTag) !void { ... }
    pub fn expectNoEvent(self: *Harness, tag: events.EventTag) !void { ... }
    pub fn drainEvents(self: *Harness) []const events.Event { ... }

    // --- Encounter Manipulation ---
    pub fn setEngagementRange(self: *Harness, range: combat.Reach) !void { ... }
    pub fn addEnemy(self: *Harness, overrides: TestAgentOverrides) !*Agent { ... }
};
```

### Card Template Registration

**Performance concern:** Loading full `card_list` for every integration test adds overhead. Instead, provide a minimal registry builder:

```zig
pub const HarnessOptions = struct {
    templates: []const *const cards.Template = &.{},  // explicit list
    use_beginner_deck: bool = false,                   // or load standard set
};

// Usage:
const h = try Harness.init(alloc, .{
    .templates = &.{ card_list.t_thrust, card_list.t_parry, card_list.t_sidestep },
});
```

Scenarios don't depend on production card data; they register only the templates they need.

### Initial Scenarios

1. **"Player plays thrust, enemy blocks"** → check plays created during selection, commit → tick resolves to "blocked + stamina deduction".
2. **"Pool card clone lifecycle"** → ensure clone created, cooldown set, destroyed after resolution/cancel.
3. **"Modifier stacking & cancel"** → stack modifier, cancel, verify cards returned/destroyed correctly.
4. **"Manoeuvre vs positioning contest"** → pulls in timing/priority rules.

---

## 3. Test Execution Strategy

### Build Targets

Add `zig build test-unit` and `zig build test-integration` targets in `build.zig`:

```zig
// In build.zig
const unit_tests = b.addTest(.{
    .root_source_file = b.path("src/domain/mod.zig"),
    // ...
});
const unit_step = b.step("test-unit", "Run unit tests");
unit_step.dependOn(&b.addRunArtifact(unit_tests).step);

const integration_tests = b.addTest(.{
    .root_source_file = b.path("src/testing/integration/integration.zig"),
    // ...
});
const integration_step = b.step("test-integration", "Run integration tests");
integration_step.dependOn(&b.addRunArtifact(integration_tests).step);
```

### Developer Workflow Integration

Update `Justfile`:

```just
test-unit:
  zig build test-unit

test-integration:
  zig build test-integration

test: test-unit test-integration
```

Unit tests live next to their modules. Integration tests live under `src/testing/integration`.

---

## 4. Documentation & Style Guide Updates

- Expand the `style_conventions` memory to mention:
  - "Use `testing/fixtures.zig` for shared setup; avoid re-creating agents inline"
  - "Prefer integration scenarios in `src/testing/integration` for multi-phase flows"
- Document the fixture helpers in `doc/testing.md` (new file) so contributors know how to use/extend them.

---

## Next Steps

1. Implement `testing/fixtures.zig` with agent/world/card helpers and upgrade `apply/validation.zig` (6 skipped tests) as proof of concept.
2. Introduce the integration harness and write the first scenario covering selection → commit → resolution.
3. Update `build.zig` and `Justfile` to expose `test-unit` / `test-integration`.
4. Document the fixture/integration testing approach for future contributors.
