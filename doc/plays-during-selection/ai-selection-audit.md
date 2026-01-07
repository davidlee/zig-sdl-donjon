# AI Card Selection Audit

> **Research task**: Document how AI selects and commits cards, with particular attention to timeline/timing requirements.
>
> **Date**: 2026-01-07

## Summary

The AI selection system is simpler than the player's command flow. AI directors call `playValidCardReservingCosts()` directly, bypassing the command handler entirely. The AI does **not** currently specify timing or targets, and would need modification to participate in a timeline-based selection model.

## AI Director Architecture

### Location
`/home/david/dev/lang/zig/deck_of_dwarf/src/domain/ai.zig`

### Director Types

```zig
/// AI strategy "interface"
pub const Director = struct {
    ptr: *anyopaque,
    playCardsFn: *const fn (ptr: *anyopaque, agent: *Agent, w: *World) anyerror!void,

    pub fn playCards(self: *Director, agent: *Agent, w: *World) !void {
        return self.playCardsFn(self.ptr, agent, w);
    }
};
```

Three implementations:

| Director | Strategy | Use Case |
|----------|----------|----------|
| `NullDirector` | Does nothing | Testing |
| `SimpleDeckDirector` | First 3 playable cards from hand | Deck-based enemies |
| `PoolDirector` | 2-3 random cards from `always_available` | Pool-based enemies |

### Combat.Director Union

```zig
// src/domain/combat/types.zig:10
pub const Director = union(enum) {
    player,
    ai: ai.Director,
};
```

## When AI Plays Cards

AI card selection happens at the **start of player selection phase**, triggered by event processing:

```zig
// src/domain/apply/event_processor.zig:224-233
.player_card_selection => {
    // AI plays cards when player enters selection phase
    for (self.world.encounter.?.enemies.items) |agent| {
        switch (agent.director) {
            .ai => |*director| {
                try director.playCards(agent, self.world);
            },
            else => unreachable,
        }
    }
},
```

### Sequence

1. Turn phase transitions to `.player_card_selection`
2. Event processor iterates all enemies
3. Each AI director's `playCards()` is called
4. AI cards go to `in_play` zone immediately
5. Player then makes their selections

## Card Selection Logic

### SimpleDeckDirector (lines 77-100)

```zig
pub fn playCards(ptr: *anyopaque, agent: *Agent, w: *World) !void {
    _ = ptr;
    const cs = agent.combat_state orelse return;
    var to_play: usize = 3;
    var hand_index: usize = 0;
    while (to_play > 0 and hand_index < cs.hand.items.len) : (hand_index += 1) {
        const card_id = cs.hand.items[hand_index];
        const card = w.card_registry.get(card_id) orelse continue;
        if (apply.isCardSelectionValid(agent, card, w.encounter)) {
            // AI doesn't select targets yet (uses all_enemies or auto-target)
            _ = try apply.playValidCardReservingCosts(&w.events, agent, card, &w.card_registry, null);
            to_play -= 1;
        }
    }
}
```

Key observations:
- **No timing specified**: Just plays cards, no `time_start` parameter
- **No explicit targets**: Passes `null` as target parameter
- **Sequential from hand**: Iterates hand in order, plays first valid cards
- **Fixed count**: Attempts to play exactly 3 cards

### PoolDirector (lines 105-138)

```zig
pub fn playCards(ptr: *anyopaque, agent: *Agent, w: *World) !void {
    _ = ptr;
    const available = agent.always_available.items;
    if (available.len == 0) return;

    // Pick 2-3 cards randomly
    const r1 = try w.drawRandom(.combat);
    const target_plays: usize = 2 + @as(usize, @intFromFloat(@floor(r1 * 2)));
    var played: usize = 0;

    // Try up to 10 random picks to find valid cards
    var attempts: usize = 0;
    while (played < target_plays and attempts < 10) : (attempts += 1) {
        const r2 = try w.drawRandom(.combat);
        const idx = @as(usize, @intFromFloat(r2 * @as(f32, @floatFromInt(available.len))));
        const card_id = available[idx];
        const card = w.card_registry.get(card_id) orelse continue;

        if (apply.isCardSelectionValid(agent, card, w.encounter)) {
            // AI doesn't select targets yet (uses all_enemies or auto-target)
            _ = try apply.playValidCardReservingCosts(&w.events, agent, card, &w.card_registry, null);
            played += 1;
        }
    }
}
```

Key observations:
- **Randomized selection**: Uses `drawRandom` for variety
- **Randomized count**: 2-3 cards per turn
- **No timing specified**: Same as SimpleDeckDirector
- **No explicit targets**: Same as SimpleDeckDirector

## AI vs Player Command Flow

### Player Flow
```
User Action
    → Command::play_card { card_id, target }
    → CommandHandler.playActionCard()
        → validation
        → channel conflict check with in_play
        → playValidCardReservingCosts()
        → setPendingTarget() if target provided
```

### AI Flow (Bypasses CommandHandler)
```
Event: turn_phase_transitioned_to(.player_card_selection)
    → director.playCards(agent, world)
        → isCardSelectionValid() for each card
        → playValidCardReservingCosts() directly
        → NO target selection
        → NO timing selection
```

**Key Difference**: AI calls `playValidCardReservingCosts()` directly, skipping:
- `CommandHandler.playActionCard()`
- Turn phase validation (since it runs at a known phase)
- Channel conflict checking with existing plays (but `isCardSelectionValid` handles some of this)

## Target Handling

### Current Behavior

Both AI directors pass `null` as the target parameter:

```zig
_ = try apply.playValidCardReservingCosts(&w.events, agent, card, &w.card_registry, null);
//                                                                                  ^^^^ null target
```

### Resolution at Commit/Resolve

When no explicit target is set, targeting is resolved via card expressions:

```zig
// src/domain/apply/targeting.zig:82-97
switch (query) {
    .self => { ... },
    .all_enemies => {
        if (actor.director == .player) {
            // Player targets all mobs
        } else {
            // AI targets player
            try targets.append(alloc, world.player);
        }
    },
    .single => {
        // Look up by entity ID from Play.target (would be null for AI)
        if (play_target) |target_id| { ... }
    },
}
```

**Implication**: AI cards with `.single` targeting would fail to resolve targets since `Play.target` is null.

## Validation Logic (Shared with Player)

Both player and AI use the same validation:

```zig
// src/domain/apply/validation.zig:53-55
pub fn isCardSelectionValid(actor: *const Agent, card: *const Instance, encounter: ?*const combat.Encounter) bool {
    return validateCardSelection(actor, card, .player_card_selection, encounter) catch false;
}
```

Validation includes:
- `combat_playable` check
- Phase validation
- Global condition restrictions (unconscious, paralysed, stunned)
- Resource costs (stamina, time, focus)
- Play source validation (`playable_from`)
- Rule predicates (weapon requirements, etc.)
- Melee reach validation

## Plays Creation Flow

### Current: Deferred Play Creation

AI cards → `in_play` zone → (commit phase) → `buildPlaysFromInPlayCards()` → Timeline

```zig
// src/domain/apply/event_processor.zig:121-144
fn buildPlaysFromInPlayCards(self: *EventProcessor) !void {
    // Player
    try self.buildPlaysForAgent(self.world.player, enc);

    // Mobs
    for (enc.enemies.items) |mob| {
        try self.buildPlaysForAgent(mob, enc);
    }
}

fn buildPlaysForAgent(self: *EventProcessor, agent: *Agent, enc: *combat.Encounter) !void {
    const enc_state = enc.stateFor(agent.id) orelse return;
    const cs = agent.combat_state orelse return;
    for (cs.in_play.items) |card_id| {
        const pending_target = enc_state.current.getPendingTarget(card_id);
        try enc_state.current.addPlay(.{
            .action = card_id,
            .target = pending_target,  // null for AI cards
        }, &self.world.card_registry);
    }
}
```

### Timing Assignment

Plays are positioned using `nextAvailableStart()`:

```zig
// src/domain/combat/plays.zig:432-450
pub fn addPlay(self: *TurnState, play: Play, registry: *const world.CardRegistry) ... {
    const channels = getPlayChannels(play, registry);
    const duration = getPlayDuration(play, registry);
    const start = self.timeline.nextAvailableStart(channels, duration, registry) orelse
        return error.NoSpace;
    self.timeline.insert(start, start + duration, play, channels, registry) ...
}
```

**Result**: All cards (player and AI) get sequential timing at commit phase entry, placed at first available slot per channel.

## Impact Analysis for Refactor

### If Plays are created during selection phase:

1. **AI doesn't know timing**: Currently no mechanism for AI to specify `time_start`
2. **AI doesn't set targets**: Would need enhancement for `.single` targeting cards
3. **Same timeline model works**: `addPlay()` with `nextAvailableStart()` could work during selection
4. **No strategic timing**: AI doesn't reason about timing advantages

### Required Changes for AI

| Aspect | Current | If Plays During Selection |
|--------|---------|---------------------------|
| When cards played | `player_card_selection` phase start | Same |
| Where they go | `in_play` zone | Directly to Timeline |
| Timing | Assigned at commit | Assigned immediately via `addPlay()` |
| Targets | null (resolved later) | Could remain null or add selection logic |

### Minimal Change Path

The simplest approach would keep AI using `addPlay()` (which calls `nextAvailableStart()`), just calling it during selection phase instead of deferring to commit. This preserves:
- Sequential timing for AI
- No target selection requirement
- Existing validation flow

### Potential Enhancements (Not Required)

For smarter AI in the future:
- Strategic timing (counter-play positioning)
- Explicit target selection for `.single` cards
- React to player's visible plays (if selection becomes visible)

## AI-Specific Assumptions

1. **AI plays first**: Selection happens before player sees cards
2. **No player visibility**: Player can't see AI selections during their selection
3. **Sequential suffices**: AI doesn't need overlapping plays
4. **Auto-target acceptable**: `.all_enemies` → player; `.single` cards may be avoided
5. **Fixed play counts**: 2-3 cards, no resource optimization beyond validation

## Recommendations

1. **Minimal refactor**: Have AI call `TurnState.addPlay()` directly during selection instead of going through `in_play` zone
2. **Keep null targets**: Current auto-resolution works for AI's simple cards
3. **No timing parameter needed**: `nextAvailableStart()` provides adequate sequencing
4. **Consider hiding AI plays**: If player can see Timeline during selection, AI plays might need to be hidden until reveal

## Files Referenced

- `/home/david/dev/lang/zig/deck_of_dwarf/src/domain/ai.zig` - AI director implementations
- `/home/david/dev/lang/zig/deck_of_dwarf/src/domain/combat/types.zig:10` - Director union
- `/home/david/dev/lang/zig/deck_of_dwarf/src/domain/apply/event_processor.zig:224-233` - AI trigger
- `/home/david/dev/lang/zig/deck_of_dwarf/src/domain/apply/event_processor.zig:121-144` - Play building
- `/home/david/dev/lang/zig/deck_of_dwarf/src/domain/apply/command_handler.zig:68-124` - `playValidCardReservingCosts()`
- `/home/david/dev/lang/zig/deck_of_dwarf/src/domain/apply/validation.zig` - Validation logic
- `/home/david/dev/lang/zig/deck_of_dwarf/src/domain/apply/targeting.zig` - Target resolution
- `/home/david/dev/lang/zig/deck_of_dwarf/src/domain/combat/plays.zig` - Play, Timeline, TurnState
