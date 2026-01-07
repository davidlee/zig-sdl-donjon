//! Manoeuvre card effects - range modification and movement.
//!
//! Handles execution of manoeuvre-type cards that modify engagement
//! range between agents.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const combat = @import("../../combat.zig");
const World = @import("../../world.zig").World;

/// Execute all manoeuvre effects for all agents in the encounter.
pub fn executeManoeuvreEffects(world: *World) !void {
    const enc = world.encounter orelse return;

    // Process player manoeuvres
    try executeAgentManoeuvres(world, world.player, enc);

    // Process enemy manoeuvres
    for (enc.enemies.items) |mob| {
        try executeAgentManoeuvres(world, mob, enc);
    }
}

fn executeAgentManoeuvres(world: *World, actor: *combat.Agent, enc: *combat.Encounter) !void {
    const enc_state = enc.stateFor(actor.id) orelse return;

    for (enc_state.current.slots()) |slot| {
        const card = world.card_registry.get(slot.play.action) orelse continue;

        // Only process manoeuvre cards
        if (!card.template.tags.manoeuvre) continue;

        // Find modify_range effects in the card's rules
        for (card.template.rules) |rule| {
            if (rule.trigger != .on_resolve) continue;

            for (rule.expressions) |expr| {
                switch (expr.effect) {
                    .modify_range => |range_mod| {
                        // Apply range modification based on target type
                        switch (expr.target) {
                            .all_enemies => {
                                // Apply to all engagements (e.g., disengage)
                                for (enc.enemies.items) |enemy| {
                                    if (enemy.id.eql(actor.id)) continue; // skip self
                                    try applyRangeModification(
                                        world,
                                        enc,
                                        actor.id,
                                        enemy.id,
                                        range_mod.steps,
                                        false, // no propagation for all_enemies
                                    );
                                }
                            },
                            .single => {
                                // Apply to focal target with propagation
                                const focal_target = slot.play.target orelse continue;
                                try applyRangeModification(
                                    world,
                                    enc,
                                    actor.id,
                                    focal_target,
                                    range_mod.steps,
                                    range_mod.propagate,
                                );
                            },
                            else => {},
                        }
                    },
                    .modify_position => |delta| {
                        // Apply position modification based on target type
                        switch (expr.target) {
                            .all_enemies => {
                                // Apply to all engagements
                                try applyPositionToAll(world, enc, actor.id, delta);
                            },
                            .single => {
                                const target_id = slot.play.target orelse continue;
                                try applyPositionModification(world, enc, actor.id, target_id, delta);
                            },
                            else => {},
                        }
                    },
                    .set_primary_target => {
                        const target_id = slot.play.target orelse continue;
                        try applySetPrimaryTarget(world, enc_state, actor.id, target_id);
                    },
                    else => {},
                }
            }
        }
    }
}

fn applyRangeModification(
    world: *World,
    enc: *combat.Encounter,
    actor_id: entity.ID,
    target_id: entity.ID,
    steps: i8,
    propagate: bool,
) !void {
    // Get the engagement to modify
    const engagement = enc.getEngagement(actor_id, target_id) orelse return;

    const old_range = engagement.range;
    engagement.range = adjustRange(engagement.range, steps);

    // Emit event if range changed
    if (engagement.range != old_range) {
        try world.events.push(.{ .range_changed = .{
            .actor_id = actor_id,
            .target_id = target_id,
            .old_range = old_range,
            .new_range = engagement.range,
        } });
    }

    // Propagation: apply n-1 steps to other engagements (multi-opponent)
    // Moving toward one enemy partially moves you toward/away from others
    if (propagate and @abs(steps) > 1) {
        const propagated_steps: i8 = if (steps > 0) steps - 1 else steps + 1;

        // Apply to other engagements involving this actor
        for (enc.enemies.items) |enemy| {
            if (enemy.id.eql(target_id)) continue; // skip focal target

            if (enc.getEngagement(actor_id, enemy.id)) |other_eng| {
                const other_old_range = other_eng.range;
                other_eng.range = adjustRange(other_eng.range, propagated_steps);

                if (other_eng.range != other_old_range) {
                    try world.events.push(.{ .range_changed = .{
                        .actor_id = actor_id,
                        .target_id = enemy.id,
                        .old_range = other_old_range,
                        .new_range = other_eng.range,
                    } });
                }
            }
        }

        // Also check if actor is the player and propagate to player engagement
        if (!actor_id.eql(enc.player_id)) {
            if (enc.getEngagement(enc.player_id, actor_id)) |player_eng| {
                if (!enc.player_id.eql(target_id)) {
                    const player_old_range = player_eng.range;
                    player_eng.range = adjustRange(player_eng.range, propagated_steps);

                    if (player_eng.range != player_old_range) {
                        try world.events.push(.{ .range_changed = .{
                            .actor_id = actor_id,
                            .target_id = enc.player_id,
                            .old_range = player_old_range,
                            .new_range = player_eng.range,
                        } });
                    }
                }
            }
        }
    }
}

fn applyPositionModification(
    world: *World,
    enc: *combat.Encounter,
    actor_id: entity.ID,
    target_id: entity.ID,
    delta: f32,
) !void {
    const engagement = enc.getEngagement(actor_id, target_id) orelse return;

    const old_position = engagement.position;
    engagement.position = std.math.clamp(engagement.position + delta, 0.0, 1.0);

    if (engagement.position != old_position) {
        try world.events.push(.{ .position_changed = .{
            .actor_id = actor_id,
            .target_id = target_id,
            .old_position = old_position,
            .new_position = engagement.position,
        } });
    }
}

fn applyPositionToAll(
    world: *World,
    enc: *combat.Encounter,
    actor_id: entity.ID,
    delta: f32,
) !void {
    // Apply to all enemy engagements
    for (enc.enemies.items) |enemy| {
        if (enemy.id.eql(actor_id)) continue; // skip self
        try applyPositionModification(world, enc, actor_id, enemy.id, delta);
    }

    // If actor is an enemy, also apply to player engagement
    if (!actor_id.eql(enc.player_id)) {
        try applyPositionModification(world, enc, actor_id, enc.player_id, delta);
    }
}

fn applySetPrimaryTarget(
    world: *World,
    enc_state: *combat.AgentEncounterState,
    actor_id: entity.ID,
    target_id: entity.ID,
) !void {
    const old_target = enc_state.attention.primary;
    enc_state.attention.primary = target_id;

    try world.events.push(.{ .primary_target_changed = .{
        .actor_id = actor_id,
        .old_target = old_target,
        .new_target = target_id,
    } });
}

/// Adjust reach by the given number of steps, clamping to valid range.
pub fn adjustRange(current: combat.Reach, steps: i8) combat.Reach {
    const current_int: i16 = @intFromEnum(current);
    const new_int = current_int + steps;

    // Clamp to valid enum range
    const min_reach: i16 = @intFromEnum(combat.Reach.clinch);
    const max_reach: i16 = @intFromEnum(combat.Reach.far);
    const clamped = @min(max_reach, @max(min_reach, new_int));

    return @enumFromInt(@as(u4, @intCast(clamped)));
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "adjustRange advances toward clinch" {
    try testing.expectEqual(combat.Reach.near, adjustRange(.medium, -1));
    try testing.expectEqual(combat.Reach.spear, adjustRange(.near, -1));
    try testing.expectEqual(combat.Reach.clinch, adjustRange(.clinch, -1)); // clamped
}

test "adjustRange retreats toward far" {
    try testing.expectEqual(combat.Reach.medium, adjustRange(.near, 1));
    try testing.expectEqual(combat.Reach.far, adjustRange(.medium, 1));
    try testing.expectEqual(combat.Reach.far, adjustRange(.far, 1)); // clamped
}

test "adjustRange clamps at clinch boundary" {
    try testing.expectEqual(combat.Reach.clinch, adjustRange(.clinch, -5));
    try testing.expectEqual(combat.Reach.clinch, adjustRange(.near, -10));
}

test "adjustRange clamps at far boundary" {
    try testing.expectEqual(combat.Reach.far, adjustRange(.far, 5));
    try testing.expectEqual(combat.Reach.far, adjustRange(.medium, 10));
}

test "range propagation applies n-1 steps to non-focal engagements" {
    // TODO: requires multi-engagement encounter setup
    // - advance 2 steps toward enemy A
    // - verify enemy B engagement gets 1 step closer
    // - retreat 3 steps from enemy A
    // - verify enemy B engagement gets 2 steps farther
    return error.SkipZigTest;
}
