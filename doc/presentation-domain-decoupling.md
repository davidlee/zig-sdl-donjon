# Presentation-Domain Decoupling

## Goal

Eliminate all direct dependencies from presentation layer to domain objects. The presentation layer
should only consume DTOs provided by the query layer, never domain types like `Agent`, `Play`,
`Template`, or `World`.

---

## Current Coupling Inventory

### 1. Direct Domain Type Dependencies

| File | Domain Types Used |
|------|-------------------|
| `views/combat/view.zig` | `World`, `Agent`, `Play`, `TurnPhase`, `cards.Template`, `cards.Instance`, `Encounter` |
| `views/card/data.zig` | `cards.Template`, `cards.Instance` |
| `views/card/model.zig` | `cards.Template`, `cards.Instance` |
| `views/combat/play.zig` | `combat.Play`, `cards.Template` |
| `views/combat/status_bar.zig` | `combat.Agent` |
| `views/combat/avatar.zig` | `combat.Agent` |
| `views/combat/button.zig` | `combat.TurnPhase` |

### 2. World Access Patterns (combat/view.zig)

```zig
world.player                    // → Agent (stamina, focus, combat_state, id, director)
world.player.id                 // → entity.ID
world.player.combat_state       // → hand, in_play card lists
world.player.always_available   // → technique card list
world.encounter                 // → Encounter
world.encounter.enemies         // → []*Agent
world.card_registry.getConst()  // → *const Instance
world.turnPhase()               // → TurnPhase
```

### 3. Domain Objects Passed to Sub-Views

| Sub-View | Receives | Properties Accessed |
|----------|----------|---------------------|
| `StatusBarView.init()` | `*combat.Agent` | `.stamina.{current,available}`, `.focus.{current,available}`, `.time_available` |
| `Opposition.init()` | `[]*combat.Agent` | `.id`, (for sprite positioning) |
| `CardViewData.fromInstance()` | `*const cards.Instance` | `.id`, `.template` |
| `buildPlayViewData()` | `*const Play`, `*const Agent` | `.action`, `.modifiers()`, `.effectiveStakes()`, `.id`, `.director` |

### 4. Template Properties Accessed

```zig
template.kind                   // .modifier check for drag/drop logic
template.tags.offensive         // play rendering (offensive indicator)
template.requiresSingleTarget() // targeting UI decisions
template.name                   // card rendering
template.description            // card rendering
template.rarity                 // card rendering
template.cost                   // card rendering
template.getTechnique()         // card rendering (technique details)
```

### 5. Domain Methods Called from Presentation

```zig
play.wouldConflict(template, &card_registry)  // handleDragging - modifier conflict check
play.effectiveStakes()                        // buildPlayViewData - stakes display
play.modifiers()                              // buildPlayViewData - modifier stack
enc.stateForConst(player.id)                  // accessing turn state
enc_state.current.slots()                     // iterating plays
```

---

## Proposed DTO Structure

### Phase 1: Expand CombatSnapshot

Extend `src/domain/query/combat_snapshot.zig` to include:

```zig
pub const CombatSnapshot = struct {
    // Existing
    card_statuses: std.AutoHashMap(entity.ID, CardStatus),
    play_statuses: std.ArrayList(PlayStatus),
    modifier_attachability: std.AutoHashMap(ModifierPlayKey, void),

    // New: Player resources
    player: PlayerStatus,

    // New: Enemy list for opposition rendering
    enemies: std.ArrayList(EnemyStatus),

    // New: Pre-computed conflict checks
    modifier_conflicts: std.AutoHashMap(ModifierPlayKey, void),

    // New: Turn phase
    turn_phase: TurnPhase,
};

pub const PlayerStatus = struct {
    id: entity.ID,
    stamina_current: f32,
    stamina_available: f32,
    focus_current: f32,
    focus_available: f32,
    time_available: f32,
};

pub const EnemyStatus = struct {
    id: entity.ID,
    index: usize,
    // Add other display-relevant fields as needed
};
```

### Phase 2: Card DTO

Replace `*const cards.Template` with a presentation-friendly DTO:

```zig
// src/domain/query/card_dto.zig (or in combat_snapshot.zig)

pub const CardDTO = struct {
    id: entity.ID,
    template_id: cards.ID,  // For asset lookup
    name: []const u8,
    description: []const u8,
    kind: CardKind,
    rarity: Rarity,
    cost: Cost,
    tags: TagSet,
    requires_single_target: bool,
    // Technique info if applicable
    technique: ?TechniqueDTO,
};

pub const TechniqueDTO = struct {
    duration: u8,
    channels: u8,
    height: ?Height,
    // Other technique display info
};
```

### Phase 3: Expanded PlayStatus

```zig
pub const PlayStatus = struct {
    play_index: usize,
    owner_id: entity.ID,
    owner_is_player: bool,
    target_id: ?entity.ID,
    stakes: u8,
    action: CardDTO,
    modifiers: []const CardDTO,  // Or bounded array
    is_offensive: bool,
};
```

### Phase 4: Conflict Pre-computation

Add to snapshot building:

```zig
/// Check if adding modifier to play would cause height conflict.
pub fn wouldModifierConflict(self: *const CombatSnapshot, modifier_id: entity.ID, play_index: usize) bool {
    return self.modifier_conflicts.contains(.{ .modifier_id = modifier_id, .play_index = play_index });
}
```

---

## Implementation Roadmap

### Stage 1: Player & Enemy Status (Low Risk)
- [ ] Add `PlayerStatus` to `CombatSnapshot`
- [ ] Add `EnemyStatus` list to `CombatSnapshot`
- [ ] Update `StatusBarView` to consume `PlayerStatus` instead of `*Agent`
- [ ] Update `Opposition` to consume `[]EnemyStatus` instead of `[]*Agent`
- [ ] Remove `combat.Agent` imports from `status_bar.zig`, `avatar.zig`

### Stage 2: Turn Phase & Conflict Checks (Low Risk)
- [ ] Add `turn_phase` to `CombatSnapshot`
- [ ] Pre-compute `wouldConflict` results in snapshot
- [ ] Update `handleDragging` to use `snapshot.wouldModifierConflict()`
- [ ] Update `View` to get phase from snapshot instead of world
- [ ] Remove last domain method calls from `view.zig`

### Stage 3: Card DTO (Medium Risk - Larger Scope)
- [ ] Define `CardDTO` structure
- [ ] Add card DTO cache/map to `CombatSnapshot`
- [ ] Update `CardViewData` to hold `CardDTO` instead of `*const Template`
- [ ] Update card renderer to consume `CardDTO`
- [ ] Update `views/card/data.zig` and `views/card/model.zig`
- [ ] Remove `cards.Template`, `cards.Instance` imports from presentation

### Stage 4: Play DTO Expansion (Medium Risk)
- [ ] Expand `PlayStatus` to include full play data
- [ ] Update `PlayViewData` to be fully DTO-based
- [ ] Remove `domain_combat.Play` from presentation
- [ ] Update `views/combat/play.zig`

### Stage 5: Final Cleanup
- [ ] Remove all `@import("...domain/...")` from presentation (except query layer)
- [ ] Remove `World` type from presentation layer
- [ ] Coordinator becomes the only presentation component that touches domain
- [ ] Document the clean architecture boundary

---

## Architecture After Completion

```
┌─────────────────────────────────────────────────────────────┐
│                     Presentation Layer                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ Combat View │  │ Card Views  │  │ Status/Avatar Views │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                     │             │
│         └────────────────┼─────────────────────┘             │
│                          ▼                                   │
│              ┌───────────────────────┐                       │
│              │    CombatSnapshot     │ (DTOs only)           │
│              │  - PlayerStatus       │                       │
│              │  - EnemyStatus[]      │                       │
│              │  - CardDTO cache      │                       │
│              │  - PlayStatus[]       │                       │
│              │  - Attachability map  │                       │
│              │  - Conflict map       │                       │
│              └───────────┬───────────┘                       │
└──────────────────────────┼───────────────────────────────────┘
                           │
┌──────────────────────────┼───────────────────────────────────┐
│                          ▼                                   │
│              ┌───────────────────────┐                       │
│              │   Query Layer         │                       │
│              │  buildSnapshot()      │                       │
│              └───────────┬───────────┘                       │
│                          │                                   │
│         ┌────────────────┼────────────────┐                  │
│         ▼                ▼                ▼                  │
│   ┌──────────┐    ┌───────────┐    ┌───────────────┐        │
│   │  World   │    │  Cards    │    │    Combat     │        │
│   │  Agent   │    │  Template │    │    Play       │        │
│   │ Encounter│    │  Instance │    │   Encounter   │        │
│   └──────────┘    └───────────┘    └───────────────┘        │
│                      Domain Layer                            │
└──────────────────────────────────────────────────────────────┘
```

---

## Notes

- The query layer is the **only** bridge between presentation and domain
- DTOs are immutable snapshots - presentation cannot mutate domain state
- Commands flow through the application layer (see command-query-decoupling.md)
- This completes the CQRS-style separation for the combat UI

## Related

- [Command-Query Decoupling](command-query-decoupling.md) - Command path refactor plan
