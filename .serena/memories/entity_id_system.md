# Entity ID System

## Overview
Unified entity identification via `entity.ID` with kind discrimination. Enables polymorphic entity lookup across different registries.

## Key Types

### entity.ID (src/entity.zig)
```zig
pub const EntityKind = enum(u8) {
    action,  // cards.Instance
    agent,   // combat.Agent  
    weapon,  // weapon.Instance
    armour,  // armour.Instance (no registry yet)
    item,    // T048 placeholder
};

pub const ID = struct {
    index: u32,
    generation: u32,
    kind: EntityKind,
    
    pub fn eql(self: ID, other: ID) bool; // compares kind + index + generation
};
```

### SlotMap (src/domain/slot_map.zig)
Generational slot-map that holds a `kind` field. IDs returned from `insert()` automatically include the correct kind.
```zig
pub fn init(alloc: Allocator, kind: entity.EntityKind) !Self
pub fn insert(self: *Self, value: T) !entity.ID  // uses self.kind
```

### Entity Union (src/domain/world.zig)
```zig
pub const Entity = union(lib.entity.EntityKind) {
    action: *cards.Instance,
    agent: *combat.Agent,
    weapon: *weapon.Instance,
    armour: void,  // no registry yet
    item: void,    // T048 placeholder
    
    pub fn asAction(self: Entity) ?*cards.Instance;
    pub fn asAgent(self: Entity) ?*combat.Agent;
    pub fn asWeapon(self: Entity) ?*weapon.Instance;
};
```

### World.getEntity()
Unified lookup that dispatches to the correct registry based on ID kind:
```zig
pub fn getEntity(self: *World, id: lib.entity.ID) ?Entity
```

## Current Registries
- `world.action_registry: ActionRegistry` → SlotMap with `.action`
- `world.entities.agents` → SlotMap with `.agent`
- `world.entities.weapons` → SlotMap with `.weapon`

## Creating IDs
Never construct entity.ID manually except in tests. Use:
- `SlotMap.insert()` for new entities (auto-populates kind)
- Registry-specific create methods (e.g., `CardRegistry.create()`)

## Test Helpers
Test code uses `testId(index, kind)` helper functions to create test IDs with explicit kinds.
