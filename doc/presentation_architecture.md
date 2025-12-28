# Presentation Architecture

## Problem

World (game state) and UX (SDL rendering) are currently coupled. `UX.render()` takes `*World` directly. This conflates:
- Domain logic (what the game state is)
- View logic (what subset of state a screen cares about)
- Animation state (transient presentation-only state)

## Goals

- World knows nothing about presentation
- UX knows nothing about game logic
- Clean seams for testing, alternative renderers
- Animation state separate from domain state

## Architecture

```
                                    Output Flow
                                    -----------
World (pure domain)
   |
   | (read-only)
   v
Coordinator
   |
   +---> ViewModels (per-screen lenses into World)
   |         |
   |         +---> Renderables
   |                   |
   +---> EffectMapper  |
            |          |
            v          |
        EffectSystem --+---> UX.render()
            |
            +---> Tweens (in-flight animations)


                                    Input Flow
                                    ----------
SDL Event (screen coords)
   |
   v
UX.translateCoords() ---> logical coords
   |
   v
Coordinator.handleInput(event, coords)
   |
   v
activeView.handleInput(event, coords) ---> ?Command
   |
   v
World.commandHandler.execute(command)
```

## Components

### World
Pure game state. Owns:
- FSM (GameState transitions)
- EventSystem (double-buffered domain events)
- Entities, player, encounter, etc.

No presentation concerns.

### Coordinator
Integration point between domain and presentation. Owns:
- `*World` (read)
- ViewModels
- EffectMapper
- EffectSystem

Responsibilities:
- Map `world.fsm.currentState()` to active ViewModel
  - design note: it's quite likely it'll make sense to break world.fsm into multiple FSMs; there's likely:
      - overall menu / pause state
      - modals / player view state
      - town vs dungeon crawl vs in combat 
      - in-combat turn state (draw, select cards, resolve, animate);
      - state for prompting player input / reaction opportunities
- Drive EffectMapper each frame (before event buffer swap)
- Tick EffectSystem
- Provide renderables to UX

### ViewModels
Read-only lenses. Each exposes what its screen needs:

| State(s) | ViewModel | Exposes |
|----------|-----------|---------|
| `menu` | MenuView | menu options |
| `draw_hand`, `player_card_selection`, `tick_resolution`, `player_reaction`, `animating` | CombatView | hand, enemies, engagements, phase |
| `encounter_summary` | SummaryView | loot, rewards, stats |

Future: DungeonView, InventoryView, MetaProgressionView, etc

ViewModels query World on demand (no cached state). Return presentation-friendly types, not domain internals.

### EffectMapper
Transforms domain events to presentation effects.

```zig
fn map(event: Event) ?Effect
```

Consumes `world.events.current_events` each frame before swap. Even if initially 1:1, the seam exists for:
- Filtering (not all events need visuals)
- Batching (coalesce rapid damage ticks)
- Enriching (add screen position, color, etc.)

### EffectSystem
Owns transient presentation state. Receives Effects, spawns Tweens, ticks animations.

```zig
pub const EffectSystem = struct {
    pending: ArrayList(Effect),
    animations: ArrayList(Tween),

    pub fn push(self: *EffectSystem, effect: Effect) void;
    pub fn tick(self: *EffectSystem, dt: f32) void;
    pub fn renderables(self: *EffectSystem) []Renderable;
};
```

Animation types:
- Card slide (deal, play, discard)
- Hit flash / damage number
- Advantage bar change
- Screen shake

### UX
Pure rendering. Receives renderables, draws them. Owns:
- Window, Renderer
- Textures / assets
- Frame timing

```zig
pub fn render(self: *UX, view: Renderables, effects: []Renderable) !void;
pub fn translateCoords(self: *UX, screen: Point) Point;  // screen → logical
```

No World reference. No game logic.

### Commands
Shared contract between Views (producers) and CommandHandler (consumer).

```zig
// commands.zig
pub const Command = union(enum) {
    play_card: struct { card_id: entity.ID },
    end_turn: void,
    select_target: struct { target_id: entity.ID },
    cancel_selection: void,
    // menu
    start_game: void,
    // etc.
};
```

Views return `?Command` from `handleInput()`. Coordinator passes non-null commands to `World.commandHandler.execute()`.

CommandHandler (in apply.zig) switches on Command to dispatch:

```zig
pub fn execute(self: *CommandHandler, cmd: Command) !void {
    switch (cmd) {
        .play_card => |c| try self.playActionCard(c.card_id),
        .end_turn => try self.endTurn(),
        // ...
    }
}
```

## Data Flow (per frame)

1. **Input** (Coordinator.handleInput for each SDL event)
   - UX.translateCoords(screen_pos) → logical coords
   - activeView.handleInput(event, coords) → ?Command
   - if command: World.commandHandler.execute(command)
2. **World.tick()** - domain updates, pushes Events
3. **Coordinator.update(dt)**
   - EffectMapper reads `world.events.current_events`, pushes Effects
   - `world.events.swap_buffers()`
   - EffectSystem.tick(dt)
4. **Coordinator.render()**
   - Select ViewModel from FSM state
   - Gather view renderables
   - Gather effect renderables
   - `ux.render(view_renderables, effect_renderables)`

## Main Loop

```zig
// main.zig
while (running) {
    while (pollEvent()) |event| {
        coordinator.handleInput(event);
    }
    world.tick();
    coordinator.update(dt);
    coordinator.render();
}
```

Coordinator owns event dispatch; main.zig just drives the loop.

## File Structure

```
src/
  main.zig                -- entry point, imports domain + presentation

  -- shared infrastructure (no SDL) --
  infra.zig               -- re-exports util, config, commands, zigfsm
  util.zig
  config.zig
  commands.zig            -- Command union (shared contract)

  -- domain (imports infra, never sdl) --
  domain/
    mod.zig               -- re-exports for convenience
    world.zig
    events.zig
    apply.zig             -- CommandHandler.execute() consumes Commands
    tick.zig
    resolution.zig
    random.zig
    entity.zig
    slot_map.zig
    cards.zig
    card_list.zig
    deck.zig
    combat.zig
    body.zig
    damage.zig
    armour.zig
    weapon.zig
    weapon_list.zig
    stats.zig
    inventory.zig
    player.zig
    rules.zig

  -- presentation (imports infra + sdl3 directly) --
  presentation/
    mod.zig               -- re-exports, imports sdl3 here
    coordinator.zig       -- Coordinator
    graphics.zig          -- UX (renderer only)
    effects.zig           -- Effect, EffectMapper, EffectSystem, Tween
    controls.zig          -- input handling
    views/
      view.zig            -- View union, Renderable types
      menu.zig            -- MenuView
      combat.zig          -- CombatView
      summary.zig         -- SummaryView

  -- test harnesses (domain only) --
  harness.zig
  sim.zig
```

Directory split enforced by imports:
- `domain/*` imports `infra` (no SDL)
- `presentation/mod.zig` imports `sdl3` directly
- `main.zig` imports both

## Decisions

- **Renderable type**: Tagged union. Simple, sufficient.
- **Tween ownership**: Flat list in EffectSystem. Can revisit if chaining/cancellation gets complex.
- **View transitions**: Hard cut. Sliding/fading easy to retrofit later.
- **Hit testing**: Views recompute layout on input (no cached layout). Acceptable for turn-based; revisit if perf becomes an issue.
- **SDL isolation**: SDL removed from infra.zig. Presentation code imports sdl3 directly; domain code cannot accidentally depend on it.