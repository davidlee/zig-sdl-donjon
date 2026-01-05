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
const body = @import("../domain/body.zig");
const damage = @import("../domain/damage.zig");

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
        .wound_inflicted => |e| try singleSpan(
            alloc,
            try formatWoundNarrative(alloc, e.agent_id, &e.wound, e.part_tag, e.part_side, world),
            colors.wound,
        ),

        .body_part_severed => |e| try singleSpan(
            alloc,
            try formatSevered(alloc, e.agent_id, e.part_tag, e.part_side, world),
            colors.critical,
        ),

        .hit_major_artery => |e| try singleSpan(
            alloc,
            try formatArteryHit(alloc, e.agent_id, e.part_tag, e.part_side, world),
            colors.critical,
        ),

        .armour_deflected => |e| try singleSpan(
            alloc,
            try formatArmourDeflected(alloc, e.agent_id, e.part_tag, e.part_side, world),
            colors.armour,
        ),

        .armour_absorbed => |e| try singleSpan(
            alloc,
            try formatArmourAbsorbed(alloc, e.agent_id, e.part_tag, e.part_side, e.damage_reduced, world),
            colors.armour,
        ),

        .armour_layer_destroyed => |e| try singleSpan(
            alloc,
            try formatArmourDestroyed(alloc, e.agent_id, e.part_tag, e.part_side, world),
            colors.wound,
        ),

        .attack_found_gap => |e| try singleSpan(
            alloc,
            try formatGapFound(alloc, e.agent_id, e.part_tag, e.part_side, world),
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
        .played_action_card,
        .card_moved,
        .card_cancelled,
        .card_cost_reserved,
        .card_cost_returned,
        .stamina_deducted,
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

// ============================================================================
// Narrative Formatting Helpers
// ============================================================================

/// Format body part tag to readable name
fn partTagName(tag: body.PartTag) []const u8 {
    return switch (tag) {
        .head => "head",
        .eye => "eye",
        .nose => "nose",
        .ear => "ear",
        .neck => "neck",
        .torso => "torso",
        .abdomen => "gut",
        .shoulder => "shoulder",
        .groin => "groin",
        .arm => "upper arm",
        .elbow => "elbow",
        .forearm => "forearm",
        .wrist => "wrist",
        .hand => "hand",
        .finger => "finger",
        .thumb => "thumb",
        .thigh => "thigh",
        .knee => "knee",
        .shin => "shin",
        .ankle => "ankle",
        .foot => "foot",
        .toe => "toe",
        .brain => "brain",
        .heart => "heart",
        .lung => "lung",
        .stomach => "stomach",
        .liver => "liver",
        .intestine => "guts",
        .tongue => "tongue",
        .trachea => "throat",
        .spleen => "spleen",
    };
}

/// Format side prefix (empty for center/none)
fn sidePrefix(side: body.Side) []const u8 {
    return switch (side) {
        .left => "left ",
        .right => "right ",
        .center, .none => "",
    };
}

/// Get possessive form for agent
fn possessive(id: entity.ID, world: *const World) []const u8 {
    return if (world.player.id.eql(id)) "your" else "the enemy's";
}

/// Action verb based on damage kind (past tense)
fn damageVerb(kind: damage.Kind) []const u8 {
    return switch (kind) {
        .slash => "cuts",
        .pierce => "pierces",
        .bludgeon => "smashes",
        .crush => "crushes",
        .shatter => "shatters",
        .fire => "burns",
        .frost => "freezes",
        .lightning => "jolts",
        .corrosion => "corrodes",
        else => "strikes",
    };
}

/// Deeper penetration verb based on damage kind
fn deepVerb(kind: damage.Kind) []const u8 {
    return switch (kind) {
        .slash => "bites into",
        .pierce => "drives deep into",
        .bludgeon => "crunches",
        .crush => "compresses",
        else => "reaches",
    };
}

/// Tissue layer name for narrative
fn layerName(layer: body.TissueLayer) []const u8 {
    return switch (layer) {
        .skin => "skin",
        .fat => "flesh",
        .muscle => "muscle",
        .tendon => "sinew",
        .nerve => "nerves",
        .bone => "bone",
        .cartilage => "cartilage",
        .organ => "organs",
    };
}

/// Severity descriptor - how bad is the damage?
fn severityWord(sev: body.Severity) []const u8 {
    return switch (sev) {
        .none => "grazes",
        .minor => "nicks",
        .inhibited => "tears",
        .disabled => "ruins",
        .broken => "shatters",
        .missing => "destroys",
    };
}

/// Format a wound into a narrative description
fn formatWoundNarrative(
    alloc: std.mem.Allocator,
    agent_id: entity.ID,
    wound: *const body.Wound,
    tag: body.PartTag,
    side: body.Side,
    world: *const World,
) ![]const u8 {
    const worst = wound.worstSeverity();
    const deepest = wound.deepestLayer();
    const poss = possessive(agent_id, world);
    const side_str = sidePrefix(side);
    const part = partTagName(tag);

    // Minor wounds - quick description
    if (@intFromEnum(worst) <= @intFromEnum(body.Severity.minor)) {
        return std.fmt.allocPrint(alloc, "The blade {s} {s} {s}{s}", .{
            severityWord(worst),
            poss,
            side_str,
            part,
        });
    }

    // Moderate wounds - mention penetration
    if (@intFromEnum(worst) <= @intFromEnum(body.Severity.inhibited)) {
        const verb = damageVerb(wound.kind);
        if (deepest) |layer| {
            return std.fmt.allocPrint(alloc, "The strike {s} through to the {s} of {s} {s}{s}", .{
                verb,
                layerName(layer),
                poss,
                side_str,
                part,
            });
        }
        return std.fmt.allocPrint(alloc, "The strike {s} {s} {s}{s}", .{
            verb,
            poss,
            side_str,
            part,
        });
    }

    // Severe wounds - visceral detail
    if (@intFromEnum(worst) <= @intFromEnum(body.Severity.disabled)) {
        const verb = deepVerb(wound.kind);
        if (deepest) |layer| {
            return std.fmt.allocPrint(alloc, "The blow {s} {s} {s}{s}, {s} the {s}", .{
                verb,
                poss,
                side_str,
                part,
                severityWord(worst),
                layerName(layer),
            });
        }
        return std.fmt.allocPrint(alloc, "The blow {s} {s} {s}{s}", .{
            verb,
            poss,
            side_str,
            part,
        });
    }

    // Catastrophic wounds
    if (deepest) |layer| {
        return std.fmt.allocPrint(alloc, "{s} {s}{s} is mangled - {s} {s}!", .{
            poss,
            side_str,
            part,
            layerName(layer),
            severityWord(worst),
        });
    }
    return std.fmt.allocPrint(alloc, "{s} {s}{s} is mangled beyond recognition!", .{
        poss,
        side_str,
        part,
    });
}

/// Format severing event
fn formatSevered(
    alloc: std.mem.Allocator,
    agent_id: entity.ID,
    tag: body.PartTag,
    side: body.Side,
    world: *const World,
) ![]const u8 {
    const poss = possessive(agent_id, world);
    const side_str = sidePrefix(side);
    const part = partTagName(tag);

    // Vary message by body part
    return switch (tag) {
        .finger, .thumb, .toe => std.fmt.allocPrint(alloc, "{s} {s}{s} goes flying!", .{
            poss,
            side_str,
            part,
        }),
        .hand, .foot => std.fmt.allocPrint(alloc, "{s} {s}{s} is hewn clean off!", .{
            poss,
            side_str,
            part,
        }),
        .arm, .forearm => std.fmt.allocPrint(alloc, "{s} {s}{s} is severed at the joint!", .{
            poss,
            side_str,
            part,
        }),
        .head => std.fmt.allocPrint(alloc, "{s} head parts company with {s} shoulders!", .{
            poss,
            if (world.player.id.eql(agent_id)) "your" else "their",
        }),
        .ear, .nose => std.fmt.allocPrint(alloc, "{s} {s} is sliced clean off!", .{
            poss,
            part,
        }),
        else => std.fmt.allocPrint(alloc, "{s} {s}{s} is severed!", .{
            poss,
            side_str,
            part,
        }),
    };
}

/// Format artery hit
fn formatArteryHit(
    alloc: std.mem.Allocator,
    agent_id: entity.ID,
    tag: body.PartTag,
    side: body.Side,
    world: *const World,
) ![]const u8 {
    const poss = possessive(agent_id, world);
    const side_str = sidePrefix(side);
    const part = partTagName(tag);

    return switch (tag) {
        .neck => std.fmt.allocPrint(alloc, "Blood spurts from {s} neck - the jugular is opened!", .{poss}),
        .thigh => std.fmt.allocPrint(alloc, "The femoral artery in {s} {s}{s} is severed - blood gushes!", .{
            poss,
            side_str,
            part,
        }),
        .shoulder => std.fmt.allocPrint(alloc, "A deep wound opens the artery in {s} {s}armpit!", .{
            poss,
            side_str,
        }),
        .groin => std.fmt.allocPrint(alloc, "A vicious blow opens {s} femoral artery!", .{poss}),
        else => std.fmt.allocPrint(alloc, "Blood pumps from a major vessel in {s} {s}{s}!", .{
            poss,
            side_str,
            part,
        }),
    };
}

/// Format armour deflection
fn formatArmourDeflected(
    alloc: std.mem.Allocator,
    agent_id: entity.ID,
    tag: body.PartTag,
    side: body.Side,
    world: *const World,
) ![]const u8 {
    const poss = possessive(agent_id, world);
    const side_str = sidePrefix(side);
    const part = partTagName(tag);

    return std.fmt.allocPrint(alloc, "Armour on {s} {s}{s} deflects the blow", .{
        poss,
        side_str,
        part,
    });
}

/// Format armour absorption
fn formatArmourAbsorbed(
    alloc: std.mem.Allocator,
    agent_id: entity.ID,
    tag: body.PartTag,
    side: body.Side,
    dmg_reduced: f32,
    world: *const World,
) ![]const u8 {
    const poss = possessive(agent_id, world);
    const side_str = sidePrefix(side);
    const part = partTagName(tag);

    if (dmg_reduced > 1.5) {
        return std.fmt.allocPrint(alloc, "Armour absorbs the brunt of the strike to {s} {s}{s}", .{
            poss,
            side_str,
            part,
        });
    }
    return std.fmt.allocPrint(alloc, "Armour on {s} {s}{s} softens the blow", .{
        poss,
        side_str,
        part,
    });
}

/// Format gap found in armour
fn formatGapFound(
    alloc: std.mem.Allocator,
    agent_id: entity.ID,
    tag: body.PartTag,
    side: body.Side,
    world: *const World,
) ![]const u8 {
    const poss = possessive(agent_id, world);
    const side_str = sidePrefix(side);
    const part = partTagName(tag);

    return std.fmt.allocPrint(alloc, "The strike finds a gap in {s} armour at the {s}{s}!", .{
        poss,
        side_str,
        part,
    });
}

/// Format armour destruction
fn formatArmourDestroyed(
    alloc: std.mem.Allocator,
    agent_id: entity.ID,
    tag: body.PartTag,
    side: body.Side,
    world: *const World,
) ![]const u8 {
    const poss = possessive(agent_id, world);
    const side_str = sidePrefix(side);
    const part = partTagName(tag);

    return std.fmt.allocPrint(alloc, "Armour protecting {s} {s}{s} is destroyed!", .{
        poss,
        side_str,
        part,
    });
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
