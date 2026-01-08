# Deck of Dwarf - Project Overview

## Purpose
Experimental deck-building dungeon battler - "Dwarf Fortress meets Slay the Spire meets Balatro"
- Simultaneous disclosure combat with information asymmetry
- Detailed wound/armor simulation (no health bars - bone, tissue, organ trauma)
- Alcohol-based regeneration mechanic

## Tech Stack
- **Language:** Zig 0.15.2
- **Graphics:** SDL3 (via zig-sdl3 bindings)
- **State machine:** zigfsm
- **Build:** Nix flake + zig build system
- **Web target:** zemscripten (Emscripten)

## Architecture Layers
```
infra/          Shared contracts (no SDL)
domain/         Pure game logic (imports infra, never SDL)
presentation/   SDL rendering & input (imports infra + SDL)
main.zig        Entry point
```

Key principle: SDL only imported in presentation/mod.zig

## Source Structure
- `src/domain/` - Pure game state, FSM, entities
- `src/presentation/` - Views, coordinator, graphics
- `src/apply/` - Action validation and execution
- `src/model/` - Data models
- `src/content/` - Game content definitions
- `src/infra/` - Shared utilities
- `src/commands.zig` - Domain/presentation contract
