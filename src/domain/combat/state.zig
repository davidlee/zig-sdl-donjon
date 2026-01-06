//! Combat zone state management.
//!
//! Handles the transient card state during combat encounters:
//! draw pile, hand, in-play, discard, and exhaust zones.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const world = @import("../world.zig");

/// Combat-specific zones (subset of cards.Zone for transient combat state).
pub const CombatZone = enum {
    draw,
    hand,
    in_play,
    discard,
    exhaust,
};

/// Transient combat state - created per encounter, holds draw/hand/discard cycle.
/// Card IDs reference World.card_registry.
pub const CombatState = struct {
    alloc: std.mem.Allocator,
    draw: std.ArrayList(entity.ID),
    hand: std.ArrayList(entity.ID),
    discard: std.ArrayList(entity.ID),
    in_play: std.ArrayList(entity.ID),
    exhaust: std.ArrayList(entity.ID),
    // Source tracking: where did cards in in_play come from?
    // For pool cards, also tracks master_id for cooldown application.
    in_play_sources: std.AutoHashMap(entity.ID, InPlayInfo),
    // Cooldowns for pool-based cards - keyed by MASTER id (techniques, maybe spells)
    cooldowns: std.AutoHashMap(entity.ID, u8),

    pub const ZoneError = error{NotFound};
    pub const CardSource = enum { hand, always_available, spells_known, inventory, environment };

    /// Tracks where an in_play card came from and its master (for cloned pool cards).
    pub const InPlayInfo = struct {
        source: CardSource,
        /// For pool cards (always_available, spells_known): the master instance ID.
        /// Cooldowns are applied to this ID. Null for hand/inventory/environment cards.
        master_id: ?entity.ID = null,
    };

    pub fn init(alloc: std.mem.Allocator) !CombatState {
        return .{
            .alloc = alloc,
            .draw = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .hand = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .discard = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .in_play = try std.ArrayList(entity.ID).initCapacity(alloc, 8),
            .exhaust = try std.ArrayList(entity.ID).initCapacity(alloc, 5),
            .in_play_sources = std.AutoHashMap(entity.ID, InPlayInfo).init(alloc),
            .cooldowns = std.AutoHashMap(entity.ID, u8).init(alloc),
        };
    }

    pub fn deinit(self: *CombatState) void {
        self.draw.deinit(self.alloc);
        self.hand.deinit(self.alloc);
        self.discard.deinit(self.alloc);
        self.in_play.deinit(self.alloc);
        self.exhaust.deinit(self.alloc);
        self.in_play_sources.deinit();
        self.cooldowns.deinit();
    }

    pub fn clear(self: *CombatState) void {
        self.draw.clearRetainingCapacity();
        self.hand.clearRetainingCapacity();
        self.discard.clearRetainingCapacity();
        self.in_play.clearRetainingCapacity();
        self.exhaust.clearRetainingCapacity();
        self.in_play_sources.clearRetainingCapacity();
        self.cooldowns.clearRetainingCapacity();
    }

    /// Get the ArrayList for a zone.
    pub fn zoneList(self: *CombatState, zone: CombatZone) *std.ArrayList(entity.ID) {
        return switch (zone) {
            .draw => &self.draw,
            .hand => &self.hand,
            .in_play => &self.in_play,
            .discard => &self.discard,
            .exhaust => &self.exhaust,
        };
    }

    /// Check if a card ID is in a specific zone.
    pub fn isInZone(self: *const CombatState, id: entity.ID, zone: CombatZone) bool {
        const list = switch (zone) {
            .draw => &self.draw,
            .hand => &self.hand,
            .in_play => &self.in_play,
            .discard => &self.discard,
            .exhaust => &self.exhaust,
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
    pub fn moveCard(self: *CombatState, id: entity.ID, from: CombatZone, to: CombatZone) !void {
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

    /// Add card to in_play from a non-CombatZone source (always_available, spells_known, etc.)
    /// For pool sources, creates an ephemeral clone so the master stays in the pool.
    /// Returns the ID of the card now in in_play (clone ID for pool sources, original for others).
    pub fn addToInPlayFrom(
        self: *CombatState,
        master_id: entity.ID,
        source: CardSource,
        registry: *world.CardRegistry,
    ) !entity.ID {
        const is_pool_source = switch (source) {
            .always_available, .spells_known => true,
            .hand, .inventory, .environment => false,
        };

        if (is_pool_source) {
            // Clone the master - ephemeral instance gets fresh ID
            const clone = try registry.clone(master_id);
            try self.in_play.append(self.alloc, clone.id);
            try self.in_play_sources.put(clone.id, .{
                .source = source,
                .master_id = master_id,
            });
            return clone.id;
        } else {
            // Non-pool sources: use the original ID directly
            try self.in_play.append(self.alloc, master_id);
            try self.in_play_sources.put(master_id, .{
                .source = source,
                .master_id = null,
            });
            return master_id;
        }
    }

    /// Decrement all cooldowns by 1 (called at turn start)
    pub fn tickCooldowns(self: *CombatState) void {
        var iter = self.cooldowns.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* > 0) entry.value_ptr.* -= 1;
        }
    }

    /// Remove card from in_play, destroy ephemeral clones, return master_id for cooldown.
    /// Returns the master_id if this was a pool card (for cooldown application), null otherwise.
    pub fn removeFromInPlay(
        self: *CombatState,
        id: entity.ID,
        registry: *world.CardRegistry,
    ) !?entity.ID {
        const idx = findIndex(&self.in_play, id) orelse return ZoneError.NotFound;
        _ = self.in_play.orderedRemove(idx);

        const info = self.in_play_sources.get(id);
        _ = self.in_play_sources.remove(id);

        if (info) |i| {
            if (i.master_id) |master_id| {
                // This was a clone - destroy the ephemeral instance
                registry.destroy(id);
                return master_id;
            }
        }

        return null;
    }

    /// Set cooldown for a pool card's master (turns until available again)
    pub fn setCooldown(self: *CombatState, master_id: entity.ID, turns: u8) !void {
        try self.cooldowns.put(master_id, turns);
    }
};
