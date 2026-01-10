# T043: JSON Event Logger
Created: 2026-01-10

## Problem statement / value driver

General-purpose event stream capture for debugging, replay analysis, and tooling. Currently only `combat_packet_resolved` events are logged (via `audit_log.zig`) in human-readable format.

### Scope - goals
- Log ALL `Event` union variants to JSON
- Default output: `./events.log.json` (one JSON object per line, JSONL format)
- Configurable: enable/disable, output path

### Scope - non-goals
- Replace `audit_log.zig` (complementary: audit log is combat-packet-specific with readable format)
- Replay system (future consumer of this log)

## Background

### Key files
- `src/domain/events.zig` - `Event` tagged union, `EventSystem`
- `src/domain/audit_log.zig` - existing specialized logger for `combat_packet_resolved`
- `src/main.zig:84` - calls `audit_log.drainPacketEvents` in game loop

### Existing systems
- `EventSystem` double-buffers events; consumers drain `current_events` after `swap_buffers()`
- `audit_log.drainPacketEvents` iterates current_events, filters for combat packets, appends to file

## Design Options

### Option A: Extend audit_log.zig
Add JSON serialization alongside existing text format. Single drain point.
- Pro: minimal new code
- Con: conflates two concerns (combat analysis vs general logging)

### Option B: New json_event_log.zig module (recommended)
Separate module with own drain function called from main loop.
- Pro: clean separation, audit_log stays focused
- Con: two drain calls in main loop

### Decisions
1. **Release builds** - enabled by default (useful for post-session analysis)
2. **Frame/tick metadata** - include frame number in each JSON object for ordering
3. **Buffering** - own ArenaAllocator, reset after flush (pattern from `coordinator.frame_arena`)

## Tasks - COMPLETE

1. ✓ Created `src/domain/json_event_log.zig`
   - `JsonEventLog.init(path)` / `deinit()` for file handle lifecycle
   - `drainAllEvents(event_system)` - serialize each event to JSON line
   - `advanceFrame()` - increment frame counter
2. ✓ JSON serialization via manual `std.fmt.bufPrint` (std.json API changed in Zig 0.15)
3. ✓ Wired into `main.zig:91` after `audit_log.drainPacketEvents`
4. Deferred: config flag (currently always enabled)

## Implementation Notes
- Uses fixed 4KB buffer per event, no arena needed
- Manual JSON formatting handles all 40+ event types
- Simplified approach: less detail on some events (marked with `else => `)

## Test / Verification Strategy

### Success criteria - VERIFIED
- ✓ Running game produces `events.log.json` with valid JSONL
- ✓ 507 events from full game session, all parsed by jq
- ✓ 21 distinct event types captured including combat physics data
- ✓ Frame numbers present for ordering

## Future Improvements

### Streaming JSON API
Current implementation uses manual `std.fmt.bufPrint` for JSON serialization. Consider migrating to `std.json.Stringify` (Zig 0.15 streaming API) for:
- Proper string escaping (current approach assumes safe strings from `@tagName()`)
- Cleaner code for complex nested structures
- Automatic handling of special characters in arbitrary `[]const u8` fields (e.g., `weapon_name`)

Worth considering for `audit_log.zig` as well if it needs richer output in future.
