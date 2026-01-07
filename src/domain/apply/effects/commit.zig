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

/// Execute on_commit rules for a single card.
fn executeCardCommitRules(card: *const cards.Instance, actor: *Agent, world: *World) !void {
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

/// Execute on_commit rules for all cards in an agent's timeline plays.
/// Called when entering commit_phase. Processes both action cards and stacked modifiers.
pub fn executeCommitPhaseRules(world: *World, actor: *Agent) !void {
    const enc = world.encounter orelse return;
    const enc_state = enc.stateFor(actor.id) orelse return;

    // Iterate over plays in timeline - includes both action cards and modifiers
    for (enc_state.current.timeline.slots()) |slot| {
        // Process the action card's rules
        const action_card = world.card_registry.get(slot.play.action) orelse continue;
        try executeCardCommitRules(action_card, actor, world);

        // Process modifier cards' rules
        for (slot.play.modifiers()) |mod_entry| {
            const mod_card = world.card_registry.get(mod_entry.card_id) orelse continue;
            try executeCardCommitRules(mod_card, actor, world);
        }
    }
}
