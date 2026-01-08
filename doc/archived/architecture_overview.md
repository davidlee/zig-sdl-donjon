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

Hey Claude: read `doc/zig.md` for recent API changes.