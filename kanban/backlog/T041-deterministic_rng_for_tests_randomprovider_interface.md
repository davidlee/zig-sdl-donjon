# T041: Deterministic RNG for Tests (RandomProvider Interface)
Created: 2026-01-10

## Problem statement / value driver
Data-driven combat tests (T040) pass but with weak assertions (`damage_dealt_min: 0`) because attacks can miss due to RNG. We need deterministic random values for reproducible, meaningful test assertions.

### Scope - goals
- Introduce `RandomProvider` interface following Director pattern
- Allow tests to inject scripted random values
- Enable tight assertions in combat tests (exact outcomes, not ranges)

### Scope - non-goals
- Seeded PRNG (hunting for "good" seeds is gross)
- Comptime feature flags

## Background

### Relevant documents
- T040 task card (F2 follow-up)
- `src/domain/ai.zig` - Director pattern reference

### Key files
- `src/domain/random.zig` - Stream, RandomStreamDict, RandomStreamID
- `src/domain/world.zig` - World.drawRandom(), World.getRandomSource()
- `src/testing/integration/domain/data_driven_combat.zig` - consumer

### Current flow
```
outcome.zig:155 -> w.drawRandom(.combat) -> world.random.combat.prng.random().float(f32)
                                                      |
                                   if roll > final_chance -> miss
                                   else -> hit
```

All random draws go through `World.drawRandom(id)` which emits events.

## Design

### RandomProvider interface (Director-style vtable)

```zig
// In random.zig
pub const RandomProvider = struct {
    ptr: *anyopaque,
    drawFn: *const fn (ptr: *anyopaque, id: RandomStreamID) f32,

    pub fn draw(self: RandomProvider, id: RandomStreamID) f32 {
        return self.drawFn(self.ptr, id);
    }
};
```

### Production implementation

```zig
pub const StreamRandomProvider = struct {
    dict: RandomStreamDict,

    pub fn provider(self: *StreamRandomProvider) RandomProvider {
        return .{ .ptr = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, id: RandomStreamID) f32 {
        const self: *StreamRandomProvider = @ptrCast(@alignCast(ptr));
        return self.dict.get(id).random().float(f32);
    }
};
```

### Test double

```zig
pub const ScriptedRandomProvider = struct {
    values: []const f32,
    index: usize = 0,

    pub fn provider(self: *ScriptedRandomProvider) RandomProvider {
        return .{ .ptr = self, .drawFn = draw };
    }

    fn draw(ptr: *anyopaque, _: RandomStreamID) f32 {
        const self: *ScriptedRandomProvider = @ptrCast(@alignCast(ptr));
        defer self.index += 1;
        return self.values[self.index % self.values.len];
    }
};
```

### World changes

```zig
// Replace: random: RandomStreamDict
// With:
random_provider: random.RandomProvider,

pub fn drawRandom(self: *World, id: random.RandomStreamID) !f32 {
    const r = self.random_provider.draw(id);
    try self.events.push(.{ .draw_random = .{ .stream = id, .result = r } });
    return r;
}
```

### Tradeoffs considered

| Option | Pro | Con |
|--------|-----|-----|
| A. Optional null override | Simple, ~free perf | Test concern in prod struct |
| **B. Director vtable** | Clean abstraction, matches patterns | Indirect call overhead |
| C. Tagged union | Explicit alternatives | Must modify union for new types |

Chose B for consistency with existing Director pattern. Perf cost immeasurable for turn-based game.

## Tasks

1. Add `RandomProvider`, `StreamRandomProvider`, `ScriptedRandomProvider` to `random.zig`
2. Update `World` to use `RandomProvider` instead of `RandomStreamDict`
3. Update `World.init()` to create `StreamRandomProvider`
4. Update `World.drawRandom()` to use provider
5. Verify `getRandomSource()` still works (may need adjustment)
6. Add harness helper or expose provider for tests
7. Update data-driven combat tests to use scripted values
8. Tighten CUE test assertions (remove `damage_dealt_min: 0` workarounds)

## Test / Verification Strategy

### Success criteria
- Same test input always produces same output
- `sword_slash_vs_plate` asserts exact outcome (deflected) not range

### Unit tests
- `ScriptedRandomProvider` returns values in sequence, wraps around

### Integration tests
- Data-driven combat tests with scripted rolls produce expected outcomes
