// CombatLog - presentation-layer combat event log
//
// Formats domain events into human-readable strings and manages scroll state.
// Entirely presentation concern - domain layer is unaware of this.

const std = @import("std");
const World = @import("../domain/world.zig").World;
const events = @import("../domain/events.zig");
const Event = events.Event;
const entity = @import("infra").entity;
const Color = @import("sdl3").pixels.Color;

pub const Entry = struct {
    text: []const u8,
    color: Color,
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
    scroll_offset: usize = 0,

    const max_entries = 500;
    pub const visible_lines = 40;

    pub fn init(alloc: std.mem.Allocator) !CombatLog {
        return .{
            .alloc = alloc,
            .entries = try std.ArrayList(Entry).initCapacity(alloc, 64),
        };
    }

    pub fn deinit(self: *CombatLog) void {
        for (self.entries.items) |entry| {
            self.alloc.free(entry.text);
        }
        self.entries.deinit(self.alloc);
    }

    pub fn append(self: *CombatLog, entry: Entry) !void {
        // Evict oldest if at capacity
        if (self.entries.items.len >= max_entries) {
            const removed = self.entries.orderedRemove(0);
            self.alloc.free(removed.text);
            // Adjust scroll if we were scrolled
            if (self.scroll_offset > 0) {
                self.scroll_offset -= 1;
            }
        }
        try self.entries.append(self.alloc, entry);
    }

    pub fn scrollUp(self: *CombatLog, lines: usize) void {
        self.scroll_offset = @min(self.scroll_offset + lines, self.maxScroll());
    }

    pub fn scrollDown(self: *CombatLog, lines: usize) void {
        self.scroll_offset -|= lines;
    }

    fn maxScroll(self: *const CombatLog) usize {
        if (self.entries.items.len <= visible_lines) return 0;
        return self.entries.items.len - visible_lines;
    }

    /// Returns slice of visible entries (most recent at bottom)
    pub fn visibleEntries(self: *const CombatLog) []const Entry {
        const len = self.entries.items.len;
        if (len == 0) return &.{};

        const visible_count = @min(len, visible_lines);
        // scroll_offset=0 means viewing the most recent entries
        // higher offset means viewing older entries
        const end = len - self.scroll_offset;
        const start = end -| visible_count;

        return self.entries.items[start..end];
    }
};

/// Format a domain event into a log entry with color.
/// Returns null for events that shouldn't be logged.
pub fn format(event: Event, world: *const World, alloc: std.mem.Allocator) !?Entry {
    return switch (event) {
        .played_action_card => |e| .{
            .text = try std.fmt.allocPrint(alloc, "{s}: played card", .{actorName(e.actor.player)}),
            .color = if (e.actor.player) colors.player_action else colors.enemy_action,
        },

        .card_moved => |e| .{
            .text = try std.fmt.allocPrint(alloc, "{s}: {s} → {s}", .{
                actorName(e.actor.player),
                @tagName(e.from),
                @tagName(e.to),
            }),
            .color = if (e.actor.player) colors.player_action else colors.enemy_action,
        },

        .wound_inflicted => |e| .{
            .text = try std.fmt.allocPrint(alloc, "Wound: {s} ({s})", .{
                agentName(e.agent_id, world),
                @tagName(e.wound.kind),
            }),
            .color = colors.wound,
        },

        .body_part_severed => |e| .{
            .text = try std.fmt.allocPrint(alloc, "SEVERED: {s}", .{agentName(e.agent_id, world)}),
            .color = colors.critical,
        },

        .hit_major_artery => |e| .{
            .text = try std.fmt.allocPrint(alloc, "ARTERY HIT: {s}", .{agentName(e.agent_id, world)}),
            .color = colors.critical,
        },

        .armour_deflected => |e| .{
            .text = try std.fmt.allocPrint(alloc, "Deflected: {s}", .{agentName(e.agent_id, world)}),
            .color = colors.armour,
        },

        .armour_absorbed => |e| .{
            .text = try std.fmt.allocPrint(alloc, "Absorbed: {s} (-{d:.0})", .{
                agentName(e.agent_id, world),
                e.damage_reduced,
            }),
            .color = colors.armour,
        },

        .armour_layer_destroyed => |e| .{
            .text = try std.fmt.allocPrint(alloc, "Armour destroyed: {s}", .{agentName(e.agent_id, world)}),
            .color = colors.wound,
        },

        .attack_found_gap => |e| .{
            .text = try std.fmt.allocPrint(alloc, "Gap found: {s}", .{agentName(e.agent_id, world)}),
            .color = colors.wound,
        },

        .technique_resolved => |e| .{
            .text = try std.fmt.allocPrint(alloc, "{s} vs {s}: {s}", .{
                agentName(e.attacker_id, world),
                agentName(e.defender_id, world),
                @tagName(e.outcome),
            }),
            .color = colors.default,
        },

        .advantage_changed => |e| {
            const delta = e.new_value - e.old_value;
            const sign: []const u8 = if (delta >= 0) "+" else "";
            return .{
                .text = try std.fmt.allocPrint(alloc, "{s}: {s} {s}{d:.1}", .{
                    agentName(e.agent_id, world),
                    @tagName(e.axis),
                    sign,
                    delta,
                }),
                .color = colors.advantage,
            };
        },

        .stamina_deducted => |e| .{
            .text = try std.fmt.allocPrint(alloc, "{s}: stamina -{d:.1}", .{
                agentName(e.agent_id, world),
                e.amount,
            }),
            .color = colors.default,
        },

        .card_cost_reserved => |e| .{
            .text = try std.fmt.allocPrint(alloc, "{s}: reserved {d:.1} stamina", .{
                actorName(e.actor.player),
                e.stamina,
            }),
            .color = if (e.actor.player) colors.player_action else colors.enemy_action,
        },

        .card_cost_returned => |e| .{
            .text = try std.fmt.allocPrint(alloc, "{s}: returned {d:.1} stamina", .{
                actorName(e.actor.player),
                e.stamina,
            }),
            .color = if (e.actor.player) colors.player_action else colors.enemy_action,
        },

        .mob_died => |id| .{
            .text = try std.fmt.allocPrint(alloc, "DIED: {s}", .{agentName(id, world)}),
            .color = colors.critical,
        },

        .game_state_transitioned_to => |state| .{
            .text = try std.fmt.allocPrint(alloc, "-- {s} --", .{@tagName(state)}),
            .color = colors.system,
        },

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
    const player_id = world.player.id;
    return if (player_id.index == id.index and player_id.generation == id.generation) "You" else "Enemy";
}

// Tests
const testing = std.testing;

test "CombatLog append and visible entries" {
    var log = try CombatLog.init(testing.allocator);
    defer log.deinit();

    try log.append(.{
        .text = try testing.allocator.dupe(u8, "Test message 1"),
        .color = colors.default,
    });
    try log.append(.{
        .text = try testing.allocator.dupe(u8, "Test message 2"),
        .color = colors.wound,
    });

    const entries = log.visibleEntries();
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("Test message 1", entries[0].text);
    try testing.expectEqualStrings("Test message 2", entries[1].text);
}

test "CombatLog scroll bounds" {
    var log = try CombatLog.init(testing.allocator);
    defer log.deinit();

    // Add fewer entries than visible_lines
    for (0..5) |i| {
        try log.append(.{
            .text = try std.fmt.allocPrint(testing.allocator, "Message {d}", .{i}),
            .color = colors.default,
        });
    }

    // maxScroll should be 0 when entries < visible_lines
    try testing.expectEqual(@as(usize, 0), log.maxScroll());

    // scrollUp should clamp to maxScroll
    log.scrollUp(10);
    try testing.expectEqual(@as(usize, 0), log.scroll_offset);

    // scrollDown from 0 should stay at 0 (saturating)
    log.scrollDown(10);
    try testing.expectEqual(@as(usize, 0), log.scroll_offset);
}

test "CombatLog evicts oldest when at capacity" {
    var log = try CombatLog.init(testing.allocator);
    defer log.deinit();

    // Fill to capacity
    for (0..CombatLog.max_entries) |i| {
        try log.append(.{
            .text = try std.fmt.allocPrint(testing.allocator, "Message {d}", .{i}),
            .color = colors.default,
        });
    }

    try testing.expectEqual(CombatLog.max_entries, log.entries.items.len);

    // Add one more - should evict oldest
    try log.append(.{
        .text = try testing.allocator.dupe(u8, "New message"),
        .color = colors.default,
    });

    try testing.expectEqual(CombatLog.max_entries, log.entries.items.len);

    // First entry should now be "Message 1" (0 was evicted)
    try testing.expectEqualStrings("Message 1", log.entries.items[0].text);
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
