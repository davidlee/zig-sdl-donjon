# Verbs vs Nouns: Actions and Items as Distinct Types

## Context

The original inventory design explored "everything is a card" - unifying items into
the card system by extending `cards.Instance` with item state. See
`doc/issues/item_data_modelling.md`.

On reflection, this conflates two fundamentally different concepts:
- **Verbs** (actions): rules, predicates, triggers, effects - "when X, do Y"
- **Nouns** (items): physical things with state - "steel sword, 80% integrity"

## The Problem with "Everything is a Card"

Cards speak the grammar of actions: triggers fire, predicates gate, effects execute.
This is verb language.

Items have physical properties: mass, dimensions, integrity, material. They don't
"trigger" or "execute" - they *exist* and *have state*.

Trying to embed nouns inside verbs creates awkwardness:
- What does it mean for a sword to have a `Trigger`?
- Why would a potion have `Predicate` guards?
- `KindData.item` on `cards.Instance` is bolting noun-state onto a verb-structure

## The Cleaner Model

**Actions (verbs)** remain cards with rules/predicates/effects:
```zig
// Slash, Parry, Drink Potion, Cast Fireball
pub const Action = struct {
    id: ID,
    template: *const ActionTemplate,
    // runtime state: cooldowns, charges, modifiers
};
```

**Items (nouns)** are their own entity type with physical state:
```zig
// Sword, Chainmail, Health Potion, Backpack
pub const Item = struct {
    id: entity.ID,
    template: *const ItemTemplate,
    integrity: f32,
    quality: Quality,
    enchantments: []Enchantment,
    contents: []entity.ID,  // for containers
    // physical state, not behavioral state
};
```

**Items can reference actions** they enable:
```zig
pub const ItemTemplate = struct {
    // Physical definition
    physical: PhysicalProperties,
    category: ItemCategory,

    // Actions this item grants when equipped/held
    granted_actions: []const *ActionTemplate,

    // For weapons: combat profile
    weapon_profile: ?*const weapon.Template,
    // For armour: protection profile
    armour_profile: ?*const armour.Template,
};
```

## The Magic Sword Example

A magic talking sword that insults opponents when they Advance:

**Item (noun):**
```zig
Item {
    template: &magic_sword_template,
    integrity: 0.95,
    // physical properties, enchantment state
}
```

**ItemTemplate references an Action:**
```zig
magic_sword_template = ItemTemplate {
    granted_actions: &.{ &insult_on_advance },
    weapon_profile: &longsword_profile,
    // ...
};
```

**Action (verb) - the behavior:**
```zig
insult_on_advance = ActionTemplate {
    rules: &.{
        Rule {
            trigger: .{ .on_event = .opponent_advance },
            predicate: .{ .item_equipped = "magic_sword" },
            effects: &.{ .{ .apply_condition = .demoralized } },
        },
    },
};
```

The sword (noun) grants access to the insult action (verb) when equipped. The action
uses the card grammar. The item carries physical state. Clean separation.

## When You Gain Access to Item-Granted Actions

- **Equipped weapon**: its granted actions enter your available pool
- **Worn armour with abilities**: same
- **Item in hand but not "equipped"**: depends on action's `PlayableFrom`
- **Item in backpack**: no access to its actions (unless action specifically allows)

This maps naturally to existing `PlayableFrom` semantics.

## Implications

### cards.zig Scope

`cards.zig` becomes specifically about *actions* - the verb grammar. It doesn't need
to know about items. Rename to `actions.zig`? Or keep `cards` as the player-facing
term while internally it means "action cards"?

### Item System

Items need their own module (`items.zig`?) with:
- `Item` struct (runtime instance)
- `ItemTemplate` (static definition)
- `ItemCategory` (weapon, armour, consumable, container, misc)
- Integration with existing weapon/armour templates

### Relationship to card_list.zig

Current `card_list.zig` defines action templates (techniques, manoeuvres). Item
templates would live elsewhere (or item definitions in CUE generate to a separate
file).

### UI Presentation

Both actions and items can be "cards" in the UI sense - rectangular things with
art, text, drag-droppable. The visual presentation can be unified even if the
underlying types are distinct.

See `doc/issues/unified_entity_wrapper.md` for this question.

## Open Questions

1. Where do "passive" cards fit? Are they verbs (continuous effects) or something
   else?

2. What about consumables? "Drink Potion" is a verb, but the potion itself is a
   noun. Is the potion an Item that grants a "Drink" action, which consumes the
   item?

3. Mobs/Agents - are they nouns too? They have state (HP, conditions), but they
   also have decks of actions. Are they a third category, or a special case of
   Item/Noun?

## Recommendation

Adopt the verbs/nouns separation. Actions (cards) and Items are distinct types.
Items can reference actions they grant. This is cleaner than embedding item state
into action instances.

The refactor touches:
- `cards.zig` (scope clarification)
- New `items.zig` or similar
- Anywhere that assumed "card" meant "any game entity"

But it avoids the awkward `KindData` union and keeps each type focused on its
actual semantics.
