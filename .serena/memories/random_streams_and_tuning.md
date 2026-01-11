# Random Streams & Combat Tuning Constants

## Random Stream Infrastructure

All combat randomness MUST go through `world.drawRandom(stream_id)` for:
- **Reproducibility**: Seeded runs for testing/replay
- **Event tracing**: Random draws emit `draw_random` events
- **Future extensibility**: Stance weights can modify draws

### Key Types (src/domain/random.zig)
- `RandomStreamID` — enum of stream purposes (`.combat`, etc.)
- `RandomProvider` — interface with `draw(id) -> f32`
- `StreamRandomProvider` — production implementation (default in World)
- `ScriptedRandomProvider` — testing helper with predetermined values

### Usage Pattern
```zig
// CORRECT: Production code
const roll = try world.drawRandom(.combat);

// WRONG: Bypasses event tracing
const roll = rng.float(f32);  // Never do this in combat code
```

### Testing with Controlled Random
For unit tests needing deterministic randomness:
```zig
const TestWorld = struct {
    world: *World,
    scripted: *random.ScriptedRandomProvider,

    fn init(alloc: Allocator, values: []const f32) !TestWorld {
        const scripted = try alloc.create(random.ScriptedRandomProvider);
        scripted.* = .{ .values = values };
        const world = try World.init(alloc);
        world.random_provider = scripted.provider();
        return .{ .world = world, .scripted = scripted };
    }
};
```

### Acceptable std.Random Usage
- `random.zig` itself (infrastructure)
- Test code using `std.Random.DefaultPrng` for isolated unit tests
- `armour.zig:resolveThroughArmour` — intentionally for testing; production uses `resolveThroughArmourWithEvents`

## Combat Tuning Constants

As of T049, all gameplay-affecting magic numbers are extracted to named `pub const` with doc comments.

### Central Reference
`src/domain/resolution/tuning.zig` re-exports all combat tuning constants for documentation:
- Hit chance modifiers (base, multipliers, clamp bounds)
- Guard coverage bonuses/penalties
- Condition modifiers (blinded, winded, grasp, flanking, mobility)

### Source Locations
- `resolution/outcome.zig` — 12 hit chance constants
- `resolution/context.zig` — 13 condition modifier constants  
- `apply/effects/positioning.zig` — manoeuvre contest constants (weights, variance, thresholds)

### Naming Convention
- Descriptive names: `guard_direct_cover_penalty` not `GDCP`
- Doc comments explain effect: "Higher values increase upset potential"
- Group related constants together
