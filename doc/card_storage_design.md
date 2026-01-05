# Card Storage Architecture Design

## Status

**Phases 1-7 complete.** Core architecture implemented. See handover.md for session-by-session details.

## Design Goals

1. **Unified card ownership** - All Instances in one registry, containers hold IDs
2. **Lifespan separation** - Agent-persistent vs encounter-transient state
3. **Playability model** - Express where cards can be played from, when, how
4. **Interoperability** - Cards flow between containers cleanly
5. **Mob support** - Same structures, different draw behaviors

## Architecture Overview

```
World
├── card_registry: CardRegistry          // All card instances (SlotMap)
├── encounter: ?Encounter
│   ├── environment: ArrayList(entity.ID)  // Rubble, thrown items
│   └── thrown_by: AutoHashMap(ID, ID)     // card -> original owner
└── agents: []*Agent
    ├── draw_style: DrawStyle             // shuffled_deck, always_available, scripted
    ├── techniques_known: ArrayList(entity.ID)  // Always available (stub)
    ├── spells_known: ArrayList(entity.ID)      // Always available (stub)
    ├── deck_cards: ArrayList(entity.ID)        // Shuffled into draw at combat start
    ├── inventory: ArrayList(entity.ID)
    └── combat_state: ?*CombatState             // Per-encounter, transient
        ├── draw: ArrayList(entity.ID)
        ├── hand: ArrayList(entity.ID)
        ├── discard: ArrayList(entity.ID)
        ├── in_play: ArrayList(entity.ID)
        └── exhaust: ArrayList(entity.ID)
```

**Instance ownership:** Cards are instanced once (at acquisition) and carry upgrades/variations (Balatro-style). When you own a card, you own an Instance, not a Template reference.

### What's Implemented

1. **World.card_registry** - central card instance storage
2. **Agent.draw_style** - enum controlling card availability behavior
3. **Agent.combat_state** - per-encounter transient zones
4. **Encounter.environment** - environmental/thrown cards
5. **PlayableFrom** - template metadata for card sources
6. **CombatState zone operations** - moveCard, shuffleDraw, etc.

### What's Stubbed

1. **DrawStyle.always_available** - falls back to shuffled_deck behavior (design complete, implementation pending)
2. **DrawStyle.scripted** - falls back to shuffled_deck behavior
3. **Cooldown tracking** - designed in "CardSource Tracking and Cooldowns" section, not yet implemented
4. **CardSource tracking** - designed, not yet implemented
5. **EquipmentSlots** - weapons/armor use existing Agent.weapons/armour systems

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
pub const DrawStyle = enum {
    shuffled_deck,    // cards cycle through draw/hand/discard
    always_available, // cards in techniques_known, cooldown-based (stub)
    scripted,         // behaviour tree selects from available cards (stub)
};

pub const Agent = struct {
    // ... existing fields (id, body, stamina, focus, director) ...

    draw_style: DrawStyle = .shuffled_deck,

    // Persistent card containers (IDs reference World.card_registry)
    techniques_known: std.ArrayList(entity.ID),  // Always available in combat (stub)
    spells_known: std.ArrayList(entity.ID),      // Always available (stub)
    deck_cards: std.ArrayList(entity.ID),        // Shuffled into draw at combat start
    inventory: std.ArrayList(entity.ID),

    // Per-encounter combat state (null outside combat)
    combat_state: ?*CombatState,
};
```

**Note:** Weapons and armor use existing `Agent.weapons` (Armament) and `Agent.armour` (armour.Stack) systems, not card-based equipment slots.

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
// In Agent (combat.zig)
pub fn initCombatState(self: *Agent) !void {
    if (self.combat_state != null) return; // already initialized

    const cs = try self.alloc.create(CombatState);
    cs.* = try CombatState.init(self.alloc);

    // Populate draw pile from agent's deck_cards
    try cs.populateFromDeckCards(self.deck_cards.items);

    self.combat_state = cs;
}
```

### Combat End (TODO - Phase 8)

```zig
pub fn cleanupCombatState(world: *World, agent: *Agent, won: bool) !void {
    const cs = agent.combat_state orelse return;

    // Handle thrown items
    if (won) {
        // Recover thrown items from environment
        const enc = &(world.encounter orelse return);
        for (enc.environment.items) |item_id| {
            if (enc.thrown_by.get(item_id) == agent.id) {
                try agent.inventory.append(world.alloc, item_id);
            }
        }
        // Remove recovered items from environment...
    }
    // Else: thrown items stay in environment (lost)

    // All deck_cards return to agent.deck_cards (already there by reference)
    // Exhausted cards un-exhaust (combat_state.exhaust is discarded)
    // Combat state is purely transient - deck_cards never left the agent

    // Free combat state
    cs.deinit();
    agent.alloc.destroy(cs);
    agent.combat_state = null;
}
```

**Key insight:** `deck_cards` IDs are *copied* into `combat_state.draw` at start. The agent always owns them. Combat zones are transient views. When combat ends, the transient state is discarded and `deck_cards` remains intact.

## CardSource Tracking and Cooldowns

Cards in `in_play` can originate from different sources with different post-resolution behaviors. CombatState tracks this transient state.

### Design Decision

**Cooldowns and source tracking live on CombatState**, not Agent containers or Instance fields, because:
1. This state is combat-transient (reset each encounter)
2. Agent containers are static during combat (what you "know" doesn't change)
3. Instance fields persist across combats - wrong lifecycle
4. CombatState already owns transient per-card state (zone membership)

### CardSource Enum

```zig
// combat.zig
pub const CardSource = enum {
    hand,              // From CombatState.hand (deck cards)
    always_available,  // From Agent.always_available (techniques)
    spells_known,      // From Agent.spells_known
    inventory,         // From Agent.inventory (consumables)
    environment,       // From Encounter.environment (picked up)
};
```

### CombatState Additions

```zig
pub const CombatState = struct {
    // ... existing zones (draw, hand, in_play, discard, exhaust) ...

    // Source tracking: where did cards in in_play originate?
    in_play_sources: std.AutoHashMap(entity.ID, CardSource),

    // Cooldowns for pool-based cards (turns until available again)
    cooldowns: std.AutoHashMap(entity.ID, u8),

    /// Add card to in_play from a non-zone source (always_available, inventory, etc.)
    /// For zone sources, use moveCard(.hand, .in_play) instead.
    pub fn addToInPlayFrom(self: *CombatState, id: entity.ID, source: CardSource) !void {
        try self.in_play.append(self.alloc, id);
        try self.in_play_sources.put(self.alloc, id, source);
    }

    /// Check if a pool card is available (not on cooldown, not currently in in_play)
    pub fn isPoolCardAvailable(self: *const CombatState, id: entity.ID) bool {
        if (self.isInZone(id, .in_play)) return false;
        if (self.cooldowns.get(id)) |cd| if (cd > 0) return false;
        return true;
    }

    /// Decrement all cooldowns by 1 (called at turn start)
    pub fn tickCooldowns(self: *CombatState) void {
        var iter = self.cooldowns.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* > 0) entry.value_ptr.* -= 1;
        }
    }
};
```

### Agent Helper

```zig
// combat.zig - Agent
pub fn poolContains(self: *const Agent, id: entity.ID) bool {
    for (self.always_available.items) |i| if (i.eql(id)) return true;
    for (self.spells_known.items) |i| if (i.eql(id)) return true;
    return false;
}
```

### Resolution Behavior by Source

| Source | After Resolution | Cooldown |
|--------|------------------|----------|
| hand | → discard (or exhaust) | No |
| always_available | stays in pool, removed from in_play | Yes (template-defined) |
| spells_known | stays in pool, removed from in_play | Maybe (mana-based?) |
| inventory | consumed (destroy instance) or → inventory | No |
| environment | → agent inventory (picked up) | No |

### Playing a Card (apply.zig)

```zig
pub fn playCardFromSource(
    cs: *CombatState,
    card_id: entity.ID,
    source: CardSource,
) !void {
    switch (source) {
        .hand => try cs.moveCard(card_id, .hand, .in_play),
        else => try cs.addToInPlayFrom(card_id, source),
    }
}
```

### Post-Resolution Cleanup (tick.zig)

```zig
pub fn returnCardAfterResolution(
    cs: *CombatState,
    card_id: entity.ID,
    template: *const Template,
) !void {
    const source = cs.in_play_sources.get(card_id) orelse .hand;

    // Remove from in_play
    try cs.removeFromInPlay(card_id);
    _ = cs.in_play_sources.remove(card_id);

    switch (source) {
        .hand => try cs.discard.append(cs.alloc, card_id),
        .always_available => {
            // Card stays in Agent.always_available (never left)
            // Set cooldown if template specifies one
            if (template.cooldown) |cd| {
                try cs.cooldowns.put(cs.alloc, card_id, cd);
            }
        },
        .spells_known => {}, // stays in pool, mana already spent
        .inventory => {},    // consumable handling TBD
        .environment => {},  // pickup handling TBD
    }
}
```

## Migration Status

### Complete (Phases 1-7)

- **Phase 1:** CardRegistry added to World
- **Phase 2:** Agent containers (techniques_known, spells_known, deck_cards, inventory, combat_state)
- **Phase 3:** Encounter.environment and thrown_by tracking
- **Phase 4:** Card lookups migrated to card_registry, CombatState zone operations
- **Phase 5:** CombatState wired into combat flow (initCombatState, zone transfers)
- **Phase 6:** PlayableFrom metadata added to Template
- **Phase 7:** Legacy removed (Deck, Strat, TechniquePool deleted)

### Remaining

- **Phase 8:** Wire `cleanupCombatState()` when combat termination is implemented
- **Phase 9:** Implement CardSource tracking and cooldowns (see "CardSource Tracking and Cooldowns" section)
- **Scripted AI:** Implement behaviour selection for `scripted` draw style

## Resolved Design Decisions

1. **Deck storage**: `Agent.deck_cards: ArrayList(entity.ID)` - agent owns instanced cards. IDs copied to `combat_state.draw` at combat start.

2. **Instance ownership**: Cards instanced once at acquisition. Instances carry upgrades/variations (Balatro-style). Combat zones are transient views; `deck_cards` remains intact.

3. **Combat cleanup**: All cards return to `deck_cards` after combat. Exhausted cards un-exhaust. Combat state is purely transient.

4. **Weapon influence**: `weapon.Offensive.speed` multiplies technique time cost. `weapon.Template.weight` multiplies stamina cost. Applied at resolution based on `technique.attack_mode`.

5. **Mob card behavior**: All agents use unified `CombatState` + `CardRegistry`. Behavior differences expressed via `DrawStyle` enum, not separate data structures. AI director populates `in_play` appropriately for each style.

6. **Cooldown and source tracking**: Lives on `CombatState`, not Agent containers or Instance fields. Combat-transient state: `in_play_sources` tracks where cards came from, `cooldowns` tracks turns until available. See "CardSource Tracking and Cooldowns" section.

## Open Questions

1. **Spell mana**: How does mana interact with `spells_known`? Separate resource like Focus? (Not yet designed)

2. **Equipment as cards**: Current weapons/armor use dedicated systems. If items become cards, need to track card IDs corresponding to equipped instances.

## Key Files

- `src/domain/world.zig` - CardRegistry, World.init populates deck_cards
- `src/domain/combat.zig` - Agent (with draw_style), CombatState, Encounter
- `src/domain/cards.zig` - PlayableFrom, combat_playable, Template
- `src/domain/apply.zig` - Zone operations, card validation, commit phase
- `src/domain/tick.zig` - Resolution, mob action commit