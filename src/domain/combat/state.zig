//! Combat zone state management.
//!
//! Handles the transient card state during combat encounters:
//! draw pile, hand, discard, and exhaust zones.
//!
//! Note: "in_play" is a conceptual zone tracked by the Timeline, not a backing ArrayList.
//! Cards are moved to "in_play" when played, but storage is in the timeline's Play structs.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const world = @import("../world.zig");
const plays = @import("plays.zig");

/// Combat-specific zones (subset of cards.Zone for transient combat state).
pub const CombatZone = enum {
    draw,
    hand,
    in_play,
    discard,
    exhaust,
};

/// Transient combat state - created per encounter, holds draw/hand/discard cycle.
/// Card IDs reference World.action_registry.
///
/// Note: "in_play" cards are tracked by the Timeline, not here. The CombatZone.in_play
/// enum value exists for event semantics, but has no backing ArrayList.
pub const CombatState = struct {
    alloc: std.mem.Allocator,
    draw: std.ArrayList(entity.ID),
    hand: std.ArrayList(entity.ID),
    discard: std.ArrayList(entity.ID),
    exhaust: std.ArrayList(entity.ID),
    // Cooldowns for pool-based cards - keyed by MASTER id (techniques, maybe spells)
    cooldowns: std.AutoHashMap(entity.ID, u8),

    pub const ZoneError = error{NotFound};

    /// Result of creating a pool clone for play.
    pub const PoolCloneResult = struct {
        clone_id: entity.ID,
        source: plays.PlaySource,
    };

    pub fn init(alloc: std.mem.Allocator) !CombatState {
        return .{
            .alloc = alloc,
            .draw = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .hand = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .discard = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .exhaust = try std.ArrayList(entity.ID).initCapacity(alloc, 5),
            .cooldowns = std.AutoHashMap(entity.ID, u8).init(alloc),
        };
    }

    pub fn deinit(self: *CombatState) void {
        self.draw.deinit(self.alloc);
        self.hand.deinit(self.alloc);
        self.discard.deinit(self.alloc);
        self.exhaust.deinit(self.alloc);
        self.cooldowns.deinit();
    }

    pub fn clear(self: *CombatState) void {
        self.draw.clearRetainingCapacity();
        self.hand.clearRetainingCapacity();
        self.discard.clearRetainingCapacity();
        self.exhaust.clearRetainingCapacity();
        self.cooldowns.clearRetainingCapacity();
    }

    /// Get the ArrayList for a zone. Does not support .in_play (use timeline).
    fn zoneList(self: *CombatState, zone: CombatZone) *std.ArrayList(entity.ID) {
        return switch (zone) {
            .draw => &self.draw,
            .hand => &self.hand,
            .discard => &self.discard,
            .exhaust => &self.exhaust,
            .in_play => unreachable, // Timeline is source of truth for in-play cards
        };
    }

    /// Check if a card ID is in a specific zone.
    /// For .in_play, always returns false - check timeline for in-play status.
    pub fn isInZone(self: *const CombatState, id: entity.ID, zone: CombatZone) bool {
        // .in_play has no backing ArrayList - timeline tracks in-play cards
        if (zone == .in_play) return false;

        const list = switch (zone) {
            .draw => &self.draw,
            .hand => &self.hand,
            .discard => &self.discard,
            .exhaust => &self.exhaust,
            .in_play => unreachable,
        };
        for (list.items) |card_id| {
            if (card_id.eql(id)) return true;
        }
        return false;
    }

    /// Find index of card in zone, or null if not found.
    fn findIndex(list: *const std.ArrayList(entity.ID), id: entity.ID) ?usize {
        for (list.items, 0..) |card_id, i| {
            if (card_id.eql(id)) return i;
        }
        return null;
    }

    /// Move a card from one zone to another.
    /// .in_play is a virtual zone: moving TO it removes from source only,
    /// moving FROM it adds to destination only (timeline tracks the card).
    pub fn moveCard(self: *CombatState, id: entity.ID, from: CombatZone, to: CombatZone) !void {
        // Handle .in_play as virtual zone (timeline is source of truth)
        if (from == .in_play) {
            // Card coming from play - just add to destination
            try self.zoneList(to).append(self.alloc, id);
            return;
        }
        if (to == .in_play) {
            // Card going to play - just remove from source
            const from_list = self.zoneList(from);
            const idx = findIndex(from_list, id) orelse return ZoneError.NotFound;
            _ = from_list.orderedRemove(idx);
            return;
        }

        // Normal zone-to-zone movement
        const from_list = self.zoneList(from);
        const to_list = self.zoneList(to);
        const idx = findIndex(from_list, id) orelse return ZoneError.NotFound;
        _ = from_list.orderedRemove(idx);
        try to_list.append(self.alloc, id);
    }

    /// Fisher-Yates shuffle of the draw pile.
    pub fn shuffleDraw(self: *CombatState, rand: anytype) !void {
        const items = self.draw.items;
        var i = items.len;
        while (i > 1) {
            i -= 1;
            const r = try rand.drawRandom();
            const j: usize = @intFromFloat(r * @as(f32, @floatFromInt(i + 1)));
            std.mem.swap(entity.ID, &items[i], &items[j]);
        }
    }

    /// Populate discard pile from deck_cards (called at combat start).
    /// Cards start in discard to simplify shuffle logic: when draw is empty,
    /// move discard to draw and shuffle.
    pub fn populateFromDeckCards(self: *CombatState, deck_cards: []const entity.ID) !void {
        self.clear();
        for (deck_cards) |card_id| {
            try self.discard.append(self.alloc, card_id);
        }
    }

    /// Create an ephemeral clone of a pool card (always_available, spells_known).
    /// The clone gets a fresh ID while the master stays in the pool.
    /// Returns clone ID and source info for Play creation.
    pub fn createPoolClone(
        _: *CombatState,
        master_id: entity.ID,
        source_zone: plays.PlaySource.SourceZone,
        registry: *world.ActionRegistry,
    ) !PoolCloneResult {
        const clone = try registry.clone(master_id);
        return .{
            .clone_id = clone.id,
            .source = .{
                .master_id = master_id,
                .source_zone = source_zone,
            },
        };
    }

    /// Decrement all cooldowns by 1 (called at turn start)
    pub fn tickCooldowns(self: *CombatState) void {
        var iter = self.cooldowns.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* > 0) entry.value_ptr.* -= 1;
        }
    }

    /// Set cooldown for a pool card's master (turns until available again)
    pub fn setCooldown(self: *CombatState, master_id: entity.ID, turns: u8) !void {
        try self.cooldowns.put(master_id, turns);
    }
};
