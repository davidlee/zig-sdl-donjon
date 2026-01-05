// CombatLog - presentation-layer combat event log
//
// Formats domain events into human-readable spans with color.
// Scroll state lives in ViewState, not here.
// Entirely presentation concern - domain layer is unaware of this.

const std = @import("std");
const World = @import("../domain/world.zig").World;
const events = @import("../domain/events.zig");
const Event = events.Event;
const entity = @import("infra").entity;
const Color = @import("sdl3").pixels.Color;

pub const Span = struct {
    text: []const u8,
    color: Color,
};

pub const Entry = struct {
    spans: []const Span, // owned, freed on eviction
};

// Color palette for log entries
pub const colors = struct {
    pub const default: Color = .{ .r = 180, .g = 180, .b = 180, .a = 255 };
    pub const player_action: Color = .{ .r = 100, .g = 200, .b = 255, .a = 255 }; // blue
    pub const enemy_action: Color = .{ .r = 255, .g = 180, .b = 100, .a = 255 }; // orange
    pub const wound: Color = .{ .r = 255, .g = 100, .b = 100, .a = 255 }; // red
    pub const critical: Color = .{ .r = 255, .g = 50, .b = 50, .a = 255 }; // bright red
    pub const armour: Color = .{ .r = 150, .g = 150, .b = 200, .a = 255 }; // steel blue
    pub const advantage: Color = .{ .r = 200, .g = 200, .b = 100, .a = 255 }; // yellow
    pub const system: Color = .{ .r = 120, .g = 120, .b = 120, .a = 255 }; // dim gray
};

pub const CombatLog = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub const max_entries = 500;
    pub const visible_lines = 40;

    pub fn init(alloc: std.mem.Allocator) !CombatLog {
        return .{
            .alloc = alloc,
            .entries = try std.ArrayList(Entry).initCapacity(alloc, 64),
        };
    }

    pub fn deinit(self: *CombatLog) void {
        for (self.entries.items) |entry| {
            self.freeEntry(entry);
        }
        self.entries.deinit(self.alloc);
    }

    pub fn append(self: *CombatLog, entry: Entry) !void {
        // Evict oldest if at capacity
        if (self.entries.items.len >= max_entries) {
            const removed = self.entries.orderedRemove(0);
            self.freeEntry(removed);
        }
        try self.entries.append(self.alloc, entry);
    }

    fn freeEntry(self: *CombatLog, entry: Entry) void {
        for (entry.spans) |span| {
            self.alloc.free(span.text);
        }
        self.alloc.free(entry.spans);
    }

    pub fn maxScroll(self: *const CombatLog, visible_count: usize) usize {
        if (self.entries.items.len <= visible_count) return 0;
        return self.entries.items.len - visible_count;
    }

    pub fn entryCount(self: *const CombatLog) usize {
        return self.entries.items.len;
    }

    /// Returns slice of visible entries (most recent at bottom)
    pub fn visibleEntries(self: *const CombatLog, scroll_offset: usize, visible_count: usize) []const Entry {
        const len = self.entries.items.len;
        if (len == 0) return &.{};

        const actual_visible = @min(len, visible_count);
        // scroll_offset=0 means viewing the most recent entries
        // higher offset means viewing older entries
        const end = len -| scroll_offset;
        const start = end -| actual_visible;

        return self.entries.items[start..end];
    }
};

/// Create a single-span entry (most common case)
fn singleSpan(alloc: std.mem.Allocator, text: []const u8, color: Color) !Entry {
    const spans = try alloc.alloc(Span, 1);
    spans[0] = .{ .text = text, .color = color };
    return .{ .spans = spans };
}

/// Format a domain event into a log entry with color.
/// Returns null for events that shouldn't be logged.
pub fn format(event: Event, world: *const World, alloc: std.mem.Allocator) !?Entry {
    return switch (event) {
        .played_action_card => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "{s}: played card", .{actorName(e.actor.player)}),
            if (e.actor.player) colors.player_action else colors.enemy_action,
        ),

        .card_moved => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "{s}: {s} → {s}", .{
                actorName(e.actor.player),
                @tagName(e.from),
                @tagName(e.to),
            }),
            if (e.actor.player) colors.player_action else colors.enemy_action,
        ),

        .card_cancelled => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "{s}: cancelled card", .{actorName(e.actor.player)}),
            if (e.actor.player) colors.player_action else colors.enemy_action,
        ),

        .wound_inflicted => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "Wound: {s} ({s})", .{
                agentName(e.agent_id, world),
                @tagName(e.wound.kind),
            }),
            colors.wound,
        ),

        .body_part_severed => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "SEVERED: {s}", .{agentName(e.agent_id, world)}),
            colors.critical,
        ),

        .hit_major_artery => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "ARTERY HIT: {s}", .{agentName(e.agent_id, world)}),
            colors.critical,
        ),

        .armour_deflected => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "Deflected: {s}", .{agentName(e.agent_id, world)}),
            colors.armour,
        ),

        .armour_absorbed => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "Absorbed: {s} (-{d:.0})", .{
                agentName(e.agent_id, world),
                e.damage_reduced,
            }),
            colors.armour,
        ),

        .armour_layer_destroyed => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "Armour destroyed: {s}", .{agentName(e.agent_id, world)}),
            colors.wound,
        ),

        .attack_found_gap => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "Gap found: {s}", .{agentName(e.agent_id, world)}),
            colors.wound,
        ),

        .technique_resolved => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "{s} vs {s}: {s}", .{
                agentName(e.attacker_id, world),
                agentName(e.defender_id, world),
                @tagName(e.outcome),
            }),
            colors.default,
        ),

        .advantage_changed => |e| {
            const delta = e.new_value - e.old_value;
            const sign: []const u8 = if (delta >= 0) "+" else "";
            return try singleSpan(
                alloc,
                try std.fmt.allocPrint(alloc, "{s}: {s} {s}{d:.1}", .{
                    agentName(e.agent_id, world),
                    @tagName(e.axis),
                    sign,
                    delta,
                }),
                colors.advantage,
            );
        },

        .stamina_deducted => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "{s}: stamina -{d:.1}", .{
                agentName(e.agent_id, world),
                e.amount,
            }),
            colors.default,
        ),

        .card_cost_reserved => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "{s}: reserved {d:.1} stamina", .{
                actorName(e.actor.player),
                e.stamina,
            }),
            if (e.actor.player) colors.player_action else colors.enemy_action,
        ),

        .card_cost_returned => |e| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "{s}: returned {d:.1} stamina", .{
                actorName(e.actor.player),
                e.stamina,
            }),
            if (e.actor.player) colors.player_action else colors.enemy_action,
        ),

        .mob_died => |id| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "DIED: {s}", .{agentName(id, world)}),
            colors.critical,
        ),

        .game_state_transitioned_to => |state| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "-- {s} --", .{@tagName(state)}),
            colors.system,
        ),

        .combat_ended => |outcome| try singleSpan(
            alloc,
            try std.fmt.allocPrint(alloc, "=== COMBAT {s} ===", .{@tagName(outcome)}),
            if (outcome == .victory) colors.player_action else colors.critical,
        ),

        // Events not worth logging
        .entity_died,
        .played_reaction,
        .equipped_item,
        .unequipped_item,
        .equipped_spell,
        .unequipped_spell,
        .equipped_passive,
        .unequipped_passive,
        .draw_random,
        .play_sound,
        .player_turn_ended,
        .player_committed,
        .tick_ended,
        .cooldown_applied,
        => null,
    };
}

fn actorName(is_player: bool) []const u8 {
    return if (is_player) "You" else "Enemy";
}

fn agentName(id: entity.ID, world: *const World) []const u8 {
    return if (world.player.id.eql(id)) "You" else "Enemy";
}

// Tests
const testing = std.testing;

/// Helper to create a test entry with a single span (dupes static text)
fn testEntryStatic(alloc: std.mem.Allocator, text: []const u8, color: Color) !Entry {
    return try singleSpan(alloc, try alloc.dupe(u8, text), color);
}

/// Helper to create a test entry with already-allocated text (takes ownership)
fn testEntryOwned(alloc: std.mem.Allocator, text: []const u8, color: Color) !Entry {
    return try singleSpan(alloc, text, color);
}

test "CombatLog append and visible entries" {
    var log = try CombatLog.init(testing.allocator);
    defer log.deinit();

    try log.append(try testEntryStatic(testing.allocator, "Test message 1", colors.default));
    try log.append(try testEntryStatic(testing.allocator, "Test message 2", colors.wound));

    const entries = log.visibleEntries(0, 40);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("Test message 1", entries[0].spans[0].text);
    try testing.expectEqualStrings("Test message 2", entries[1].spans[0].text);
}

test "CombatLog maxScroll" {
    var log = try CombatLog.init(testing.allocator);
    defer log.deinit();

    // Add fewer entries than visible_lines
    for (0..5) |i| {
        try log.append(try testEntryOwned(
            testing.allocator,
            try std.fmt.allocPrint(testing.allocator, "Message {d}", .{i}),
            colors.default,
        ));
    }

    // maxScroll should be 0 when entries < visible_count
    try testing.expectEqual(@as(usize, 0), log.maxScroll(40));
}

test "CombatLog visibleEntries with scroll offset" {
    var log = try CombatLog.init(testing.allocator);
    defer log.deinit();

    // Add more entries than visible_count
    for (0..50) |i| {
        try log.append(try testEntryOwned(
            testing.allocator,
            try std.fmt.allocPrint(testing.allocator, "Message {d}", .{i}),
            colors.default,
        ));
    }

    // scroll_offset=0 shows most recent entries (10-49)
    const recent = log.visibleEntries(0, 40);
    try testing.expectEqual(@as(usize, 40), recent.len);
    try testing.expectEqualStrings("Message 10", recent[0].spans[0].text);
    try testing.expectEqualStrings("Message 49", recent[39].spans[0].text);

    // scroll_offset=10 shows older entries (0-39)
    const older = log.visibleEntries(10, 40);
    try testing.expectEqual(@as(usize, 40), older.len);
    try testing.expectEqualStrings("Message 0", older[0].spans[0].text);
    try testing.expectEqualStrings("Message 39", older[39].spans[0].text);
}

test "CombatLog evicts oldest when at capacity" {
    var log = try CombatLog.init(testing.allocator);
    defer log.deinit();

    // Fill to capacity
    for (0..CombatLog.max_entries) |i| {
        try log.append(try testEntryOwned(
            testing.allocator,
            try std.fmt.allocPrint(testing.allocator, "Message {d}", .{i}),
            colors.default,
        ));
    }

    try testing.expectEqual(CombatLog.max_entries, log.entries.items.len);

    // Add one more - should evict oldest
    try log.append(try testEntryStatic(testing.allocator, "New message", colors.default));

    try testing.expectEqual(CombatLog.max_entries, log.entries.items.len);

    // First entry should now be "Message 1" (0 was evicted)
    try testing.expectEqualStrings("Message 1", log.entries.items[0].spans[0].text);
}

test "format returns null for ignored events" {
    const event = Event{ .tick_ended = {} };
    const result = try format(event, undefined, testing.allocator);
    try testing.expect(result == null);
}

test "actorName returns correct strings" {
    try testing.expectEqualStrings("You", actorName(true));
    try testing.expectEqualStrings("Enemy", actorName(false));
}
