# Development Commands

## Build & Run
```bash
zig build              # Build the project
zig build run          # Build and run
./zig-out/bin/cardigan # Run built binary
just                   # Build + run (default)
```

## Testing
```bash
zig build test         # Run all tests
```

## Formatting & Linting
```bash
zig fmt src/           # Format all source files
zig fmt --check src/   # Check formatting without changes
```

## Useful Patterns
```bash
zig build 2>&1 | head -50   # Build with truncated errors
zig fmt src/ && zig build   # Format then build
```
