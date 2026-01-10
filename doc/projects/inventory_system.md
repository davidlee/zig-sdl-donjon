# Inventory System

## Overview

A card-based inventory system where items, equipment, and consumables are represented
as cards with instance-level state. Integrates with the existing card mechanics,
body system, and damage model.

This is a multi-epic project touching:
- Card instance data model
- Equipment and armament systems
- UI for inventory/equipment management
- Physical attachment and container hierarchies
- Combat action economy for item interactions

## Design Principles

### Everything is a Card

Items are cards. A sword in your inventory is a card instance. Equipping it moves
the card between zones/states. The card's rules define what you can do with it
(equip, throw, use). The card's instance state tracks durability, enchantments, etc.

### No Abstract Carry

There is no invisible inventory. Everything a character carries must be physically
located:
- **Worn on body**: armour layers, jewelry, clothing
- **Strapped to body**: backpack, quiver, scabbard (Strapped layer)
- **Held in grasper**: weapon in hand, torch, carried object
- **Inside a container**: which is itself worn/strapped/held

Carrying capacity emerges from what containers you have equipped and what your
graspers are holding. No containers + hands full = can't pick up more without
dropping something.

### Consequences Over Constraints

The system allows "bad" decisions and imposes consequences rather than hard blocking.
Wearing plate without padding? Allowed, but expect chafing conditions over time.
This respects player agency while teaching through gameplay.

## Settled Design Decisions

### Item Cards and Instance State

Item cards use the kind-discriminated instance data model (see
`doc/issues/item_data_modelling.md`):

```
cards.Instance
  └─ kind_data: KindData
       └─ .item: ItemState
            ├─ integrity, quality, enchantments, contents
            └─ category_data: .weapon | .armour | .consumable
```

Item templates reference weapon/armour templates for their mechanical definitions.
The card is the item's identity throughout its lifecycle.

### Stackable Items

Fungible items (arrows, coins, rations) use stacking:
- `ItemState.quantity: u16` tracks stack size
- Using one decrements quantity (firing arrow, spending coin)
- Used items may instance into environment with degraded state
- Stacking is conditional: same template + compatible state (can't stack pristine
  arrows with damaged ones)

### In-Combat Interaction

All inventory access during combat is **card-mediated**:
- Item cards in hand can be played (use potion, throw weapon)
- Always-available actions target items (Quick Draw → pick weapon from equipment)
- Inventory/equipment UI acts as a **target picker modal** when cards require it
- Time costs handled by existing card cost system
- No free equipment changes - donning plate is not a 1-second action

### Out-of-Combat Interaction

Dedicated **Equipment** and **Inventory** screens with direct manipulation:

**Equipment Screen** (body-centric):
- Shows character with equipped items by body part/layer
- "What am I wearing and wielding?"
- Drag items onto body slots to equip
- Visual representation of layering
  - but - in a way that doesn't require a lot of bespoke textures

**Inventory Screen** (container-centric):
- Shows carried containers and their contents
- "What am I carrying and where?"
- Stack-based container navigation (one container open at a time)
- Drill into containers, back button to parent

Items can be moved between the two (equip from inventory, unequip to container).

### Container Navigation

Stack-based model to keep UI state simple (immediate-mode constraint):
- `open_container: ?entity.ID` - currently viewed container (null = top level)
- `container_stack: []entity.ID` - breadcrumb for back navigation
- View one container's contents at a time
- "Open" pushes to stack, "Back" pops

No windowing system, no multiple simultaneous open containers. Drag targets are
limited to visible items.

### Armour Layering

Uses existing `inventory.Layer` enum for ordering:
```
Skin → Underwear → CloseFit → Gambeson → Mail → Plate → Outer → Cloak → Strapped
```

**Soft validation**: UI warns about problematic layering (plate without padding)
but allows it. Gameplay consequences (conditions, reduced effectiveness) follow.

### Armament Revision

`Armament` will reference card instances rather than holding `*weapon.Instance`
directly. Exact representation (entity.ID vs pointer) TBD, but weapon stats resolve
through the card's template and instance state.

See `doc/issues/item_data_modelling.md` for detailed implications.

## Priorities and Sequencing

**Domain before UI.** The inventory/equipment screens can't be designed until we
know how things attach to bodies and what physical constraints apply. Don't start
UI work until the domain model is solid.

**Suggested sequencing:**

1. **Shared EntityID** (see `unified_entity_wrapper.md`) - Clean up entity identity
   before adding new entity types
2. **Physical properties unification** (see `physical_properties_unification.md`) -
   High-stakes, do it carefully
3. **Item entity type** (see `verbs_vs_nouns.md`) - Items as distinct from actions
4. **Container model** - Physical hierarchy, attachment to bodies
5. **UI** - Only after domain is stable

## Open Design Questions

### Zones and Ownership

`Zone.inventory` and `Zone.equipped` exist as placeholders but lack careful design.

**Core need**: Item cards must not shuffle into combat draw pile. They have a
different lifecycle than action cards.

**Assessment**: The existing zone system works fine for ownership semantics during
play. Containers introduce some lifetime management (child cleanup when container
destroyed), but that's a familiar pattern. The bigger concern is serialization -
persisting zone/container state to save files - but that's a general problem, not
inventory-specific.

**Open questions**:
- Is zone the right mechanism for ownership/lifecycle separation?
- Should zones map to physical location, or are those orthogonal?
- How do zones interact with container hierarchy?

Lower priority than physical properties and entity identity.

### Physical Attachment Model

"No abstract carry" implies items attach to bodies, but the model isn't fully
specified.

**Conceptual model** (previously explored): Worn items occupy a list of body parts
at a given attachment layer. An item's attachment *options* are a set of such lists
- the same backpack could be worn on back (shoulders + torso), slung over one
shoulder, or carried in hand. The specific attachment is chosen at equip time.

**Attachment modes for containers**:
- Backpack: straps over shoulders, sits on back
- Satchel: strap over one shoulder, hangs at hip
- Belt pouch: attached to belt at waist
- Quiver: strapped to back or hip
- Same bag might be carried 4-5 different ways

**Questions** (lower priority - model is conceptually sound):
- Exact data representation for attachment options
- How does this interact with body damage (lose arm → drop shoulder bag)?
- Integration with `inventory.Layer` and body part tags

### Container Capacity and Constraints

Containers have physical limits:
- Volume/size constraints (can't fit a greatsword in a belt pouch)
- Weight limits (overstuffed backpack affects mobility?)
- Shape constraints (rigid vs flexible containers)

**Questions**:
- How granular should capacity modeling be?
- Per-item size/weight vs simple slot counts?
- Should exceeding limits be soft (penalties) or hard (blocked)?

### Nested Container Depth

Physical constraints naturally limit nesting (backpack fits pouches, pouches don't
fit backpacks), but we haven't specified:
- Maximum practical depth expected (2-3 levels?)
- How does the UI gracefully degrade if someone creates deep nesting?
- Are there items that shouldn't go in containers at all (too large, unwieldy)?

### Combat Accessibility

Items in different locations have different accessibility during combat:
- Weapon in hand: immediately usable
- Potion on belt: quick to access (low time cost)
- Scroll in backpack: requires digging (high time cost? multi-step action?)

**Questions**:
- Should accessibility be implicit from container location?
- Or explicit metadata on container types?
- How does this interact with card `PlayableFrom` flags?

### Save/Load and Persistence

Item cards carry mutable state (integrity, enchantments, contents). This needs
serialization. Not designed yet, but should be considered early to avoid painful
retrofitting.

## Related Documents

### Foundational Design Questions

These issues explore architectural alternatives that affect the entire inventory
system. Decisions here inform implementation approach.

- `doc/issues/verbs_vs_nouns.md` - Are actions and items fundamentally different
  types? (Likely yes - items are nouns, actions are verbs)
- `doc/issues/unified_entity_wrapper.md` - Should Action, Item, Agent share a
  common identity/presentation layer?
- `doc/issues/physical_properties_unification.md` - Universal model for mass,
  dimensions, volume across weapons, bodies, armour, items
- `doc/issues/item_data_modelling.md` - Original "everything is a card" proposal
  (may be superseded by verbs_vs_nouns approach)

### Background

- `doc/ideas/shields_splinter_swords_chip.md` - Item degradation concepts

## Implementation Phases (Sketch)

These are rough groupings, not a committed plan:

**Phase 1: Foundation**
- Extend `cards.Instance` with `KindData`
- Item state basics (integrity, quality)
- Create item cards from weapon/armour templates

**Phase 2: Equipment Integration**
- Revise `Armament` to reference card instances
- Connect armour stack building to item cards
- Item damage during combat

**Phase 3: Inventory Management**
- Container model and hierarchy
- Out-of-combat inventory/equipment UI
- Drag-drop, stack-based navigation

**Phase 4: Combat Integration**
- Target picker modal for item selection
- Time costs for equipment changes
- Accessibility by container location

**Phase 5: Polish and Edge Cases**
- Stackable items and splitting
- Soft validation and consequence conditions
- Nested container edge cases