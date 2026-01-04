# Card Storage Architecture Design

## Problem Statement

The current card storage model (`Agent.cards: Strat` with `Deck` or `TechniquePool`) doesn't support Model B requirements:
- Techniques always available (not dealt)
- Modifier cards dealt from deck
- Cards flowing between contexts (equipped → thrown → environment → loot)
- Multiple card container types with different behaviors

## Design Goals

1. **Unified card ownership** - All Instances in one registry, containers hold IDs
2. **Lifespan separation** - Agent-persistent vs encounter-transient state
3. **Playability model** - Express where cards can be played from, when, how
4. **Interoperability** - Cards flow between containers cleanly
5. **Mob support** - Same structures, different AI drivers

## Architecture Overview

```
World
├── card_registry: SlotMap(*Instance)    // All card instances
├── encounter: ?Encounter
│   └── environment: ArrayList(entity.ID) // Rubble, thrown items
└── agents: []*Agent
    ├── techniques_known: ArrayList(entity.ID)  // Always available
    ├── spells_known: ArrayList(entity.ID)      // Always available (if mana)
    ├── deck_cards: ArrayList(entity.ID)        // Shuffled into draw at combat start
    ├── equipment: EquipmentSlots               // Body-aware
    ├── inventory: ArrayList(entity.ID)
    └── combat: ?CombatState                    // Per-encounter, transient
        ├── draw: ArrayList(entity.ID)
        ├── hand: ArrayList(entity.ID)
        ├── discard: ArrayList(entity.ID)
        ├── in_play: ArrayList(entity.ID)
        └── exhaust: ArrayList(entity.ID)
```

**Instance ownership:** Cards are instanced once (at acquisition) and carry upgrades/variations (Balatro-style). When you own a card, you own an Instance, not a Template reference.

### Key Changes

1. **World.card_registry** replaces `Deck.entities`
2. **Agent** gains explicit containers for knowledge, equipment, inventory
3. **Agent.combat** is optional, created per-encounter
4. **Encounter.environment** holds environmental/thrown cards

## Card Registry

```zig
// world.zig
pub const World = struct {
    // ... existing fields ...
    card_registry: CardRegistry,
};

pub const CardRegistry = struct {
    alloc: Allocator,
    entities: SlotMap(*Instance),

    pub fn create(self: *CardRegistry, template: *const Template) !entity.ID {
        const instance = try self.alloc.create(Instance);
        instance.* = .{ .id = undefined, .template = template };
        instance.id = try self.entities.insert(instance);
        return instance.id;
    }

    pub fn get(self: *CardRegistry, id: entity.ID) ?*Instance {
        return self.entities.get(id);
    }

    pub fn destroy(self: *CardRegistry, id: entity.ID) void {
        if (self.entities.remove(id)) |instance| {
            self.alloc.destroy(instance);
        }
    }
};
```

## Agent Card Containers

```zig
// combat.zig
pub const Agent = struct {
    // ... existing fields (id, body, stamina, focus, director) ...

    // Persistent card containers (IDs reference World.card_registry)
    techniques_known: std.ArrayList(entity.ID),  // Always available in combat
    spells_known: std.ArrayList(entity.ID),      // Always available (if mana)
    deck_cards: std.ArrayList(entity.ID),        // Shuffled into draw at combat start
    equipment: EquipmentSlots,
    inventory: std.ArrayList(entity.ID),

    // Per-encounter combat state (null outside combat)
    combat: ?*CombatState,

    // Legacy: keeping for gradual migration
    cards: Strat,  // TODO: remove after migration
};
```

### CombatState (replaces combat zones in Deck)

```zig
pub const CombatState = struct {
    alloc: Allocator,
    draw: std.ArrayList(entity.ID),
    hand: std.ArrayList(entity.ID),
    discard: std.ArrayList(entity.ID),
    in_play: std.ArrayList(entity.ID),
    exhaust: std.ArrayList(entity.ID),

    pub fn init(alloc: Allocator) CombatState { ... }
    pub fn deinit(self: *CombatState) void { ... }

    // Zone transfer helpers
    pub fn moveCard(self: *CombatState, id: entity.ID, from: CombatZone, to: CombatZone) !void { ... }
    pub fn shuffle(self: *CombatState, rng: *std.Random) void { ... }
    pub fn drawToHand(self: *CombatState, count: usize) !void { ... }
};

pub const CombatZone = enum { draw, hand, discard, in_play, exhaust };
```

### EquipmentSlots (body-aware)

```zig
pub const EquipmentSlots = struct {
    // Slot -> card ID (null = empty)
    // Slots derived from Agent.body
    main_hand: ?entity.ID = null,
    off_hand: ?entity.ID = null,
    head: ?entity.ID = null,
    torso: ?entity.ID = null,  // Can layer: gambeson + chain + plate
    // ... etc based on body model

    pub fn canEquip(self: *EquipmentSlots, body: *const Body, item: *const Instance) bool { ... }
    pub fn equip(self: *EquipmentSlots, slot: Slot, item_id: entity.ID) !void { ... }
    pub fn unequip(self: *EquipmentSlots, slot: Slot) ?entity.ID { ... }
};
```

## Encounter Environment

```zig
// combat.zig
pub const Encounter = struct {
    // ... existing fields (enemies, engagements, agent_state) ...

    // Environmental cards (rubble, thrown items, lootable)
    environment: std.ArrayList(entity.ID),

    // Card ownership tracking for thrown items
    thrown_by: std.AutoHashMap(entity.ID, entity.ID), // card -> original owner
};
```

## Playability Model

### Template Extensions

```zig
// cards.zig
pub const PlayableFrom = packed struct {
    hand: bool = false,              // Dealt cards in hand
    techniques_known: bool = false,  // Always-available techniques
    spells_known: bool = false,      // Always-available spells
    equipped: bool = false,          // Draw/throw/swap equipped items
    inventory: bool = false,         // Use consumables
    environment: bool = false,       // Pick up items
};

pub const Template = struct {
    // ... existing fields ...

    // Playability
    playable_from: PlayableFrom = .{ .hand = true },  // Default: dealt only
    combat_playable: bool = true,  // false = out-of-combat only (don plate)

    // Existing phase flags in TagSet:
    // tags.phase_selection, tags.phase_commit
};
```

### Playability Examples

```zig
// Thrust technique - always available
const thrust = Template{
    .kind = .action,
    .playable_from = .{ .techniques_known = true },
    .combat_playable = true,
    .tags = .{ .phase_selection = true, .offensive = true },
    // ...
};

// Feint modifier - dealt from deck
const feint = Template{
    .kind = .modifier,
    .playable_from = .{ .hand = true, .techniques_known = true, },
    .combat_playable = true,
    .tags = .{ .phase_commit = true },
    // ...
};

// Draw Sword - from equipped
const draw_weapon = Template{
    .kind = .action,
    .playable_from = .{ .equipped = true },
    .combat_playable = true,
    .cost = .{ .stamina = 0.5, .time = 0.2 },
    // ...
};

// Don Plate - out of combat only
const don_armour = Template{
    .kind = .action,
    .playable_from = .{ .inventory = true },
    .combat_playable = false,  // Can't do this mid-fight
    // ...
};

// Pick Up Shield - from environment
const pick_up_armament = Template{
    .kind = .action,
    .playable_from = .{ .environment = true },
    .combat_playable = true,
    .cost = .{ .stamina = 0.3, .time = 0.3 },
    // ...
};
```

### Rider Mechanism

Cards can "mobilize" other cards via the existing Effect system:

```zig
// Throw Axe technique
const throw_weapon = Template{
    .kind = .action,
    .playable_from = .{ .techniques_known = true },
    .rules = &.{
        .{
            .trigger = .on_play,
            .valid = .{ .has_equipped = .{ .throwable = true } },
            .expressions = &.{
                // Move equipped throwable to environment (toward target)
                .{
                    .effect = .{ .throw_equipped = .{} },  // New effect type
                    .target = .{ .equipped_item = .{ .throwable = true } },
                },
                // Apply damage based on thrown item
                .{
                    .effect = .{ .thrown_damage = {} },
                    .target = .all_enemies,
                },
            },
        },
    },
};
```

## Time Cost Model

Current `cost.time` handles within-turn timing. For actions that can't happen mid-combat:

| Action | `combat_playable` | `cost.time` | Notes |
|--------|-------------------|-------------|-------|
| Thrust | true | 0.3 | Normal attack |
| Draw Sword | true | 0.2 | Quick action |
| Pick Up Shield | true | 0.3 | Costs time in turn |
| Drink Potion | true | 0.1 | Quick |
| Don Plate | **false** | N/A | Out-of-combat only |
| Full Equipment Change | **false** | N/A | Camp/rest action |

`combat_playable = false` cards are filtered out of combat UI entirely.

## Weapon Speed and Weight

Equipped weapon properties modify technique costs. From `weapon.zig`:

```zig
pub const Offensive = struct {
    speed: f32,      // Time multiplier (lower = faster)
    // ...
};

pub const Template = struct {
    weight: f32,     // Stamina multiplier
    swing: ?Offensive,
    thrust: ?Offensive,
    // ...
};
```

**Application at resolution (tick.zig):**

```zig
// Base technique cost
const base_time = template.cost.time;
const base_stamina = template.cost.stamina;

// Get weapon modifiers based on attack mode
const weapon_speed = getEquippedWeaponSpeed(agent, technique.attack_mode); // e.g., 0.8 for smallsword, 1.4 for greataxe
const weapon_weight = getEquippedWeaponWeight(agent);

// Apply modifiers
const time_cost = base_time * weapon_speed * play.computedCostMult(lookup);
const stamina_cost = base_stamina * weapon_weight;
```

**Attack mode mapping:**
- `AttackMode.thrust` → `weapon.thrust.speed`
- `AttackMode.swing` → `weapon.swing.speed`
- `AttackMode.none` → 1.0 (defensive techniques, no weapon influence)

This means a smallsword thrust is faster than a greataxe swing, even using the same "Thrust" technique template.

## Feint as Commit-Phase Modifier

Feint is a modifier card playable during commit phase. It converts an already-committed offensive technique into a cheaper feint that:
- Consumes opponent's defensive resources (they parry/block a fake attack)
- Sets up advantage for a follow-up attack

```zig
const feint = Template{
    .kind = .modifier,
    .playable_from = .{ .hand = true, .techniques_known = true },
    .tags = .{ .phase_commit = true },  // Played during commit, not selection
    .cost = .{ .stamina = 0.2, .focus = 1.0 },
    .rules = &.{
        .{
            .trigger = .on_play,
            .target = .{ .my_play = .{ .has_tag = .{ .offensive = true } } },
            .expressions = &.{
                .{
                    .effect = .{ .modify_play = .{
                        .damage_mult = 0,       // No damage
                        .cost_mult = 0.33,      // Much cheaper
                        .replace_advantage = .{ // Favorable outcomes
                            .on_parried = .{ .control = 0.25 },
                            .on_blocked = .{ .control = 0.20 },
                            // ...
                        },
                    }},
                },
            },
        },
    },
};
```

**Flow:**
1. Selection phase: Player commits Thrust
2. Commit phase: Player plays Feint modifier (costs 1F)
3. Feint attaches to Thrust, modifying its properties
4. Resolution: Thrust resolves as a zero-damage probe with feint advantage profile

## Function Signature Approach

### Pass World for Game Logic

```zig
// Game logic functions take World
pub fn playCard(world: *World, agent: *Agent, card_id: entity.ID) !void {
    const instance = world.card_registry.get(card_id) orelse return error.CardNotFound;
    // Can access events, encounter, other agents...
    try world.events.emit(.{ .card_played = .{ ... } });
}

pub fn throwItem(world: *World, agent: *Agent, item_id: entity.ID) !void {
    // Remove from agent equipment
    _ = agent.equipment.unequip(slot);
    // Add to encounter environment
    const enc = &(world.encounter orelse return error.NotInCombat);
    try enc.environment.append(item_id);
    try enc.thrown_by.put(item_id, agent.id);
}
```

### Pure Lookup Stays Narrow

```zig
// Pure lookups only need registry
pub fn getInstance(registry: *const CardRegistry, id: entity.ID) ?*Instance {
    return registry.entities.get(id);
}

pub fn getTemplate(registry: *const CardRegistry, id: entity.ID) ?*const Template {
    const instance = registry.entities.get(id) orelse return null;
    return instance.template;
}
```

## Lifecycle Management

### Combat Start

```zig
pub fn initCombatState(world: *World, agent: *Agent) !void {
    // Create combat state
    agent.combat = try world.alloc.create(CombatState);
    agent.combat.?.* = CombatState.init(world.alloc);

    // Populate draw pile from agent's deck_cards
    for (agent.deck_cards.items) |card_id| {
        try agent.combat.?.draw.append(card_id);
    }

    // Shuffle
    agent.combat.?.shuffle(world.rng);
}
```

### Combat End

```zig
pub fn cleanupCombatState(world: *World, agent: *Agent, won: bool) !void {
    const combat = agent.combat orelse return;

    // Handle thrown items
    if (won) {
        // Recover thrown items from environment
        const enc = &(world.encounter orelse return);
        var to_recover = std.ArrayList(entity.ID).init(world.alloc);
        defer to_recover.deinit();

        for (enc.environment.items) |item_id| {
            if (enc.thrown_by.get(item_id) == agent.id) {
                try to_recover.append(item_id);
            }
        }
        for (to_recover.items) |item_id| {
            try agent.inventory.append(item_id);
            // Remove from environment
            // ...
        }
    }
    // Else: thrown items stay in environment (lost)

    // All deck_cards return to agent.deck_cards (already there by reference)
    // Exhausted cards un-exhaust (combat.exhaust is discarded)
    // Combat state is purely transient - deck_cards never left the agent

    // Free combat state
    combat.deinit();
    world.alloc.destroy(combat);
    agent.combat = null;
}
```

**Key insight:** `deck_cards` IDs are *copied* into `combat.draw` at start. The agent always owns them. Combat zones are transient views. When combat ends, the transient state is discarded and `deck_cards` remains intact.

## Migration Path

### Phase 1: Add CardRegistry to World
1. Add `World.card_registry: CardRegistry`
2. Keep `Deck.entities` temporarily
3. New card creation uses registry

### Phase 2: Add Agent Containers
1. Add `Agent.techniques_known`, `spells_known`, `equipment`, `inventory`
2. Add `Agent.combat: ?*CombatState`
3. Populate from existing Deck zones at migration points

### Phase 3: Add Encounter.environment
1. Add environment container to Encounter
2. Add thrown_by tracking

### Phase 4: Update Card Operations
1. Migrate card lookups from `deck.entities` to `world.card_registry`
2. Update function signatures to take `*World` where needed
3. Update zone transfers to use new containers

### Phase 5: Add Playability Fields
1. Add `PlayableFrom` to Template
2. Add `combat_playable` to Template
3. Update validation to check playability

### Phase 6: Remove Legacy
1. Remove `Deck.entities` (use registry)
2. Remove combat zones from Deck (use CombatState)
3. Simplify or remove `Strat` union

## Resolved Design Decisions

1. **Deck storage**: `Agent.deck_cards: ArrayList(entity.ID)` - agent owns instanced cards. IDs copied to `combat.draw` at combat start.

2. **Instance ownership**: Cards instanced once at acquisition. Instances carry upgrades/variations (Balatro-style). Combat zones are transient views; `deck_cards` remains intact.

3. **Combat cleanup**: All cards return to `deck_cards` after combat. Exhausted cards un-exhaust. Combat state is purely transient.

4. **Weapon influence**: `weapon.Offensive.speed` multiplies technique time cost. `weapon.Template.weight` multiplies stamina cost. Applied at resolution based on `technique.attack_mode`.

## Open Questions

1. **Mob decks**: Should mobs use same CombatState, or keep simplified AI driver? TechniquePool could become an AI behavior selecting from `techniques_known`. Design should support either.

2. **Spell mana**: How does mana interact with `spells_known`? Separate resource like Focus? (Not yet designed)

3. **Equipment layering**: Armor can layer (gambeson + chain + plate). Uses existing armor layer system from `body.zig`.

## Files to Modify

- `src/domain/world.zig` - Add CardRegistry
- `src/domain/combat.zig` - Agent containers, CombatState, EquipmentSlots, Encounter.environment
- `src/domain/cards.zig` - PlayableFrom, combat_playable, Kind.modifier
- `src/domain/deck.zig` - Migrate to use registry, eventually simplify
- `src/domain/apply.zig` - Update to use new containers, pass World
- `src/domain/tick.zig` - Update card lookups