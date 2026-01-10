# Unified Entity Wrapper: Actions, Items, Agents

## Context

If we separate Actions (verbs) from Items (nouns) as distinct types
(see `doc/issues/verbs_vs_nouns.md`), a question remains:

Should Action, Item, and Agent share a common wrapper for lifecycle, identity,
and presentation?

## The Observation

These entity types have similarities:
- **Lifecycle**: created, moved between zones/locations, destroyed
- **Identity**: unique `entity.ID`, can be referenced, looked up
- **Presentation**: shown to player as "cards" (rectangular UI elements with art/text)
- **Ownership**: belong to someone or somewhere (agent's hand, inventory, environment)

Currently:
- Actions (cards): `cards.Instance` with `entity.ID`, lives in `CardRegistry`
- Items (weapons): `weapon.Instance` with `entity.ID`, lives in `Agent.weapons`
- Items (armour): `armour.Instance` with `entity.ID`, lives in `Agent.armour`
- Agents: `Agent` struct, lives in `World.entities.agents`

Each has its own registry/storage, its own ID allocation, its own lifecycle
management.

## The Question

Does it make sense to unify these under a common entity system?

```zig
pub const Entity = union(enum) {
    action: *Action,
    item: *Item,
    agent: *Agent,
};

pub const EntityRegistry = struct {
    // Single ID space, single storage
    entities: SlotMap(Entity),

    pub fn get(id: entity.ID) ?Entity { ... }
    pub fn create(e: Entity) entity.ID { ... }
};
```

Or should they remain separate registries with a thin wrapper only for
presentation?

```zig
// Presentation-only wrapper, not stored
pub const CardView = union(enum) {
    action: *const Action,
    item: *const Item,
    agent: *const Agent,

    pub fn render(self: CardView, ...) void { ... }
    pub fn name(self: CardView) []const u8 { ... }
};
```

## Arguments For Unification

1. **Single ID space**: No confusion about which registry an ID belongs to. One ID
   type, one lookup.

2. **Uniform zone/location tracking**: "Where is entity X?" has one answer path
   regardless of entity type.

3. **Simplified event system**: Events can reference any entity uniformly.
   `target: entity.ID` works for actions, items, and agents.

4. **Loot/rewards**: "Drop a random card" can mean action, item, or agent (summoned
   creature?) without special-casing.

5. **Future extensibility**: New entity types (traps? terrain features?) slot into
   the same system.

## Arguments Against Unification

1. **Different storage needs**: Actions are mostly stateless (template + modifiers).
   Items have rich physical state. Agents have bodies, conditions, combat state.
   Forcing them into one registry may be awkward.

2. **Different query patterns**: "All items in this container" vs "All actions in
   this hand" vs "All agents in this encounter" are different queries. Unified
   storage doesn't help and may hurt.

3. **Type safety**: Separate registries give compile-time guarantees. `Agent.weapons`
   can only hold weapon items. A unified registry loses this.

4. **Refactor scope**: Touching every system that handles entities. High risk.

5. **YAGNI**: If the only benefit is presentation, a thin view wrapper achieves
   that without restructuring storage.

## Middle Ground: Shared ID Space, Separate Storage

```zig
// IDs are globally unique across all entity types
pub const EntityID = struct {
    index: u32,
    generation: u16,
    kind: EntityKind,  // action, item, agent
};

// But storage is separate
pub const World = struct {
    actions: ActionRegistry,
    items: ItemRegistry,
    agents: AgentRegistry,

    pub fn getEntity(id: EntityID) ?Entity {
        return switch (id.kind) {
            .action => .{ .action = self.actions.get(id) },
            .item => .{ .item = self.items.get(id) },
            .agent => .{ .agent = self.agents.get(id) },
        };
    }
};
```

This gives:
- Uniform ID type for cross-references
- Type-specific storage and queries
- Entity wrapper for polymorphic operations
- Less invasive than full unification

## Presentation Unification

Regardless of storage, the UI can treat all entities as "cards":

```zig
pub const CardPresentation = struct {
    name: []const u8,
    description: []const u8,
    art_id: ?ArtID,
    rarity: Rarity,
    tags: TagSet,
    // ... common visual properties

    pub fn fromAction(a: *const Action) CardPresentation { ... }
    pub fn fromItem(i: *const Item) CardPresentation { ... }
    pub fn fromAgent(a: *const Agent) CardPresentation { ... }
};
```

The presentation layer doesn't care about the underlying type. It renders cards.

## Impact Assessment

**Full unification**: Touches World, all registries, all code that creates/queries
entities. Weeks of work. High risk.

**Middle ground (shared ID, separate storage)**: Touches ID types, lookup code,
cross-reference sites. Days of work. Medium risk.

**Presentation-only wrapper**: Touches UI layer only. Hours of work. Low risk.

## Open Questions

1. Are there concrete use cases where unified storage helps beyond presentation?
   (Loot tables, event targeting, zone tracking?)

2. Does the current `entity.ID` type already support kind discrimination, or would
   that need adding?

3. How does this interact with serialization? Easier or harder to save/load with
   unified vs separate storage?

## Recommendation

**Adopt the middle ground: shared ID space with separate storage.**

The presentation-only wrapper is insufficient. Key systems need to reference
entities polymorphically:

- **Event targeting**: `target: EntityID` must work for attacking an Agent,
  sundering an Item, or canceling an Action. The event system shouldn't need
  separate code paths per entity type.

- **Damage application**: When a sword chips against plate, both the weapon (Item)
  and the armour (Item) take integrity damage. The resolution pipeline needs
  uniform entity references.

- **Serialization**: Save/load needs to persist entity references. A uniform ID
  type with kind discrimination simplifies this significantly.

The memory cost is minimal - adding a `kind: EntityKind` field to IDs. Storage
remains separate (type-specific registries), preserving query efficiency and
type safety where it matters.

**Sequencing**: This work should come *before* physical properties unification.
Getting entity identity clean first means the physical properties refactor doesn't
also have to deal with entity reference inconsistencies.

Full unification (single storage for all entity types) remains overkill - the
storage needs of Agents, Items, and Actions are too different.
