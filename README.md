# DECK OF DWARF: a card game about killing Gobbo scum

This is an experimental deck-building dungeon battler written in Zig (0.15.2) with SDL3 bindings.

The game is about simultaneous disclosure, information asymmetry, and ludicrous simulated detail.

There are no health bars; only bone, tissue penetration, and vital organ trauma.

Happily, Dwarves regenerate in the presence of alcohol (although the process isn't kind to the alcohol).

Success in combat is about anticipating your opponent, carefully conserving stamina, probing and exploiting to gain an advantage, and pressing it at the right time (without over-extending) to land a decisive hit.

Everything is a card, drawn at random from your deck; but your inventory is modelled in autistic detail. Gambeson can be layered under chain; munitions plate is nearly impervious, but leaves your joints vulnerable to a rondel dagger.

Think of it as an attempt to answer the question nobody ever asked: what if Dwarf Fortress fell into a teleporter with Slay the Spire and Balatro?

Current State: pre-alpha. Crappy graphics; incomplete core gameplay loop; more ideas modelled than wired up; plenty of core data (e.g. a definitive list of cards) still missing.

## Architecture

See `doc/presentation_architecture.md` for detailed design. Key principles:

### Layer Separation

```
infra/          Shared contracts (no SDL)
domain/         Pure game logic (imports infra, never SDL)
presentation/   SDL rendering & input (imports infra + SDL)
main.zig        Entry point (imports both)
```

**Import enforcement:** SDL is only imported in `presentation/mod.zig`. Domain code cannot accidentally depend on SDL.

### Domain → Presentation Data Flow

1. **World** owns pure game state (FSM, entities, EventSystem)
2. **Coordinator** reads World, maps FSM state to active View
3. **Views** are read-only lenses - query World on demand, return `Renderable` primitives
4. **EffectMapper** transforms domain Events into presentation Effects
5. **UX** renders Renderables. Knows nothing about game logic.

### Presentation → Domain Data Flow

1. SDL events pass through **Coordinator.handleInput()**
2. **Views** translate input + ViewState into `?Command`
3. Non-null Commands execute via **World.commandHandler**
4. **Commands** are the shared contract (defined in `src/commands.zig`, re-exported via `infra`)

### State Ownership

| State | Owner | Description |
|-------|-------|-------------|
| World | domain | Game state, FSM, entities, events |
| ViewState | Coordinator | Transient presentation state (mouse, hover, drag, scroll) |
| Renderables | Views | Fresh each frame, not cached |
| Tweens/Effects | EffectSystem | In-flight animations |

**Architectural invariant:** Views receive ViewState as immutable input and return updates from `handleInput()`. They never mutate World. Views themselves are stateless (created and disposed each frame).

### Practical Guidelines

- **Adding game logic?** Put it in `domain/`. Never import SDL.
- **Adding UI/rendering?** Put it in `presentation/`. Import World read-only.
- **Adding a new command?** Add to `commands.zig`, handle in `apply.zig`.
- **Adding visual feedback for an event?** Add Effect variant, map in EffectMapper.
- **Need to track UI state (hover, selection)?** Add to ViewState, not World.

