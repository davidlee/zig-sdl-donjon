//! Commit phase effects - card effects that execute during the commit phase.
//!
//! These effects modify plays before resolution (e.g., damage/cost multipliers,
//! advantage overrides, play cancellation).

const cards = @import("../../cards.zig");
const combat = @import("../../combat.zig");
const World = @import("../../world.zig").World;
const targeting = @import("../targeting.zig");
const validation = @import("../validation.zig");

const Agent = combat.Agent;
const PlayTarget = targeting.PlayTarget;

/// Apply a single commit-phase effect to a target play.
pub fn applyCommitPhaseEffect(
    effect: cards.Effect,
    play_target: PlayTarget,
    world: *World,
) void {
    const enc = world.encounter orelse return;
    const enc_state = enc.stateFor(play_target.agent.id) orelse return;

    switch (effect) {
        .modify_play => |mod| {
            if (play_target.play_index >= enc_state.current.slots().len) return;
            var play = &enc_state.current.slotsMut()[play_target.play_index].play;
            if (mod.cost_mult) |m| play.cost_mult *= m;
            if (mod.damage_mult) |m| play.damage_mult *= m;
            if (mod.replace_advantage) |adv| play.advantage_override = adv;
        },
        .cancel_play => {
            enc_state.current.removePlay(play_target.play_index);
        },
        else => {}, // Other effects not handled here
    }
}

/// Execute all on_commit rules for an agent's in-play cards.
/// Called when entering commit_phase.
pub fn executeCommitPhaseRules(world: *World, actor: *Agent) !void {
    const cs = actor.combat_state orelse return;

    // Iterate over card IDs in play, look up instances via registry
    for (cs.in_play.items) |card_id| {
        const card = world.card_registry.get(card_id) orelse continue;

        for (card.template.rules) |rule| {
            if (rule.trigger != .on_commit) continue;

            // Check rule validity predicate (weapon requirements, range, etc.)
            if (!validation.rulePredicatesSatisfied(card.template, actor, world.encounter)) continue;

            // Execute expressions
            for (rule.expressions) |expr| {
                // Check if this is a play-targeting expression
                switch (expr.target) {
                    .my_play, .opponent_play => {
                        var targets = try targeting.evaluatePlayTargets(world.alloc, expr.target, actor, world);
                        defer targets.deinit(world.alloc);

                        for (targets.items) |target| {
                            applyCommitPhaseEffect(expr.effect, target, world);
                        }
                    },
                    else => {
                        // Non-play targets handled elsewhere
                    },
                }
            }
        }
    }
}
