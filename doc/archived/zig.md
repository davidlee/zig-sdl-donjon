# Zig language & standard library changes since Claude training cutoff

Here is the expanded summary of changes to the Zig Standard Library (`std`) and language features from **version 0.14.0 through 0.15.2**.

This period represents a major shift in Zig's development philosophy, moving from "generic-heavy" interfaces to "explicit & unmanaged" patterns, culminating in the massive I/O overhaul of 0.15.x.

### **Zig 0.14.0 (March 2025)**
*The "Preparation" Release.*
This release laid the groundwork for the breaking changes in 0.15, focusing on build times and memory visibility.

*   **Build System & Compiler:**
    *   **Incremental Compilation:** Enabled by default for Debug builds, significantly reducing rebuild times.
    *   **File System Watching:** `zig build --watch` became available natively.
    *   **ZON:** `std.zon` (Zig Object Notation) introduced for data serialization/deserialization, replacing some JSON use cases in build configuration.
*   **Memory Management (The "Unmanaged" Shift):**
    *   **Deprecation of Managed Types:** `std.ArrayList` and `std.AutoHashMap` (the versions storing an allocator) were marked **deprecated**.
    *   **Push toward Unmanaged:** Developers were urged to migrate to `std.ArrayListUnmanaged` and `std.HashMapUnmanaged`, passing allocators explicitly to methods.
    *   **Allocator Rename:** `std.heap.GeneralPurposeAllocator` was renamed/refactored into **`std.heap.DebugAllocator`** (focused on safety/leak detection) and a new **`std.heap.SmpAllocator`** (high-performance multi-threaded allocator) was added.
*   **Language Features:**
    *   **Labeled Switch Statements:** `switch (enum) :label { ... }` allowed for more complex control flow break/continue logic within state machines.
    *   **`@branchHint`:** Replaced `@setCold` and `@setHot` for finer optimizer control.

---

### **Zig 0.15.0 & 0.15.1 (August/September 2025)**
*The "Writergate" & Breaking Release.*
Version 0.15.0 introduced the changes, and 0.15.1 refined/enforced them. This is widely considered the most disruptive update since 0.11.

*   **"Writergate" (Complete I/O Overhaul):**
    *   **Interface Replacement:** The generic `Reader(Context, Error, ReadFn)` and `Writer` types were removed. They were replaced by non-generic interfaces **`std.Io.Reader`** and **`std.Io.Writer`** (note the capital `Io`).
    *   **Virtual Tables:** The new interfaces use explicit vtables (stored in `std.mem.Allocator` style) rather than comptime generics, improving compile times and allowing easier runtime polymorphism.
    *   **Explicit Buffering:** The new `std.Io` interfaces are **unbuffered by default**. APIs that previously buffered internally (like `std.fs.File.writer()`) now require you to pass a buffer:
        ```zig
        // 0.15.x pattern
        var buf: [4096]u8 = undefined;
        var writer = file.writer(&buf); // Returns a buffered writer wrapper
        try writer.print("Hello", .{});
        try writer.flush(); // MANDATORY: forgetting this loses data
        ```
    *   **Removals:** `std.io.BufferedWriter` and `std.io.CountingWriter` wrappers were removed, as buffering and counting are now handled via specific implementation strategies or the new `std.Io` adapter chain.

*   **Standard Library Collections (The "Unmanaged" Default):**
    *   **`std.ArrayList` is now Unmanaged:** The type previously known as `ArrayListUnmanaged` was renamed to `std.ArrayList`. It no longer stores an allocator field.
    *   **Migration:** Old code doing `var list = std.ArrayList(u8).init(allocator);` broke.
    *   **New Usage:**
        ```zig
        var list = std.ArrayList(u8){}; // No allocator in init
        try list.append(allocator, item); // Allocator passed here
        ```
    *   **Managed Wrapper:** The old behavior was moved to `std.array_list.Managed(T)`, but its use is discouraged in libraries.

*   **Async Preparation:**
    *   Internal changes to the compiler and `std` to support the re-introduction of `async`/`await` (planned for 0.16 or later), influencing the decision to move to `std.Io` interfaces.

- BoundedArray was entirely removed in 0.15.0
    Depending on your use case, the standard practice is to use one of the following alternatives:
    - For small, fixed-size buffers with dynamic length: Manually manage a fixed-size array along with a separate length variable (e.g., in a simple struct { buffer: [N]T, len: usize }). This is essentially what BoundedArray did internally.
    - For general-purpose dynamic arrays: Use std.ArrayList (which is managed by an allocator) or std.ArrayListUnmanaged with an externally provided buffer (e.g., from a stack-allocated buffer or a std.heap.FixedBufferAllocator).
---

### **Zig 0.15.2 (October 2025)**
*The Stabilization Patch.*
Addressed immediate bugs arising from the massive refactors in 0.15.0/0.15.1.

*   **`std.Io` Fixes:**
    *   **`takeDelimiter`:** Fixed edge cases where delimiters split across buffer boundaries caused infinite loops or dropped bytes. *Breaking:* Renamed from `takeDelimiterExclusive` to clarify behavior.
    *   **`readVec` / Vectored I/O:** Fixed position tracking bugs when reading into non-contiguous slices.
    *   **`Limited` Reader:** Fixed issue where EOF was not correctly signaled if the limit matched the stream end exactly.
*   **Networking (`std.net`):**
    *   Fixed `std.net.getAddrInfo` failing to parse certain `/etc/hosts` configurations on Linux/BSD due to the new buffering logic returning short reads.
*   **System:**
    *   **`std.process`:** Fixed memory reporting overflow on 32-bit targets.
    *   **macOS Support:** improved `std.fs` compatibilty for Darwin following the I/O vtable switch.