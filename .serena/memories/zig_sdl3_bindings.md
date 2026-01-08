# Zig SDL3 Bindings

**Local path:** `./zig-sdl3` (symlink)  
**Homepage:** https://codeberg.org/7Games/zig-sdl3  
**Docs:** https://gota7.github.io/zig-sdl3/

## Overview
Lightweight wrapper providing idiomatic Zig access to SDL3 (windowing, audio, rendering, GPU).

## Key Features
- Organized namespaces for SDL subsystems
- Error handling with custom callbacks
- C bindings available via namespace
- Standard resource lifecycle (init/deinit)
- Type safety with optional annotations
- Conversion utilities between Zig and SDL types

## Build Integration
```zig
const sdl3 = b.dependency("sdl3", .{
    .target = target,
    .optimize = optimize,
});
lib.root_module.addImport("sdl3", sdl3.module("sdl3"));
```

## Status
Subsystems complete but not yet production-ready. Version 1.0.0 pending bug fixes and API refinement.
