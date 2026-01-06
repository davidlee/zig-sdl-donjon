//! Resolve phase effects - effects that execute during tick resolution.
//!
//! Handles stamina/focus recovery, condition application, and
//! condition expiration ticking.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const cards = @import("../../cards.zig");
const combat = @import("../../combat.zig");
const events = @import("../../events.zig");
const World = @import("../../world.zig").World;
const targeting = @import("../targeting.zig");
const validation = @import("../validation.zig");

const Agent = combat.Agent;
const EventSystem = events.EventSystem;

/// Apply a single resolve-phase effect to an agent.
fn applyResolveEffect(
    effect: cards.Effect,
    agent: *Agent,
    is_player: bool,
    world: *World,
) !void {
    const actor_meta: events.AgentMeta = .{ .id = agent.id, .player = is_player };

    switch (effect) {
        .modify_stamina => |mod| {
            const old_value = agent.stamina.current;
            const delta: f32 = @as(f32, @floatFromInt(mod.amount)) + (agent.stamina.max * mod.ratio);
            agent.stamina.current = @min(agent.stamina.current + delta, agent.stamina.max);
            agent.stamina.available = @min(agent.stamina.available + delta, agent.stamina.current);

            try world.events.push(.{ .stamina_recovered = .{
                .agent_id = agent.id,
                .amount = agent.stamina.current - old_value,
                .new_value = agent.stamina.current,
                .actor = actor_meta,
            } });
        },
        .modify_focus => |mod| {
            const old_value = agent.focus.current;
            const delta: f32 = @as(f32, @floatFromInt(mod.amount)) + (agent.focus.max * mod.ratio);
            agent.focus.current = @min(agent.focus.current + delta, agent.focus.max);
            agent.focus.available = @min(agent.focus.available + delta, agent.focus.current);

            try world.events.push(.{ .focus_recovered = .{
                .agent_id = agent.id,
                .amount = agent.focus.current - old_value,
                .new_value = agent.focus.current,
                .actor = actor_meta,
            } });
        },
        .add_condition => |active_cond| {
            try agent.conditions.append(world.alloc, active_cond);

            try world.events.push(.{ .condition_applied = .{
                .agent_id = agent.id,
                .condition = active_cond.condition,
                .actor = actor_meta,
            } });
        },
        else => {}, // Other effects not handled during resolution
    }
}

/// Execute all on_resolve rules for an agent's in-play cards.
/// Called during tick resolution.
pub fn executeResolvePhaseRules(world: *World, actor: *Agent) !void {
    const cs = actor.combat_state orelse return;
    const is_player = switch (actor.director) {
        .player => true,
        else => false,
    };
    const actor_meta: events.AgentMeta = .{ .id = actor.id, .player = is_player };

    // Track cards that resolved on_resolve rules and should exhaust
    var to_exhaust = try std.ArrayList(entity.ID).initCapacity(world.alloc, 4);
    defer to_exhaust.deinit(world.alloc);

    for (cs.in_play.items) |card_id| {
        const card = world.card_registry.get(card_id) orelse continue;

        var rule_fired = false;
        for (card.template.rules) |rule| {
            if (rule.trigger != .on_resolve) continue;

            // Check rule validity predicate (weapon requirements, range, etc.)
            if (!validation.rulePredicatesSatisfied(card.template, actor, world.encounter)) continue;

            rule_fired = true;

            // Execute expressions
            for (rule.expressions) |expr| {
                switch (expr.target) {
                    .self => {
                        try applyResolveEffect(expr.effect, actor, is_player, world);
                    },
                    .all_enemies => {
                        // Get enemy targets
                        var targets = try targeting.evaluateTargets(world.alloc, .all_enemies, actor, world, null);
                        defer targets.deinit(world.alloc);

                        for (targets.items) |target| {
                            const target_is_player = switch (target.director) {
                                .player => true,
                                else => false,
                            };
                            try applyResolveEffect(expr.effect, target, target_is_player, world);
                        }
                    },
                    else => {
                        // Other targets not yet implemented for resolve effects
                    },
                }
            }
        }

        // Track exhausting cards that had on_resolve rules fire
        if (rule_fired and card.template.cost.exhausts) {
            try to_exhaust.append(world.alloc, card_id);
        }
    }

    // Move exhausting cards to exhaust zone
    for (to_exhaust.items) |card_id| {
        cs.moveCard(card_id, .in_play, .exhaust) catch continue;
        try world.events.push(.{
            .card_moved = .{
                .instance = card_id,
                .from = .in_play,
                .to = .exhaust,
                .actor = actor_meta,
            },
        });
    }
}

/// Tick all conditions on an agent, removing expired ones.
/// Called at the end of each tick.
pub fn tickConditions(agent: *Agent, event_system: *EventSystem) !void {
    const is_player = switch (agent.director) {
        .player => true,
        else => false,
    };
    const actor_meta: events.AgentMeta = .{ .id = agent.id, .player = is_player };

    // Iterate backwards so we can remove while iterating
    var i: usize = agent.conditions.items.len;
    while (i > 0) {
        i -= 1;
        const cond = &agent.conditions.items[i];

        var should_remove = false;
        switch (cond.expiration) {
            .ticks => |*remaining| {
                remaining.* -= 1.0;
                if (remaining.* <= 0) {
                    should_remove = true;
                }
            },
            .end_of_tick => {
                should_remove = true;
            },
            .dynamic, .permanent, .end_of_action, .end_of_combat => {},
        }

        if (should_remove) {
            const removed_condition = cond.condition;
            _ = agent.conditions.orderedRemove(i);

            try event_system.push(.{ .condition_expired = .{
                .agent_id = agent.id,
                .condition = removed_condition,
                .actor = actor_meta,
            } });
        }
    }
}
