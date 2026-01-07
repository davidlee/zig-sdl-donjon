//! Combat play management - cards being played and timeline tracking.
//!
//! Contains Play (a card with modifiers), Timeline (time-based scheduling),
//! and turn state management.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const cards = @import("../cards.zig");
const body = @import("../body.zig");
const world = @import("../world.zig");
const advantage = @import("advantage.zig");

pub const TechniqueAdvantage = advantage.TechniqueAdvantage;

// ============================================================================
// Play
// ============================================================================

/// Which phase the play was created in.
pub const Phase = enum { selection, commit };

/// Source tracking for pool cards (always_available, spells_known).
/// Null source on a Play indicates a hand card.
pub const PlaySource = struct {
    master_id: entity.ID, // Original pool card for cooldown tracking
    source_zone: SourceZone,

    pub const SourceZone = enum { always_available, spells_known };
};

/// Entry in a Play's modifier stack, tracking both the card and its source.
/// Source tracking enables correct lifecycle handling (destroy clone vs discard hand card).
pub const ModifierEntry = struct {
    card_id: entity.ID,
    source: ?PlaySource, // null = hand card, Some = pool clone
};

/// A card being played, with optional modifier stack.
pub const Play = struct {
    pub const max_modifiers = 4;

    action: entity.ID, // the lead card (technique, maneuver, etc.)
    target: ?entity.ID = null, // who this play targets (null for self-target or all)
    source: ?PlaySource = null, // null = hand card, Some = pool clone
    modifier_stack_buf: [max_modifiers]ModifierEntry = undefined,
    modifier_stack_len: usize = 0,
    stakes: cards.Stakes = .guarded,
    added_in_phase: Phase = .selection, // commit phase plays (via Focus) cannot be stacked

    // Applied by modify_play effects during commit phase
    cost_mult: f32 = 1.0,
    damage_mult: f32 = 1.0,
    advantage_override: ?TechniqueAdvantage = null,

    pub fn modifiers(self: *const Play) []const ModifierEntry {
        return self.modifier_stack_buf[0..self.modifier_stack_len];
    }

    pub fn addModifier(self: *Play, card_id: entity.ID, source: ?PlaySource) error{Overflow}!void {
        if (self.modifier_stack_len >= max_modifiers) return error.Overflow;
        self.modifier_stack_buf[self.modifier_stack_len] = .{ .card_id = card_id, .source = source };
        self.modifier_stack_len += 1;
    }

    pub fn cardCount(self: Play) usize {
        return 1 + self.modifier_stack_len;
    }

    pub fn canStack(self: Play) bool {
        return self.added_in_phase != .commit;
    }

    /// Stakes based on modifier stack depth.
    pub fn effectiveStakes(self: Play) cards.Stakes {
        return switch (self.modifier_stack_len) {
            0 => self.stakes,
            1 => .committed,
            else => .reckless,
        };
    }

    /// Get advantage profile (override if set, else from technique).
    pub fn getAdvantage(self: Play, technique: *const cards.Technique) ?TechniqueAdvantage {
        return self.advantage_override orelse technique.advantage;
    }

    // -------------------------------------------------------------------------
    // Computed modifier effects
    // -------------------------------------------------------------------------

    /// Extract modify_play effect from a template (first on_commit rule with modify_play).
    fn getModifyPlayEffect(template: *const cards.Template) ?cards.ModifyPlay {
        for (template.rules) |rule| {
            if (rule.trigger != .on_commit) continue;
            for (rule.expressions) |expr| {
                switch (expr.effect) {
                    .modify_play => |mp| return mp,
                    else => {},
                }
            }
        }
        return null;
    }

    /// Compute effective cost multiplier from modifier stack + stored override.
    pub fn effectiveCostMult(self: *const Play, registry: *const world.CardRegistry) f32 {
        var mult: f32 = 1.0;
        for (self.modifiers()) |entry| {
            const card = registry.getConst(entry.card_id) orelse continue;
            if (getModifyPlayEffect(card.template)) |mp| {
                mult *= mp.cost_mult orelse 1.0;
            }
        }
        return mult * self.cost_mult; // stored override applied last
    }

    /// Compute effective damage multiplier from modifier stack + stored override.
    pub fn effectiveDamageMult(self: *const Play, registry: *const world.CardRegistry) f32 {
        var mult: f32 = 1.0;
        for (self.modifiers()) |entry| {
            const card = registry.getConst(entry.card_id) orelse continue;
            if (getModifyPlayEffect(card.template)) |mp| {
                mult *= mp.damage_mult orelse 1.0;
            }
        }
        return mult * self.damage_mult; // stored override applied last
    }

    /// Compute effective height from modifier stack (last override wins).
    pub fn effectiveHeight(self: *const Play, registry: *const world.CardRegistry, base: body.Height) body.Height {
        var height = base;
        for (self.modifiers()) |entry| {
            const card = registry.getConst(entry.card_id) orelse continue;
            if (getModifyPlayEffect(card.template)) |mp| {
                if (mp.height_override) |h| height = h;
            }
        }
        return height;
    }

    /// Check if adding a modifier would conflict with existing modifiers.
    /// Currently detects: conflicting height_override (e.g., Low + High).
    pub fn wouldConflict(self: *const Play, new_modifier: *const cards.Template, registry: *const world.CardRegistry) bool {
        const new_effect = getModifyPlayEffect(new_modifier) orelse return false;
        const new_height = new_effect.height_override orelse return false;

        // Check existing modifiers for conflicting height
        for (self.modifiers()) |entry| {
            const card = registry.getConst(entry.card_id) orelse continue;
            if (getModifyPlayEffect(card.template)) |mp| {
                if (mp.height_override) |existing_height| {
                    if (existing_height != new_height) return true;
                }
            }
        }
        return false;
    }
};

// ============================================================================
// TimeSlot & Timeline
// ============================================================================

/// A play positioned within a tick's timeline.
/// Duration is computed on-demand from the play's current state.
pub const TimeSlot = struct {
    time_start: f32, // 0.0-1.0 within tick
    play: Play,

    /// Compute duration from play's current state (includes modifier effects).
    pub fn duration(self: TimeSlot, registry: *const world.CardRegistry) f32 {
        return getPlayDuration(self.play, registry);
    }

    /// Compute end time from play's current state.
    pub fn timeEnd(self: TimeSlot, registry: *const world.CardRegistry) f32 {
        return self.time_start + self.duration(registry);
    }

    /// Check if this slot overlaps with a time range.
    pub fn overlapsWith(self: TimeSlot, start: f32, end: f32, registry: *const world.CardRegistry) bool {
        return self.timeEnd(registry) > start and self.time_start < end;
    }
};

/// Time-aware collection of plays within a tick.
/// Slots are kept sorted by time_start for natural iteration order.
pub const Timeline = struct {
    pub const max_slots = 12; // More than max_plays since overlaps possible
    pub const granularity: f32 = 0.1; // 100ms slots

    slots_buf: [max_slots]TimeSlot = undefined,
    slots_len: usize = 0,

    /// Get all slots as a slice (sorted by time_start).
    pub fn slots(self: *const Timeline) []const TimeSlot {
        return self.slots_buf[0..self.slots_len];
    }

    /// Get mutable slots slice.
    pub fn slotsMut(self: *Timeline) []TimeSlot {
        return self.slots_buf[0..self.slots_len];
    }

    /// Number of slots.
    pub fn len(self: *const Timeline) usize {
        return self.slots_len;
    }

    /// Snap a time value to granularity (round down).
    pub fn snap(time: f32) f32 {
        return @trunc(time / granularity) * granularity;
    }

    /// Check if a play with given channels can be inserted at time range.
    pub fn canInsert(
        self: *const Timeline,
        time_start: f32,
        time_end: f32,
        channels: cards.ChannelSet,
        registry: *const world.CardRegistry,
    ) bool {
        if (self.slots_len >= max_slots) return false;
        if (time_end > 1.0) return false;

        for (self.slots()) |slot| {
            // Check time overlap first (compute slot's end time on demand)
            if (!slot.overlapsWith(time_start, time_end, registry)) continue;

            // If times overlap, check channel conflict
            const slot_channels = getPlayChannels(slot.play, registry);
            if (channels.conflicts(slot_channels)) return false;
        }
        return true;
    }

    /// Insert a play at specified time. Auto-snaps time_start to granularity.
    /// Duration is computed from the play; time_end parameter used for validation.
    /// Maintains sorted order by time_start.
    pub fn insert(
        self: *Timeline,
        time_start: f32,
        time_end: f32,
        play: Play,
        channels: cards.ChannelSet,
        registry: *const world.CardRegistry,
    ) error{ Conflict, Overflow }!void {
        const snapped_start = snap(time_start);
        const snapped_end = snapped_start + (time_end - time_start);

        if (!self.canInsert(snapped_start, snapped_end, channels, registry)) {
            if (self.slots_len >= max_slots) return error.Overflow;
            return error.Conflict;
        }

        const new_slot = TimeSlot{
            .time_start = snapped_start,
            .play = play,
        };

        // Find insertion point to maintain sorted order
        var insert_pos: usize = self.slots_len;
        for (self.slots(), 0..) |slot, i| {
            if (snapped_start < slot.time_start) {
                insert_pos = i;
                break;
            }
        }

        // Shift elements to make room
        if (insert_pos < self.slots_len) {
            var i = self.slots_len;
            while (i > insert_pos) : (i -= 1) {
                self.slots_buf[i] = self.slots_buf[i - 1];
            }
        }

        self.slots_buf[insert_pos] = new_slot;
        self.slots_len += 1;
    }

    /// Remove slot by index.
    pub fn remove(self: *Timeline, index: usize) void {
        if (index >= self.slots_len) return;
        // Shift remaining slots down
        var i = index;
        while (i < self.slots_len - 1) : (i += 1) {
            self.slots_buf[i] = self.slots_buf[i + 1];
        }
        self.slots_len -= 1;
    }

    /// Find slot index containing card.
    pub fn findByCard(self: *const Timeline, card_id: entity.ID) ?usize {
        for (self.slots(), 0..) |slot, i| {
            if (slot.play.action.eql(card_id)) return i;
        }
        return null;
    }

    /// Find first available start time for given channels and duration.
    /// Returns null if no space available before tick end (1.0).
    pub fn nextAvailableStart(
        self: *const Timeline,
        channels: cards.ChannelSet,
        duration: f32,
        registry: *const world.CardRegistry,
    ) ?f32 {
        var candidate: f32 = 0.0;
        while (candidate + duration <= 1.0) {
            if (self.canInsert(candidate, candidate + duration, channels, registry)) {
                return candidate;
            }
            candidate += granularity;
        }
        return null;
    }

    /// Get channels occupied at a specific time point.
    pub fn channelsOccupiedAt(
        self: *const Timeline,
        time: f32,
        registry: *const world.CardRegistry,
    ) cards.ChannelSet {
        var occupied = cards.ChannelSet{};
        for (self.slots()) |slot| {
            if (time >= slot.time_start and time < slot.timeEnd(registry)) {
                occupied = occupied.merge(getPlayChannels(slot.play, registry));
            }
        }
        return occupied;
    }

    /// Clear all slots.
    pub fn clear(self: *Timeline) void {
        self.slots_len = 0;
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Get duration of a play from its card's time cost.
pub fn getPlayDuration(play: Play, registry: *const world.CardRegistry) f32 {
    const card = registry.getConst(play.action) orelse return 0.0;
    return card.template.cost.time * play.effectiveCostMult(registry);
}

/// Get combined channels occupied by a play (lead card + modifiers).
pub fn getPlayChannels(play: Play, registry: *const world.CardRegistry) cards.ChannelSet {
    var channels = cards.ChannelSet{};
    var has_technique = false;
    var lead_tags: ?cards.TagSet = null;

    // Get channels from lead card
    if (registry.getConst(play.action)) |instance| {
        lead_tags = instance.template.tags;
        if (instance.template.getTechnique()) |technique| {
            channels = channels.merge(technique.channels);
            has_technique = true;
        }
    }

    // Modifiers don't typically add channels, but include for completeness
    for (play.modifiers()) |entry| {
        if (registry.getConst(entry.card_id)) |instance| {
            if (instance.template.getTechnique()) |technique| {
                channels = channels.merge(technique.channels);
                has_technique = true;
            }
        }
    }

    // Cards without techniques get default channels based on tags
    if (!has_technique) {
        if (lead_tags) |tags| {
            channels = channels.merge(cards.defaultChannelsForTags(tags));
        }
    }

    // Warn if card still has no channels
    if (channels.isEmpty()) {
        if (registry.getConst(play.action)) |instance| {
            std.log.warn("card '{s}' has no channels assigned", .{instance.template.name});
        }
    }

    return channels;
}

/// Returns true if any play in the timeline uses the footwork channel.
pub fn hasFootworkInTimeline(timeline: *const Timeline, registry: *const world.CardRegistry) bool {
    for (timeline.slots()) |slot| {
        const channels = getPlayChannels(slot.play, registry);
        if (channels.footwork) return true;
    }
    return false;
}

// ============================================================================
// Turn State
// ============================================================================

/// Ephemeral state for the current turn - exists from commit through resolution.
pub const TurnState = struct {
    timeline: Timeline = .{},
    focus_spent: f32 = 0,
    stack_focus_paid: bool = false, // 1F covers all stacking for the turn

    /// Get all slots (sorted by time_start).
    pub fn slots(self: *const TurnState) []const TimeSlot {
        return self.timeline.slots();
    }

    /// Get mutable slots slice.
    pub fn slotsMut(self: *TurnState) []TimeSlot {
        return self.timeline.slotsMut();
    }

    pub fn clear(self: *TurnState) void {
        self.timeline.clear();
        self.focus_spent = 0;
        self.stack_focus_paid = false;
    }

    /// Add a play at the next available time slot.
    /// Preserves sequential behavior from old API.
    pub fn addPlay(
        self: *TurnState,
        play: Play,
        registry: *const world.CardRegistry,
    ) error{ Overflow, Conflict, NoSpace }!void {
        // Check capacity first for clearer error
        if (self.timeline.slots_len >= Timeline.max_slots) return error.Overflow;

        const channels = getPlayChannels(play, registry);
        const duration = getPlayDuration(play, registry);
        const start = self.timeline.nextAvailableStart(channels, duration, registry) orelse
            return error.NoSpace;
        self.timeline.insert(start, start + duration, play, channels, registry) catch |err| switch (err) {
            error.Conflict => return error.Conflict,
            error.Overflow => return error.Overflow,
        };
    }

    /// Add a play at a specific time.
    pub fn addPlayAt(
        self: *TurnState,
        play: Play,
        time_start: f32,
        registry: *const world.CardRegistry,
    ) error{ Overflow, Conflict }!void {
        const channels = getPlayChannels(play, registry);
        const duration = getPlayDuration(play, registry);
        try self.timeline.insert(time_start, time_start + duration, play, channels, registry);
    }

    /// Remove a play by index.
    pub fn removePlay(self: *TurnState, index: usize) void {
        self.timeline.remove(index);
    }

    /// Find a play by its action card ID, returns index or null.
    pub fn findPlayByCard(self: *const TurnState, card_id: entity.ID) ?usize {
        return self.timeline.findByCard(card_id);
    }
};

/// Ring buffer of recent turns for sequencing predicates.
pub const TurnHistory = struct {
    pub const max_history = 4;

    recent_buf: [max_history]TurnState = undefined,
    recent_len: usize = 0,

    pub fn recent(self: *const TurnHistory) []const TurnState {
        return self.recent_buf[0..self.recent_len];
    }

    pub fn push(self: *TurnHistory, turn: TurnState) void {
        if (self.recent_len == max_history) {
            // Shift out oldest
            std.mem.copyForwards(TurnState, self.recent_buf[0 .. max_history - 1], self.recent_buf[1..max_history]);
            self.recent_len -= 1;
        }
        self.recent_buf[self.recent_len] = turn;
        self.recent_len += 1;
    }

    pub fn lastTurn(self: *const TurnHistory) ?*const TurnState {
        return if (self.recent_len > 0)
            &self.recent_buf[self.recent_len - 1]
        else
            null;
    }

    pub fn turnsAgo(self: *const TurnHistory, n: usize) ?*const TurnState {
        if (n >= self.recent_len) return null;
        return &self.recent_buf[self.recent_len - 1 - n];
    }
};

/// Per-agent state within an encounter.

// ============================================================================
// Attention State
// ============================================================================

/// Tracks which enemy an agent is focused on and peripheral awareness.
/// Attacking non-primary targets incurs penalties reduced by awareness.
pub const AttentionState = struct {
    primary: ?entity.ID = null, // current focus target
    awareness: f32, // base awareness from acuity (0-1 scale)

    pub fn init(acuity: f32) AttentionState {
        return .{ .primary = null, .awareness = acuity * 0.1 };
    }

    /// Penalty for acting against non-primary target.
    /// Returns 0 for primary target, up to 0.2 for others (reduced by awareness).
    pub fn penaltyFor(self: AttentionState, target: entity.ID) f32 {
        if (self.primary == null) return 0;
        if (self.primary.?.eql(target)) return 0;
        return @max(0, 0.2 - self.awareness);
    }
};

pub const AgentEncounterState = struct {
    current: TurnState = .{},
    history: TurnHistory = .{},
    attention: AttentionState = .{ .awareness = 0.1 }, // default awareness

    /// End current turn: push to history, clear turn state, reset attention primary.
    pub fn endTurn(self: *AgentEncounterState) void {
        self.history.push(self.current);
        self.current.clear();
        self.attention.primary = null; // reset primary target each turn
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testId(index: u32) entity.ID {
    return .{ .index = index, .generation = 0 };
}

// AttentionState tests

test "AttentionState.init derives awareness from acuity" {
    const state = AttentionState.init(0.5);
    try testing.expectEqual(@as(f32, 0.05), state.awareness);
    try testing.expectEqual(@as(?entity.ID, null), state.primary);
}

test "AttentionState.init with high acuity" {
    const state = AttentionState.init(1.0);
    try testing.expectEqual(@as(f32, 0.1), state.awareness);
}

test "AttentionState.penaltyFor returns 0 for primary target" {
    var state = AttentionState.init(0.5);
    state.primary = testId(1);
    try testing.expectEqual(@as(f32, 0), state.penaltyFor(testId(1)));
}

test "AttentionState.penaltyFor returns 0 when no primary set" {
    const state = AttentionState.init(0.5);
    try testing.expectEqual(@as(f32, 0), state.penaltyFor(testId(1)));
}

test "AttentionState.penaltyFor returns penalty for non-primary" {
    var state = AttentionState.init(0.5); // awareness = 0.05
    state.primary = testId(1);
    // Penalty = max(0, 0.2 - 0.05) = 0.15
    try testing.expectEqual(@as(f32, 0.15), state.penaltyFor(testId(2)));
}

test "AttentionState.penaltyFor reduced by high awareness" {
    var state = AttentionState.init(2.0); // awareness = 0.2
    state.primary = testId(1);
    // Penalty = max(0, 0.2 - 0.2) = 0
    try testing.expectEqual(@as(f32, 0), state.penaltyFor(testId(2)));
}

test "Play.effectiveStakes escalates with modifiers" {
    var play = Play{ .action = testId(1) };
    try testing.expectEqual(cards.Stakes.guarded, play.effectiveStakes());

    try play.addModifier(testId(2), null);
    try testing.expectEqual(cards.Stakes.committed, play.effectiveStakes());

    try play.addModifier(testId(3), null);
    try testing.expectEqual(cards.Stakes.reckless, play.effectiveStakes());
}

test "Play.canStack false when added in commit phase" {
    const normal_play = Play{ .action = testId(1) };
    try testing.expect(normal_play.canStack());

    const commit_play = Play{ .action = testId(2), .added_in_phase = .commit };
    try testing.expect(!commit_play.canStack());
}

test "TurnState tracks plays and clears" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};
    try testing.expectEqual(@as(usize, 0), state.slots().len);

    try state.addPlay(.{ .action = testId(1) }, &registry);
    try state.addPlay(.{ .action = testId(2) }, &registry);
    try testing.expectEqual(@as(usize, 2), state.slots().len);

    state.clear();
    try testing.expectEqual(@as(usize, 0), state.slots().len);
    try testing.expectEqual(@as(f32, 0), state.focus_spent);
}

test "TurnHistory ring buffer evicts oldest" {
    var history = TurnHistory{};

    // Push 4 turns (fills buffer)
    var turn1 = TurnState{};
    turn1.focus_spent = 1.0;
    history.push(turn1);

    var turn2 = TurnState{};
    turn2.focus_spent = 2.0;
    history.push(turn2);

    var turn3 = TurnState{};
    turn3.focus_spent = 3.0;
    history.push(turn3);

    var turn4 = TurnState{};
    turn4.focus_spent = 4.0;
    history.push(turn4);

    try testing.expectEqual(@as(usize, 4), history.recent_len);
    try testing.expectEqual(@as(f32, 4.0), history.lastTurn().?.focus_spent);
    try testing.expectEqual(@as(f32, 1.0), history.turnsAgo(3).?.focus_spent);

    // Push 5th turn, should evict turn1
    var turn5 = TurnState{};
    turn5.focus_spent = 5.0;
    history.push(turn5);

    try testing.expectEqual(@as(usize, 4), history.recent_len);
    try testing.expectEqual(@as(f32, 5.0), history.lastTurn().?.focus_spent);
    try testing.expectEqual(@as(f32, 2.0), history.turnsAgo(3).?.focus_spent); // turn1 evicted
}

test "AgentEncounterState.endTurn pushes to history" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = AgentEncounterState{};

    // Add a play to current turn
    try state.current.addPlay(.{ .action = testId(1) }, &registry);
    state.current.focus_spent = 2.5;

    // End turn
    state.endTurn();

    // Current should be cleared
    try testing.expectEqual(@as(usize, 0), state.current.slots().len);
    try testing.expectEqual(@as(f32, 0), state.current.focus_spent);

    // History should have the previous turn
    try testing.expectEqual(@as(usize, 1), state.history.recent_len);
    try testing.expectEqual(@as(f32, 2.5), state.history.lastTurn().?.focus_spent);
}

test "Play.addModifier overflow returns error" {
    var play = Play{ .action = testId(0) };

    // Fill to capacity
    for (0..Play.max_modifiers) |i| {
        try play.addModifier(testId(@intCast(i + 1)), null);
    }
    try testing.expectEqual(Play.max_modifiers, play.modifier_stack_len);

    // Next one should fail
    try testing.expectError(error.Overflow, play.addModifier(testId(99), null));
    try testing.expectEqual(Play.max_modifiers, play.modifier_stack_len); // unchanged
}

test "TurnState.addPlay overflow returns error" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};

    // Fill to capacity (Timeline.max_slots)
    for (0..Timeline.max_slots) |i| {
        try state.addPlay(.{ .action = testId(@intCast(i)) }, &registry);
    }
    try testing.expectEqual(Timeline.max_slots, state.slots().len);

    // Next one should fail with Overflow
    try testing.expectError(error.Overflow, state.addPlay(.{ .action = testId(99) }, &registry));
    try testing.expectEqual(Timeline.max_slots, state.slots().len); // unchanged
}

test "TurnState.removePlay shifts remaining plays" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};

    try state.addPlay(.{ .action = testId(1) }, &registry);
    try state.addPlay(.{ .action = testId(2) }, &registry);
    try state.addPlay(.{ .action = testId(3) }, &registry);
    try testing.expectEqual(@as(usize, 3), state.slots().len);

    // Remove middle play
    state.removePlay(1);
    try testing.expectEqual(@as(usize, 2), state.slots().len);
    try testing.expectEqual(@as(u32, 1), state.slots()[0].play.action.index);
    try testing.expectEqual(@as(u32, 3), state.slots()[1].play.action.index);
}

test "TurnState.removePlay handles out of bounds" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};
    try state.addPlay(.{ .action = testId(1) }, &registry);

    // Should do nothing for invalid index
    state.removePlay(5);
    try testing.expectEqual(@as(usize, 1), state.slots().len);
}

test "TurnState.findPlayByCard returns correct index" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};

    try state.addPlay(.{ .action = testId(10) }, &registry);
    try state.addPlay(.{ .action = testId(20) }, &registry);
    try state.addPlay(.{ .action = testId(30) }, &registry);

    try testing.expectEqual(@as(?usize, 0), state.findPlayByCard(testId(10)));
    try testing.expectEqual(@as(?usize, 1), state.findPlayByCard(testId(20)));
    try testing.expectEqual(@as(?usize, 2), state.findPlayByCard(testId(30)));
    try testing.expectEqual(@as(?usize, null), state.findPlayByCard(testId(99)));
}

test "Play.wouldConflict detects conflicting height_override" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    const card_list = @import("../card_list.zig");
    const low = card_list.byName("low");
    const high = card_list.byName("high");

    // Create a play with low modifier
    var play = Play{ .action = testId(1) };
    const low_instance = try registry.create(low);
    try play.addModifier(low_instance.id, null);

    // high should conflict (different height)
    try testing.expect(play.wouldConflict(high, &registry));

    // low should not conflict (same height)
    try testing.expect(!play.wouldConflict(low, &registry));
}

test "Play.wouldConflict allows same height_override" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    const card_list = @import("../card_list.zig");
    const low = card_list.byName("low");

    // Create a play with low modifier
    var play = Play{ .action = testId(1) };
    const low_instance = try registry.create(low);
    try play.addModifier(low_instance.id, null);

    // Another low should not conflict
    try testing.expect(!play.wouldConflict(low, &registry));
}

test "Play.wouldConflict allows non-conflicting modifiers" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    const card_list = @import("../card_list.zig");
    // Use a modifier without height_override
    const feint = card_list.byName("feint");

    const play = Play{ .action = testId(1) };

    // Feint (no height_override) should not conflict
    try testing.expect(!play.wouldConflict(feint, &registry));
}

test "Play.wouldConflict returns false for empty modifier stack" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    const card_list = @import("../card_list.zig");
    const low = card_list.byName("low");

    const play = Play{ .action = testId(1) };
    // Empty modifier stack - any modifier should be allowed
    try testing.expect(!play.wouldConflict(low, &registry));
}

test "Timeline.canInsert allows non-overlapping same channel" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var timeline = Timeline{};
    const weapon_channels: cards.ChannelSet = .{ .weapon = true };

    // Insert first play at 0.0-0.2
    try timeline.insert(0.0, 0.2, .{ .action = testId(1) }, weapon_channels, &registry);

    // Should allow non-overlapping same channel at 0.3-0.5
    try testing.expect(timeline.canInsert(0.3, 0.5, weapon_channels, &registry));
}

test "Timeline.canInsert rejects overlapping same channel" {
    const card_list = @import("../card_list.zig");
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    // Register a real card with duration
    const slash = card_list.byName("slash");
    const slash_instance = try registry.create(slash);
    const duration = getPlayDuration(.{ .action = slash_instance.id }, &registry);

    var timeline = Timeline{};
    const weapon_channels: cards.ChannelSet = .{ .weapon = true };

    // Insert first play at 0.0 with the card's actual duration
    try timeline.insert(0.0, duration, .{ .action = slash_instance.id }, weapon_channels, &registry);

    // Should reject overlapping same channel at half-duration to 1.5x duration
    try testing.expect(!timeline.canInsert(duration / 2, duration * 1.5, weapon_channels, &registry));
}

test "Timeline.canInsert allows overlapping different channels" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var timeline = Timeline{};
    const weapon_channels: cards.ChannelSet = .{ .weapon = true };
    const footwork_channels: cards.ChannelSet = .{ .footwork = true };

    // Insert first play at 0.0-0.2 on weapon channel
    try timeline.insert(0.0, 0.2, .{ .action = testId(1) }, weapon_channels, &registry);

    // Should allow overlapping on different channel
    try testing.expect(timeline.canInsert(0.1, 0.3, footwork_channels, &registry));
}

test "Timeline.nextAvailableStart finds first gap" {
    const card_list = @import("../card_list.zig");
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    // Register a real card with duration
    const slash = card_list.byName("slash");
    const slash_instance = try registry.create(slash);
    const duration = getPlayDuration(.{ .action = slash_instance.id }, &registry);

    var timeline = Timeline{};
    const weapon_channels: cards.ChannelSet = .{ .weapon = true };

    // Insert play at 0.0 with the card's actual duration
    try timeline.insert(0.0, duration, .{ .action = slash_instance.id }, weapon_channels, &registry);

    // Should find the card's duration as next available start
    const next = timeline.nextAvailableStart(weapon_channels, 0.1, &registry);
    try testing.expect(next != null);
    try testing.expectApproxEqAbs(duration, next.?, 0.001);
}

test "Timeline.nextAvailableStart returns null when no space" {
    const card_list = @import("../card_list.zig");
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    // Register a real card with duration
    const slash = card_list.byName("slash");
    const slash_instance = try registry.create(slash);
    const card_duration = getPlayDuration(.{ .action = slash_instance.id }, &registry);

    var timeline = Timeline{};
    const weapon_channels: cards.ChannelSet = .{ .weapon = true };

    // Fill timeline by inserting cards until no space for another full-duration card
    var time: f32 = 0.0;
    while (time + card_duration <= 1.0) {
        try timeline.insert(time, time + card_duration, .{ .action = slash_instance.id }, weapon_channels, &registry);
        time += card_duration;
    }

    // Should return null when asking for the full card duration (not enough space)
    const remaining = 1.0 - time;
    const next = timeline.nextAvailableStart(weapon_channels, remaining + 0.1, &registry);
    try testing.expect(next == null);
}

test "Timeline.insert snaps time_start to granularity" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var timeline = Timeline{};
    const channels = cards.ChannelSet{};

    // Insert at 0.15 (should snap to 0.1)
    try timeline.insert(0.15, 0.25, .{ .action = testId(1) }, channels, &registry);

    try testing.expectApproxEqAbs(@as(f32, 0.1), timeline.slots()[0].time_start, 0.001);
}

test "TimeSlot.overlapsWith adjacent slots do not overlap" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    const slot = TimeSlot{
        .time_start = 0.0,
        .play = .{ .action = testId(1) },
    };

    // Adjacent slot (0.0-0.0 to 0.0-0.1) should not overlap
    // slot duration is 0 since card not in registry
    try testing.expect(!slot.overlapsWith(0.0, 0.1, &registry));
}

test "TimeSlot.overlapsWith exact same range overlaps" {
    const card_list = @import("../card_list.zig");
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    // Register a card with actual duration
    const slash = card_list.byName("slash");
    const slash_instance = try registry.create(slash);

    const slot = TimeSlot{
        .time_start = 0.0,
        .play = .{ .action = slash_instance.id },
    };

    const duration = slot.duration(&registry);
    // Same range should overlap
    try testing.expect(slot.overlapsWith(0.0, duration, &registry));
}

test "hasFootworkInTimeline returns false when empty" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var timeline = Timeline{};
    try testing.expect(!hasFootworkInTimeline(&timeline, &registry));
}

test "hasFootworkInTimeline returns true when footwork card present" {
    const card_list = @import("../card_list.zig");
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    // Create a footwork card (advance uses footwork channel)
    const advance = card_list.byName("advance");
    const advance_instance = try registry.create(advance);

    var timeline = Timeline{};
    const channels = cards.ChannelSet{ .footwork = true };
    try timeline.insert(0.0, 0.3, .{ .action = advance_instance.id }, channels, &registry);

    try testing.expect(hasFootworkInTimeline(&timeline, &registry));
}

test "hasFootworkInTimeline returns false when only weapon card present" {
    const card_list = @import("../card_list.zig");
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    // Create a weapon card (thrust uses weapon channel)
    const thrust = card_list.byName("thrust");
    const thrust_instance = try registry.create(thrust);

    var timeline = Timeline{};
    const channels = cards.ChannelSet{ .weapon = true };
    try timeline.insert(0.0, 0.5, .{ .action = thrust_instance.id }, channels, &registry);

    try testing.expect(!hasFootworkInTimeline(&timeline, &registry));
}
