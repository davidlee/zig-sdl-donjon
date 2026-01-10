# T047: Unified Entity ID Implementation Guide

This document provides implementation details for adding kind discrimination to
`entity.ID`. The goal is to make this work boring - follow the steps, run tests,
done.

## Current State

```zig
// src/entity.zig
pub const ID = struct {
    index: u32,
    generation: u32,

    pub fn eql(self: ID, other: ID) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};
```

No kind field. Code "just knows" which registry an ID belongs to.

**Current registries** (src/domain/world.zig):
- `CardRegistry` - `SlotMap(*cards.Instance)` - actions/cards
- `EntityMap.agents` - `SlotMap(*combat.Agent)` - agents
- `EntityMap.weapons` - `SlotMap(*weapon.Instance)` - weapons (legacy, may merge)

## Target State

```zig
// src/entity.zig
pub const EntityKind = enum(u8) {
    action,   // cards.Instance (was "card")
    agent,    // combat.Agent
    weapon,   // weapon.Instance (legacy, may become item)
    item,     // future: Item entity
};

pub const ID = struct {
    index: u32,
    generation: u32,
    kind: EntityKind,

    pub fn eql(self: ID, other: ID) bool {
        return self.kind == other.kind and
               self.index == other.index and
               self.generation == other.generation;
    }
};
```

## Phase 1: Add Optional Kind (Backwards Compatible)

**Goal**: Add the field without breaking anything.

### Step 1.1: Add EntityKind enum

```zig
// src/entity.zig
pub const EntityKind = enum(u8) {
    action,
    agent,
    weapon,
    // item, // reserved for future
};
```

### Step 1.2: Add optional kind field to ID

```zig
pub const ID = struct {
    index: u32,
    generation: u32,
    kind: ?EntityKind = null,  // optional for backwards compat

    pub fn eql(self: ID, other: ID) bool {
        // If both have kinds, they must match
        // If either is null, ignore kind in comparison (legacy compat)
        const kinds_match = if (self.kind != null and other.kind != null)
            self.kind.? == other.kind.?
        else
            true;
        return kinds_match and
               self.index == other.index and
               self.generation == other.generation;
    }
};
```

### Step 1.3: Run tests

```bash
just check
```

All existing tests should pass. The optional field with default `null` means
existing code creating IDs continues to work.

## Phase 2: Populate Kind at Creation

**Goal**: All new IDs get appropriate kind. Existing IDs remain null until touched.

### Step 2.1: Update CardRegistry.create()

```zig
// src/domain/world.zig - CardRegistry
pub fn create(self: *CardRegistry, template: *const cards.Template) !*cards.Instance {
    const instance = try self.alloc.create(cards.Instance);
    var id = try self.entities.insert(instance);
    id.kind = .action;  // <-- ADD THIS
    instance.* = .{ .id = id, .template = template };
    return instance;
}
```

### Step 2.2: Update SlotMap.insert() to accept kind hint

Option A: Pass kind to insert:
```zig
pub fn insert(self: *Self, value: T, kind: ?entity.EntityKind) !entity.ID {
    // ... existing logic ...
    return .{
        .index = @intCast(index),
        .generation = generation,
        .kind = kind,
    };
}
```

Option B: Set kind after insert (simpler, shown in 2.1)

**Recommendation**: Option B (set after insert). Less invasive to SlotMap.

### Step 2.3: Update EntityMap agent creation

Find where agents are created and ensure kind is set:
```zig
// Agent creation site (likely Agent.init or encounter setup)
var id = try world.entities.agents.insert(agent_ptr);
id.kind = .agent;
agent_ptr.id = id;
```

### Step 2.4: Update EntityMap weapon creation

```zig
var id = try world.entities.weapons.insert(weapon_ptr);
id.kind = .weapon;
weapon_ptr.id = id;
```

### Step 2.5: Add debug assertions

```zig
// In places that expect a specific kind:
std.debug.assert(id.kind == null or id.kind == .action);
```

This catches misuse without breaking legacy code.

### Step 2.6: Run tests

```bash
just check
```

## Phase 3: Make Kind Required

**Goal**: Remove the optional. All IDs must have a kind.

### Step 3.1: Change field type

```zig
pub const ID = struct {
    index: u32,
    generation: u32,
    kind: EntityKind,  // no longer optional

    pub fn eql(self: ID, other: ID) bool {
        return self.kind == other.kind and
               self.index == other.index and
               self.generation == other.generation;
    }
};
```

### Step 3.2: Fix compilation errors

The compiler will flag every place that creates an ID without setting kind.
Fix each one by providing the appropriate kind.

**Expected sites**:
- `SlotMap.insert()` - needs kind parameter or callers set it
- Test fixtures creating mock IDs
- Any place using struct literal `.{ .index = x, .generation = y }`

### Step 3.3: Update tests

Tests that create IDs directly need to specify kind:
```zig
const test_id = entity.ID{ .index = 0, .generation = 0, .kind = .action };
```

### Step 3.4: Run tests

```bash
just check
```

## Phase 4: Unified Lookup

**Goal**: `World.getEntity(id)` returns the right entity type.

### Step 4.1: Define Entity union

```zig
// src/domain/world.zig or src/entity.zig
pub const Entity = union(enum) {
    action: *cards.Instance,
    agent: *combat.Agent,
    weapon: *weapon.Instance,

    pub fn asAction(self: Entity) ?*cards.Instance {
        return if (self == .action) self.action else null;
    }
    // ... similar for agent, weapon
};
```

### Step 4.2: Add World.getEntity()

```zig
// src/domain/world.zig - World struct
pub fn getEntity(self: *World, id: entity.ID) ?entity.Entity {
    return switch (id.kind) {
        .action => if (self.card_registry.get(id)) |inst|
            .{ .action = inst }
        else
            null,
        .agent => if (self.entities.agents.get(id)) |ptr|
            .{ .agent = ptr.* }
        else
            null,
        .weapon => if (self.entities.weapons.get(id)) |ptr|
            .{ .weapon = ptr.* }
        else
            null,
        .item => null, // not yet implemented
    };
}
```

### Step 4.3: Use where appropriate

Look for patterns like:
```zig
// Before: caller "knows" it's a card
const instance = world.card_registry.get(some_id);

// After: can be polymorphic if needed
const entity = world.getEntity(some_id);
if (entity) |e| switch (e) {
    .action => |inst| // ...
    .agent => |ag| // ...
    // ...
};
```

Don't force this everywhere - only where polymorphism is actually useful.

## Phase 5: Cleanup

### Step 5.1: Add ItemRegistry placeholder

```zig
// src/domain/world.zig
pub const ItemRegistry = struct {
    // Empty for now - T048 will populate
    pub fn init(alloc: std.mem.Allocator) !ItemRegistry {
        _ = alloc;
        return .{};
    }
    pub fn deinit(self: *ItemRegistry) void {
        _ = self;
    }
};

// In World struct:
item_registry: ItemRegistry,
```

### Step 5.2: Consider registry renaming

Current: `card_registry` → Maybe rename to `action_registry`?

This is optional and can be deferred. The code works either way.

### Step 5.3: Update memories

Update `project_overview` or create new memory if entity.ID semantics
are something future sessions should know about.

## Files Changed (Expected)

**Definitely touched**:
- `src/entity.zig` - ID struct, EntityKind enum
- `src/domain/world.zig` - CardRegistry, EntityMap, World
- `src/slot_map.zig` - possibly, if insert signature changes

**Likely touched** (ID creation sites):
- `src/domain/combat/agent.zig`
- `src/domain/combat/encounter.zig`
- `src/testing/fixtures.zig`
- Various test files

**Grep to find all sites**:
```bash
rg "entity\.ID\{" --type zig
rg "\.insert\(" src/domain/world.zig
```

## Verification Checklist

- [ ] `just check` passes after each phase
- [ ] No `kind: null` remaining after Phase 3
- [ ] `World.getEntity()` returns correct types (add test)
- [ ] Event system still works (events reference entity IDs)
- [ ] Combat scenarios pass (cards, agents, weapons)
