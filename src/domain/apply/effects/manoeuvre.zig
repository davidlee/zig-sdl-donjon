//! Manoeuvre card effects - range modification and movement.
//!
//! Handles execution of manoeuvre-type cards that modify engagement
//! range between agents.

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
                        // Get the focal target for this manoeuvre
                        const focal_target = slot.play.target orelse continue;

                        // Apply range modification to the focal engagement
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

    // Propagation: apply n-1 steps to other engagements (Phase 5 multi-opponent)
    // Currently a no-op for single engagement encounters
    _ = propagate; // TODO (Phase 5): Iterate other engagements and apply reduced steps
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
