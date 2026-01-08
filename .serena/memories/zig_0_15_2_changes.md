# Zig 0.15.2 Changes & Reference

This project uses **Zig 0.15.2**.

## Key Breaking Changes (0.14.0 - 0.15.2)

### I/O Overhaul ("Writergate")
- Generic `Reader`/`Writer` types removed → replaced by `std.Io.Reader` / `std.Io.Writer`
- New interfaces use explicit vtables (not comptime generics)
- **Unbuffered by default** - must pass buffer explicitly:
  ```zig
  var buf: [4096]u8 = undefined;
  var writer = file.writer(&buf);
  try writer.print("Hello", .{});
  try writer.flush(); // MANDATORY
  ```
- `std.io.BufferedWriter` and `std.io.CountingWriter` removed

### Collections ("Unmanaged" Default)
- `std.ArrayList` is now unmanaged (no allocator field)
- Old `ArrayListUnmanaged` renamed to `std.ArrayList`
- New usage:
  ```zig
  var list = std.ArrayList(u8){};
  try list.append(allocator, item); // allocator passed per-call
  ```
- Old managed behavior in `std.array_list.Managed(T)` (discouraged)
- `BoundedArray` entirely removed - use fixed array + length manually

### Allocators
- `GeneralPurposeAllocator` → `std.heap.DebugAllocator`
- New `std.heap.SmpAllocator` for high-performance multi-threaded use

### Language Features
- Labeled switch statements: `switch (enum) :label { ... }`
- `@branchHint` replaced `@setCold` / `@setHot`

## External Dependencies

See memory `zig_sdl3_bindings` for SDL3 bindings reference.
