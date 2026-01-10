# T047: Unified Entity ID Implementation Guide

This document provides implementation details for adding kind discrimination to
`entity.ID`.

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

## Implementation Plan

We skip the "optional field" dance. Just make `kind` required from the start,
fix compiler errors. SlotMap gets `kind` at construction so `insert()` produces
correct IDs automatically.

### Step 1: Add EntityKind enum

```zig
// src/entity.zig
pub const EntityKind = enum(u8) {
    action,
    agent,
    weapon,
    // item, // reserved for future
};
```

### Step 2: Add required kind field to ID

```zig
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

### Step 3: Update SlotMap to hold kind

```zig
// src/slot_map.zig
pub fn SlotMap(comptime T: type) type {
    return struct {
        // ... existing fields ...
        kind: entity.EntityKind,

        pub fn init(allocator: Allocator, kind: entity.EntityKind) Self {
            return .{
                .kind = kind,
                // ... existing init ...
            };
        }

        pub fn insert(self: *Self, value: T) !entity.ID {
            // ... existing slot logic ...
            return .{
                .index = @intCast(index),
                .generation = generation,
                .kind = self.kind,
            };
        }
    };
}
```

### Step 4: Fix compiler errors

The compiler will flag every site that:
- Creates a SlotMap without providing kind
- Creates an entity.ID struct literal without kind

**Expected sites**:
- `CardRegistry` init → pass `.action`
- `EntityMap.agents` init → pass `.agent`
- `EntityMap.weapons` init → pass `.weapon`
- Test fixtures creating mock IDs → add appropriate kind
- Any struct literal `.{ .index = x, .generation = y }` → add `.kind = ...`

**Grep to find all sites**:
```bash
rg "entity\.ID\{" --type zig
rg "SlotMap\(" --type zig -A2
```

### Step 5: Run tests

```bash
just check
```

### Step 6: Add World.getEntity() (unified lookup)

```zig
// src/entity.zig or src/domain/world.zig
pub const Entity = union(enum) {
    action: *cards.Instance,
    agent: *combat.Agent,
    weapon: *weapon.Instance,

    pub fn asAction(self: Entity) ?*cards.Instance {
        return if (self == .action) self.action else null;
    }
    // ... similar for agent, weapon
};

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

### Step 7: Cleanup

- Add `ItemRegistry` placeholder (empty, for T048)
- Update memories if entity.ID semantics are something future sessions need

## Files Changed (Expected)

**Definitely touched**:
- `src/entity.zig` - ID struct, EntityKind enum
- `src/slot_map.zig` - kind field, init signature
- `src/domain/world.zig` - CardRegistry, EntityMap, World

**Likely touched** (ID creation sites):
- `src/domain/combat/agent.zig`
- `src/domain/combat/encounter.zig`
- `src/testing/fixtures.zig`
- Various test files

## Verification Checklist

- [x] `just check` passes
- [x] All IDs created with appropriate kind (no undefined/default)
- [x] `World.getEntity()` returns correct types (add test)
- [x] Event system still works (events reference entity IDs)
- [x] Combat scenarios pass (cards, agents, weapons)
