/// AI directors and behaviours for non-player agents.
///
/// Provides Director implementations that decide which cards to play for NPCs.
/// Does not own world state or presentation logic; callers pass in Agent/World
/// references when requesting AI actions.
const std = @import("std");
const lib = @import("infra");

const damage = @import("damage.zig");
const stats = @import("stats.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const e = @import("events.zig");
const world = @import("world.zig");
const random = @import("random.zig");
const entity = lib.entity;
const tick = @import("tick.zig");
const combat = @import("combat.zig");
const apply = @import("apply.zig");

const Event = e.Event;
const EventSystem = e.EventSystem;
const EventTag = std.meta.Tag(Event);
const World = world.World;
const Agent = combat.Agent;
const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Expression = cards.Expression;
const Technique = cards.Technique;

// convenience constructors for Agent

pub fn simple() combat.Director {
    var impl = SimpleDeckDirector{};
    return .{ .ai = impl.director() };
}

pub fn noop() combat.Director {
    var impl = NullDirector{};
    return .{ .ai = impl.director() };
}

const AIError = error{
    InvalidResourceType,
};

/// AI strategy "interface"
pub const Director = struct {
    ptr: *anyopaque,

    playCardsFn: *const fn (ptr: *anyopaque, agent: *Agent, w: *World) anyerror!void,

    pub fn playCards(self: *Director, agent: *Agent, w: *World) !void {
        return self.playCardsFn(self.ptr, agent, w);
    }
};

/// does nothing. maybe useful for tests.
pub const NullDirector = struct {
    pub fn director(self: *NullDirector) Director {
        return Director{
            .ptr = self,
            .playCardsFn = playCards,
        };
    }

    pub fn playCards(ptr: *anyopaque, agent: *Agent, w: *World) !void {
        _ = .{ ptr, agent, w };
    }
};

/// Just spams the first playable card whenever it can
/// requires combat_state (deck-based agent)
/// Create a Play in the timeline for a card that was just added to in_play.
/// Shared by AI directors - player uses CommandHandler.playActionCard instead.
fn createPlayForInPlayCard(
    agent: *Agent,
    in_play_id: entity.ID,
    target: ?entity.ID,
    w: *World,
) !void {
    const cs = agent.combat_state orelse return;
    const enc = w.encounter orelse return;
    const enc_state = enc.stateFor(agent.id) orelse return;

    // Look up source info for the card
    const source: ?combat.PlaySource = if (cs.in_play_sources.get(in_play_id)) |info| blk: {
        break :blk switch (info.source) {
            .always_available => .{
                .master_id = info.master_id orelse in_play_id,
                .source_zone = .always_available,
            },
            .spells_known => .{
                .master_id = info.master_id orelse in_play_id,
                .source_zone = .spells_known,
            },
            .hand, .inventory, .environment => null,
        };
    } else null;

    try enc_state.current.addPlay(.{
        .action = in_play_id,
        .target = target,
        .source = source,
        .added_in_phase = .selection,
    }, &w.card_registry);
}

pub const SimpleDeckDirector = struct {
    pub fn director(self: *SimpleDeckDirector) Director {
        return Director{
            .ptr = self,
            .playCardsFn = playCards,
        };
    }

    pub fn playCards(ptr: *anyopaque, agent: *Agent, w: *World) !void {
        _ = ptr;
        const cs = agent.combat_state orelse return;
        var to_play: usize = 3;
        var hand_index: usize = 0;
        while (to_play > 0 and hand_index < cs.hand.items.len) : (hand_index += 1) {
            const card_id = cs.hand.items[hand_index];
            const card = w.card_registry.get(card_id) orelse continue;
            if (apply.isCardSelectionValid(agent, card, w.encounter)) {
                const in_play_id = try apply.playValidCardReservingCosts(&w.events, agent, card, &w.card_registry, null);
                try createPlayForInPlayCard(agent, in_play_id, null, w);
                to_play -= 1;
            }
        }
    }
};

/// Randomly picks 2-3 cards from always_available to play.
/// For agents that use pool-based techniques instead of decks.
pub const PoolDirector = struct {
    pub fn director(self: *PoolDirector) Director {
        return Director{
            .ptr = self,
            .playCardsFn = playCards,
        };
    }

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

            // Check if playable (not on cooldown, meets requirements)
            if (apply.isCardSelectionValid(agent, card, w.encounter)) {
                const in_play_id = try apply.playValidCardReservingCosts(&w.events, agent, card, &w.card_registry, null);
                try createPlayForInPlayCard(agent, in_play_id, null, w);
                played += 1;
            }
        }
    }
};

pub fn pool() combat.Director {
    var impl = PoolDirector{};
    return .{ .ai = impl.director() };
}
