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
    // agent: *Agent,
    // player: *Agent,

    playCardsFn: *const fn (ptr: *anyopaque, agent: *Agent, player: *Agent, events: *EventSystem) anyerror!void,

    // delegate to the supplied function
    pub fn playCards(self: *Director, agent: *Agent, player: *Agent, events: *EventSystem) !void {
        return self.playCardsFn(self.ptr, agent, player, events);
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

    pub fn playCards(ptr: *anyopaque, agent: *Agent, player: *Agent, events: *EventSystem) !void {
        _ = .{ ptr, agent, player, events };
    }
};

/// Just spams the first playable card whenever it can
/// requires a deck
pub const SimpleDeckDirector = struct {
    pub fn director(self: *SimpleDeckDirector) Director {
        return Director{
            .ptr = self,
            .playCardsFn = playCards,
        };
    }

    // TODO: ensure events differentiate player and mob actions
    pub fn playCards(ptr: *anyopaque, agent: *Agent, player: *Agent, events: *EventSystem) !void {
        const self: *SimpleDeckDirector = @ptrCast(@alignCast(ptr));
        _ = .{ player, self };

        const dk = &agent.cards.deck;
        var to_play: usize = 3;
        var hand_index: usize = 0;
        while (to_play > 0 and hand_index < dk.hand.items.len) : (hand_index += 1) {
            const card = dk.hand.items[hand_index];
            if (apply.isCardSelectionValid(agent, card)) {
                try apply.playValidCardReservingCosts(events, agent, card);
                try events.push(e.Event{ .played_action_card = .{ .instance = card.id, .template = card.template.id, .actor = .{ .id = agent.id, .player = false } } });
                to_play -= 1;
            }
        }
    }
};
