//! Cost application - finalize committed card costs after resolution.
//!
//! Handles the transition of reserved stamina to spent stamina,
//! and moves cards to their post-resolution zones (discard, exhaust, etc.).

const cards = @import("../cards.zig");
const combat = @import("../combat.zig");
const events = @import("../events.zig");
const tick = @import("../tick.zig");
const world = @import("../world.zig");

const EventSystem = events.EventSystem;
const Agent = combat.Agent;
const CardRegistry = world.CardRegistry;

/// Finalize costs for all committed actions after tick resolution.
/// - Converts committed stamina to spent
/// - Moves cards to appropriate zones based on play.source:
///   - null (hand card): move to discard or exhaust
///   - Some (pool clone): destroy the clone
pub fn applyCommittedCosts(
    committed: []const tick.CommittedAction,
    event_system: *EventSystem,
    registry: *CardRegistry,
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

        // Move card to appropriate zone based on source
        const cs = agent.combat_state orelse continue;
        if (action.source) |_| {
            // Pool clone: destroy it
            _ = cs.removeFromInPlay(card.id, registry) catch continue;
        } else {
            // Hand card: move to discard or exhaust
            const combat_dest: combat.CombatZone = if (card.template.cost.exhausts)
                .exhaust
            else
                .discard;

            cs.moveCard(card.id, .in_play, combat_dest) catch continue;

            // Event uses cards.Zone (not combat.CombatZone)
            const event_dest: cards.Zone = if (card.template.cost.exhausts)
                .exhaust
            else
                .discard;
            try event_system.push(.{
                .card_moved = .{
                    .instance = card.id,
                    .from = .in_play,
                    .to = event_dest,
                    .actor = actor_meta,
                },
            });
        }
    }
}
