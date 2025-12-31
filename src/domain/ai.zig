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

// AI strategy "interface"
pub const AIDirector = struct {
    ptr: *anyopaque,
    // agent: *Agent,
    // player: *Agent,

    playCardsFn: *const fn (ptr: *anyopaque, agent: *Agent, player: *Agent, events: *EventSystem) anyerror!void,

    // delegate to the supplied function
    pub fn playCards(self: *AIDirector, agent: *Agent, player: *Agent, events: *EventSystem) !void {
        return self.playCardsFn(self.ptr, agent, player, events);
    }
};

const AIError = error{
    InvalidResourceType,
};

pub const SimpleDeckAIDirector = struct {
    pub fn director(self: *SimpleDeckAIDirector) AIDirector {
        return AIDirector{
            .ptr = self,
            .playCardsFn = playCards,
        };
    }

    pub fn playCards(ptr: *anyopaque, agent: *Agent, player: *Agent, events: *EventSystem) !void {
        const self: *SimpleDeckAIDirector = @ptrCast(@alignCast(ptr));
        _ = .{ player, self };

        // check invariant: agent has a deck
        // switch (agent.cards) {
        //     .deck => {},
        //     else => return AIError.InvalidResourceType,
        // }
        var dk = &agent.cards.deck;

        var to_play: usize = 3;
        var hand_index: usize = 0;

        while (to_play > 0 and hand_index < dk.hand.items.len) : (hand_index += 1) {
            const card = dk.hand.items[hand_index];

            // TODO: ENSURE STAMINA COSTS ETC ARE CHECKED

            if (apply.canUseCard(card.template, agent)) {
                try dk.move(card.id, .hand, .in_play);

                // TODO: ensure events differentiate player and mob actions
                // TODO: ensure costs are deducted

                try events.push(e.Event{ .played_action_card = .{ .instance = card.id, .template = card.template.id } });
                // TODO Sink event
                to_play -= 1;
            }
        }
    }
};

pub const Director = union(enum) {
    player,
    ai: AIDirector,
};
