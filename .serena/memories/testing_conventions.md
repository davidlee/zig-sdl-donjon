# Testing Conventions for deck_of_dwarf

## Test Categories

### Unit Tests (`src/**/*.zig` inline test blocks)
- Test single functions/modules in isolation
- No cross-module dependencies - mock or stub if needed
- Fast, deterministic, no I/O
- Use `testing.allocator` to catch memory leaks
- Location: inline `test` blocks in source files

### Integration Tests (`src/testing/integration/`)
- Test multi-module collaboration (e.g., play card → timeline → tick → events)
- Use Harness for world/encounter setup
- May have ordering dependencies within a scenario
- Location: `src/testing/integration/domain/*.zig`

#### Harness API (src/testing/integration/harness.zig)
```zig
const Harness = @import("integration_root").integration.harness.Harness;

// Lifecycle
var h = try Harness.init(allocator);
defer h.deinit();

// Setup
_ = try h.addEnemyFromTemplate(&personas.Agents.ser_marcus);
try h.beginSelection();  // Initializes combat state, enters selection phase

// Card management
const card_id = try h.giveCard(h.player(), "slash"); // Add to hand
const thrust_id = h.findAlwaysAvailable("thrust"); // Find pool card

// Play control
try h.playCard(card_id, target_id);
try h.commitPlays();  // Transition to commit phase
try h.resolveTick();  // Process one tick
try h.resolveAllTicks();  // Process all ticks

// Inspection
h.getPlays();  // Returns []const TimeSlot
h.playerStamina();  // Current stamina value
h.playerAvailableStamina();  // Stamina minus reserved

// Events
h.expectEvent(.played_action_card);  // Assert event exists
h.expectNoEvent(.card_cancelled);  // Assert event absent
h.hasEvent(.tick_ended);  // Bool check
h.clearEvents();  // Clear pending events
```

### System Tests (`src/testing/system/`)
- Full application flows
- Reserved for future use
- Location: `src/testing/system/*.zig`

## Running Tests

```bash
# All checks: format + all tests + build
just check

# Individual test suites
just test-unit
just test-integration
just test-system

# All tests (no format/build)
just test

# With output (see all test names)
just test-verbose
just test-unit "--summary all"
```

## Test Philosophy

### Focus on Behaviour
- Test what the code does, not how it does it
- Assert on outcomes and invariants, not internal state
- Avoid brittle assertions (exact event ordering, log strings)

### Use Fixtures
- Persona templates in `src/data/personas.zig` for consistent test agents/weapons/encounters
- `AgentHandle` from `src/testing/fixtures.zig` for proper ownership/cleanup
- Share setup between tests and game content where sensible

### Example Unit Test
```zig
const testing = std.testing;
const fixtures = @import("testing").fixtures;
const personas = @import("data").personas;

test "agent takes damage reducing health" {
    const handle = try fixtures.agentFromTemplate(testing.allocator, &personas.Agents.ser_marcus);
    defer handle.deinit();
    
    const agent = handle.agent;
    const initial_health = agent.health;
    
    agent.takeDamage(10);
    
    try testing.expectEqual(initial_health - 10, agent.health);
}
```

### Naming
- Describe behaviour: `test "damage reduces health to minimum of zero"`
- Not implementation: `test "takeDamage calls reduceHealth helper"` (bad)

## When Tests Need More Setup

If a unit test requires:
- Full `World` instance
- `Encounter` with enemies
- Card registry + combat state

→ It's probably an integration test. Use T020 harness or defer to integration suite.

## Key Files

- `src/testing/fixtures.zig` - AgentHandle, agentFromTemplate
- `src/testing/integration/harness.zig` - (T020) world/encounter setup
- `src/data/personas.zig` - shared test personas
- `Justfile` - test commands
