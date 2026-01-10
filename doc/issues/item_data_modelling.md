# Item Data Modelling

> **Note**: This document explores embedding item state in `cards.Instance`. An
> alternative approach - treating actions (verbs) and items (nouns) as fundamentally
> different types - is explored in `doc/issues/verbs_vs_nouns.md`. That approach may
> be cleaner and is currently favored. This document remains as context for the
> design exploration.

## Problem Statement

The game aspires to "everything is a card" - items, equipment, consumables are all
represented as cards. However, the current `cards.Instance` type is too minimal to
support item-specific state:

```zig
pub const Instance = struct {
    id: entity.ID,
    template: *const Template,
};
```

Items require instance-level variation that techniques and actions don't:
- **Durability/integrity**: shields splinter, swords chip, plate dents
- **Quality**: masterwork vs crude
- **Material overrides**: this sword is steel, that one is bronze
- **Enchantments/modifiers**: flaming, keen, blessed
- **Contained items**: a scabbard holding a dagger, a quiver with arrows

A "Slash" technique is always the same Slash. But *this* knight's sword has 80%
durability and a fire enchantment while *that* one is pristine but mundane.

### The Type-Level Constraint

This isn't "optional data that some cards happen to have." It's **required data for
a subtype of card**:

- Item cards *require* item instance state
- Technique/action cards have *no* item state (and it would be nonsensical)
- The card's `Kind` determines what instance data is valid/required

### Current Architecture Gaps

1. **`cards.Instance`** - No mechanism for kind-specific instance state
2. **`Agent.inventory`** - Holds `entity.ID`s but nothing populates or uses them
3. **`Armament`** - Holds `*weapon.Instance` directly, separate from card system
4. **`Agent.armour`** - Holds `*armour.Instance` directly, separate from card system
5. **`weapon.Instance` / `armour.Instance`** - Exist outside the card model entirely

If weapons and armour are to be cards, the current separation creates problems:
- How does `Armament` reference a weapon that's also a card?
- How do we model a chipped flaming sword's damage output AND structural integrity?
- How do cards move between zones (inventory → equipped → dropped → picked up)?

## Proposed Solution: Kind-Discriminated Instance Data

Extend `cards.Instance` with kind-specific state:

```zig
pub const Instance = struct {
    id: entity.ID,
    template: *const Template,

    // Balatro-style modifiers (future: seals, foils, etc.)
    modifiers: ModifierSet = .{},

    // Kind-specific instance state
    // Required for item cards, absent for action/technique cards
    kind_data: KindData = .none,
};

pub const KindData = union(enum) {
    none,                    // actions, techniques, reactions, etc.
    item: ItemState,         // weapons, armour, consumables, containers
    // future: mob, ally, environment with mutable state
};

pub const ItemState = struct {
    // Physical condition (0.0 = destroyed, 1.0 = pristine)
    integrity: f32 = 1.0,

    // Quality tier (affects base stats)
    quality: Quality = .standard,

    // Material (may override template default)
    material_id: ?MaterialId = null,

    // Enchantments/magical properties
    enchantments: []const Enchantment = &.{},

    // For containers: what's inside
    contents: []entity.ID = &.{},

    // Item-category-specific data
    category_data: CategoryData = .none,
};

pub const CategoryData = union(enum) {
    none,
    weapon: WeaponState,
    armour: ArmourState,
    consumable: ConsumableState,
};

pub const WeaponState = struct {
    // Edge/point condition for bladed weapons
    edge_integrity: f32 = 1.0,
    // Ammunition for ranged
    ammo_count: ?u16 = null,
};

pub const ArmourState = struct {
    // Per-coverage-zone integrity (indexed same as template coverage)
    zone_integrity: []f32,
};

pub const ConsumableState = struct {
    charges: u8,
};
```

### Template-Side Changes

The `cards.Template` needs to declare item properties for item cards:

```zig
pub const Template = struct {
    // ... existing fields ...

    // For item cards: the item definition
    item_def: ?ItemDefinition = null,
};

pub const ItemDefinition = struct {
    category: ItemCategory,  // weapon, armour, consumable, container, misc

    // References to existing type-specific templates
    weapon_template: ?*const weapon.Template = null,
    armour_template: ?*const armour.Template = null,

    // Base properties
    weight: f32,
    value: u32,
    default_material: MaterialId,

    // Slots/layers this item occupies when equipped
    equip_slots: []const EquipSlot,
};
```

## Implications

### Armament Revision

`Armament` currently holds `*weapon.Instance`. If weapons are item cards:

**Option A**: Armament holds card instance IDs
```zig
pub const Armament = struct {
    equipped: Equipped,
    natural: []const species.NaturalWeapon,

    pub const Equipped = union(enum) {
        unarmed,
        single: entity.ID,        // card instance ID
        dual: struct {
            primary: entity.ID,
            secondary: entity.ID,
        },
        compound: [][]entity.ID,
    };
};
```

Weapon stats are resolved by: `card_registry.get(id).kind_data.item.category_data.weapon`
plus `card_registry.get(id).template.item_def.weapon_template`.

**Option B**: Armament holds pointers to card Instances directly
```zig
pub const Equipped = union(enum) {
    unarmed,
    single: *cards.Instance,
    // ...
};
```

Avoids registry lookup but creates lifetime/ownership questions.

### Armour Integration

Similarly, `Agent.armour: []*armour.Instance` becomes card-based. The `armour.Stack`
build process would iterate equipped item cards with armour category data.

### Zone Movement

Item cards naturally support zone transitions:
- `inventory` → `equipped`: equip action
- `equipped` → `inventory`: unequip action
- `equipped`/`inventory` → `environment`: drop/throw
- `environment` → `inventory`: pick up

The card's `entity.ID` is the item's identity throughout its lifecycle.

### Damage to Items

When armour absorbs damage or weapons clash:
1. Resolve through existing 3-axis physics
2. Apply integrity damage to `ItemState.integrity` or `CategoryData` fields
3. Below thresholds: item becomes damaged (reduced effectiveness)
4. At zero: item is destroyed (card exhausted/removed)

This connects directly to `doc/ideas/shields_splinter_swords_chip.md`.

## Open Questions

1. **Entity ownership**: Who owns the `ItemState` memory? The `CardRegistry`? Need
   allocation strategy for dynamic arrays (enchantments, contents, zone_integrity).

2. **Natural weapons**: Species natural weapons (fist, bite) aren't items. Keep them
   separate in `Armament.natural`, or model as innate pseudo-cards?

3. **Consumable charges vs card exhaustion**: A potion with 3 charges - is that 3
   uses before exhaust, or 3 separate "dose" cards?

4. **Template item_def vs generated data**: Item templates are CUE-generated. How
   does `item_def` integrate with `weapon_list`, `armour_list`?

5. **Instance creation**: When creating an item card, who initializes `ItemState`?
   The `CardRegistry.create()` would need item-aware logic or a separate factory.

## Next Steps

1. Validate this model against concrete use cases:
   - Equip a sword from inventory
   - Sword takes damage in combat, becomes chipped
   - Drop damaged sword, enemy picks it up
   - Enchanted armour with per-zone integrity

2. Prototype `KindData` extension to `cards.Instance`

3. Design `Armament` revision to use card instance references

4. Integrate with existing weapon/armour physics (3-axis damage model)

---
## A critical reading:

  ### Strengths

- Single source of truth: Making every item a card keeps identity, movement between zones, and modifiers
consistent. That aligns with “everything is a card” and avoids bolting on separate inventory systems.
- Kind-discriminated state cleanly separates technique cards (stateless) from items (stateful) without forcing
every card to drag around weapon-specific data.
- Extensible structure: ItemState + CategoryData + future unions gives us a place to add armour durability, weapon
ammo, enchantments, etc. without exploding the base cards.Instance.
- Direct tie-in to damage model: Having per-zone integrity and edge condition makes it easier to apply wear-and-
tear (shields splinter, swords chip) as envisioned.

### Risks & trade-offs

1. Memory/layout growth: Every cards.Instance now carries a union + optional allocations. Even if techniques
    use .none, we incur branching/indirection. If we expect thousands of non-item cards, we should size the union
    carefully or consider splitting items into their own storage.
2. Ownership & lifetime: Item state includes slices (enchantments, contents, per-zone integrity). We need a clear
    allocator/registry story (probably CardRegistry) to avoid leaks/dangling pointers when cards move between
    zones, get destroyed, or are referenced by systems like Armament.
3. Armament indirection: Switching Armament to hold card IDs (or pointers) means every combat action has to
    resolve through the card registry. That’s a long-term benefit (consistency) but will add runtime indirection
    and raises concurrency/lifetime considerations. We should confirm this won’t complicate low-level combat hot
    paths.
4. Schema duplication: Item templates would reference weapon_template / armour_template, which themselves are
    generated entities. We must ensure we don’t end up with circular or redundant data—maybe the CUE pipeline
    should emit card definitions directly so we don’t maintain two layers of templates manually.
5. Complexity for simple items: Not every item needs per-zone integrity or contents. The union helps, but
    developers authoring new cards now have to think about item_def, category_data, KindData. We’ll want tooling or
    defaults to keep simple items simple.
6. Natural weapons & innate gear: The proposal punts on how to model “non-item” equipment like claws or racial
    traits. We need a clear boundary so we don’t shoehorn natural weapons into the item card shape unless we’re
    ready for that.
7. Save/load implications: Once items carry mutable state (integrity, enchantments, contents), we need
    serialization downstream. The doc doesn’t address persistence, but ripping this out later would be painful—so
    we should make sure it fits the planned save system.
8. Access ergonomics: the nesting depth (instance.kind_data.item.category_data.weapon.edge_integrity) is getting 
    deep. Might be worth considering whether ItemState should be flatter, or whether accessors/helpers hide the nesting.

### Alternative considerations

- Separate item registry: Instead of uplifting all cards, we could keep cards.Instance lean and maintain a
parallel ItemRegistry keyed by card IDs for stateful items. That trades some consistency for lower per-card cost
and clearer ownership. Worth considering if we anticipate many non-item cards or if card movement doesn’t
actually need the item state most of the time.
- Component-based approach: Rather than a single KindData union, use component structs (Integrity, Enchantment,
Container). Cards would have a bitset indicating components present. More work upfront, but it avoids a
monolithic ItemState and could make it easier to extend (e.g., future “ally” cards).
- Inventory-specific entity: Keep cards as “blueprints/actions” and wrap items in another entity (e.g.,
ItemInstance) that references a card template but lives in inventory/equipment. This is the current pattern
(weapon instances), but it could be modernized without touching the card system.

### Recommendation

The proposed approach is coherent and probably the cleanest way to make items first-class cards, but it’s a heavy
lift and locks us into a specific architecture. Before committing, I’d:

1. Prototype a minimal version (just integrity + weapon category) to confirm the ergonomics and performance.
2. Make a clear decision on ownership/lifetime (e.g., card registry allocates all item state and exposes
    mutators).
3. Ensure CUE generation can populate item_def so we’re not manually wiring templates.
4. Plan for serialization and natural weapon exceptions.

If we accept those trade-offs, the design is solid. If we’re unsure about the long-term ratio of item cards to
other cards or want to reduce coupling, exploring the “parallel item registry keyed by card IDs” might be safer.