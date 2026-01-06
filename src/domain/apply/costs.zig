//! Cost application - finalize committed card costs after resolution.
//!
//! Handles the transition of reserved stamina to spent stamina,
//! and moves cards to their post-resolution zones (discard, exhaust, etc.).

const combat = @import("../combat.zig");
const events = @import("../events.zig");
const tick = @import("../tick.zig");

const EventSystem = events.EventSystem;
const Agent = combat.Agent;

/// Finalize costs for all committed actions after tick resolution.
/// - Converts committed stamina to spent
/// - Moves cards to appropriate zones (discard/exhaust for deck-based, cooldown for pool-based)
pub fn applyCommittedCosts(
    committed: []const tick.CommittedAction,
    event_system: *EventSystem,
) !void {
    for (committed) |action| {
        const card = action.card orelse continue;
        const agent = action.actor;
        const is_player = switch (agent.director) {
            .player => true,
            else => false,
        };
        const actor_meta: events.AgentMeta = .{ .id = agent.id, .player = is_player };

        // Finalize stamina commitment (current catches down to available)
        const stamina_cost = card.template.cost.stamina;
        agent.stamina.finalize();

        try event_system.push(.{
            .stamina_deducted = .{
                .agent_id = agent.id,
                .amount = stamina_cost,
                .new_value = agent.stamina.current,
            },
        });

        // Move card to appropriate zone after use
        const cs = agent.combat_state orelse continue;
        switch (agent.draw_style) {
            .shuffled_deck => {
                // Deck-based: move to discard or exhaust
                const dest_zone: combat.CombatZone = if (card.template.cost.exhausts)
                    .exhaust
                else
                    .discard;

                cs.moveCard(card.id, .in_play, dest_zone) catch continue;
                try event_system.push(.{
                    .card_moved = .{
                        .instance = card.id,
                        .from = .in_play,
                        .to = if (card.template.cost.exhausts) .exhaust else .discard,
                        .actor = actor_meta,
                    },
                });
            },
            .always_available, .scripted => {
                // TODO: implement cooldown tracking on CombatState
                // always_available cards don't move zones, just reset cooldown (stub)
                cs.moveCard(card.id, .in_play, .discard) catch continue;
            },
        }
    }
}
