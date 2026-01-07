//! Positioning contests between combatants.
//!
//! Resolves conflicting manoeuvres when multiple agents attempt to control
//! positioning in the same tick. Uses weighted scoring based on speed,
//! engagement position, and balance.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const combat = @import("../../combat.zig");
const cards = @import("../../cards.zig");
const stats = @import("../../stats.zig");
const random = @import("../../random.zig");
const weapon = @import("../../weapon.zig");
const world_mod = @import("../../world.zig");
const World = world_mod.World;
const CardRegistry = world_mod.CardRegistry;

/// Type of footwork being attempted.
pub const ManoeuvreType = enum {
    advance, // closing distance
    retreat, // opening distance
    sidestep, // lateral movement for angle
    hold, // standing still / no footwork
};

/// Outcome of a positioning contest.
pub const ManoeuvreOutcome = enum {
    aggressor_succeeds,
    defender_succeeds,
    stalemate,
};

/// Full result of a positioning contest including scores for logging.
pub const ContestResult = struct {
    outcome: ManoeuvreOutcome,
    aggressor_score: f32,
    defender_score: f32,
};

/// Weights for manoeuvre score calculation.
const speed_weight: f32 = 0.3;
const position_weight: f32 = 0.4;
const balance_weight: f32 = 0.3;
const standing_still_penalty: f32 = 0.3;

/// Threshold for determining clear winner vs stalemate.
/// Score differential must exceed this to avoid stalemate.
const stalemate_threshold: f32 = 0.1;

/// Calculate positioning contest score for an agent.
/// Score = Speed (0.3) + Position (0.4) + Balance (0.3) - standing still penalty.
pub fn calculateManoeuvreScore(
    agent: *const combat.Agent,
    move: ManoeuvreType,
    position: f32,
) f32 {
    const speed = stats.Block.normalize(agent.stats.speed);
    const balance = agent.balance;

    var score = (speed * speed_weight) +
        (position * position_weight) +
        (balance * balance_weight);

    if (move == .hold) {
        score -= standing_still_penalty;
    }

    return score;
}

/// Resolve a positioning conflict between aggressor and defender.
/// Returns outcome based on score differential with randomness.
pub fn resolveManoeuvreConflict(
    aggressor: *const combat.Agent,
    defender: *const combat.Agent,
    aggressor_move: ManoeuvreType,
    defender_move: ManoeuvreType,
    engagement: *const combat.Engagement,
    rng: std.Random,
) ContestResult {
    // Calculate scores for logging regardless of auto-win/lose rules
    const aggressor_score = calculateManoeuvreScore(aggressor, aggressor_move, engagement.position);
    const defender_position = 1.0 - engagement.position;
    const defender_score = calculateManoeuvreScore(defender, defender_move, defender_position);

    // Standing still auto-loses against advance
    if (defender_move == .hold and aggressor_move == .advance) {
        return .{ .outcome = .aggressor_succeeds, .aggressor_score = aggressor_score, .defender_score = defender_score };
    }
    if (aggressor_move == .hold and defender_move == .advance) {
        return .{ .outcome = .defender_succeeds, .aggressor_score = aggressor_score, .defender_score = defender_score };
    }

    // Both holding = stalemate (no movement contest)
    if (aggressor_move == .hold and defender_move == .hold) {
        return .{ .outcome = .stalemate, .aggressor_score = aggressor_score, .defender_score = defender_score };
    }

    const differential = aggressor_score - defender_score;

    // Add randomness: roll 0..0.2 variance centered on differential
    const variance = (rng.float(f32) - 0.5) * 0.2;
    const adjusted_diff = differential + variance;

    const outcome: ManoeuvreOutcome = if (adjusted_diff > stalemate_threshold)
        .aggressor_succeeds
    else if (adjusted_diff < -stalemate_threshold)
        .defender_succeeds
    else
        .stalemate;

    return .{ .outcome = outcome, .aggressor_score = aggressor_score, .defender_score = defender_score };
}

/// Determine what footwork an agent is attempting this tick based on their played cards.
/// Scans manoeuvre cards for modify_range effects to infer movement intent.
/// Returns null if agent has no encounter state.
pub fn getAgentFootwork(
    agent: *const combat.Agent,
    enc: *const combat.Encounter,
    registry: *const CardRegistry,
) ?ManoeuvreType {
    const enc_state = enc.stateForConst(agent.id) orelse return null;

    var net_steps: i8 = 0;
    var has_manoeuvre = false;

    for (enc_state.current.slots()) |slot| {
        const card = registry.getConst(slot.play.action) orelse continue;

        if (!card.template.tags.manoeuvre) continue;
        has_manoeuvre = true;

        // Sum up modify_range effects from on_resolve rules
        for (card.template.rules) |rule| {
            if (rule.trigger != .on_resolve) continue;
            for (rule.expressions) |expr| {
                switch (expr.effect) {
                    .modify_range => |range_mod| {
                        net_steps += range_mod.steps;
                    },
                    else => {},
                }
            }
        }
    }

    if (!has_manoeuvre) return .hold;

    // Interpret net movement
    if (net_steps < 0) return .advance;
    if (net_steps > 0) return .retreat;
    // Has manoeuvre card(s) but net zero range change = sidestep
    return .sidestep;
}

/// Get the primary weapon's reach for an agent.
/// Returns sabre as fallback if no weapon equipped.
fn getPrimaryWeaponReach(agent: *const combat.Agent) combat.Reach {
    const template = switch (agent.weapons) {
        .single => |w| w.template,
        .dual => |d| d.primary.template,
        .compound => return .sabre, // fallback for complex setups
    };
    // Use swing reach as primary, fall back to thrust
    if (template.swing) |s| return s.reach;
    if (template.thrust) |t| return t.reach;
    return .sabre;
}

/// Resolve positioning contests for all engagements in the encounter.
/// Called after executeManoeuvreEffects to apply contest bonuses.
pub fn resolvePositioningContests(world: *World) !void {
    const enc = world.encounter orelse return;
    const rng_source = world.getRandomSource(.combat);
    const rng = rng_source.stream.random();

    // For each player-enemy engagement
    for (enc.enemies.items) |enemy| {
        const engagement = enc.getEngagement(world.player.id, enemy.id) orelse continue;

        const player_footwork = getAgentFootwork(world.player, enc, &world.card_registry) orelse .hold;
        const enemy_footwork = getAgentFootwork(enemy, enc, &world.card_registry) orelse .hold;

        // Skip if both holding (no contest)
        if (player_footwork == .hold and enemy_footwork == .hold) continue;

        // Resolve contest (player is "aggressor" by convention)
        const result = resolveManoeuvreConflict(
            world.player,
            enemy,
            player_footwork,
            enemy_footwork,
            engagement,
            rng,
        );

        // Emit contest event
        try world.events.push(.{ .manoeuvre_contest_resolved = .{
            .aggressor_id = world.player.id,
            .defender_id = enemy.id,
            .aggressor_move = player_footwork,
            .defender_move = enemy_footwork,
            .aggressor_score = result.aggressor_score,
            .defender_score = result.defender_score,
            .outcome = result.outcome,
        } });

        // Apply contest outcome
        try applyContestOutcome(world, enc, world.player, enemy, engagement, result.outcome, player_footwork, enemy_footwork);
    }
}

/// Apply the outcome of a positioning contest.
fn applyContestOutcome(
    world: *World,
    _: *combat.Encounter, // enc - reserved for future multi-engagement propagation
    player: *combat.Agent,
    enemy: *combat.Agent,
    engagement: *combat.Engagement,
    outcome: ManoeuvreOutcome,
    player_footwork: ManoeuvreType,
    enemy_footwork: ManoeuvreType,
) !void {
    const manoeuvre = @import("manoeuvre.zig");

    switch (outcome) {
        .aggressor_succeeds => {
            // Player wins: +1 step in their direction
            const bonus_step: i8 = switch (player_footwork) {
                .advance => -1, // closer
                .retreat => 1, // farther
                .sidestep, .hold => 0,
            };
            if (bonus_step != 0) {
                const old_range = engagement.range;
                engagement.range = manoeuvre.adjustRange(engagement.range, bonus_step);

                // Apply floor at player's weapon reach
                const player_reach = getPrimaryWeaponReach(player);
                if (@intFromEnum(engagement.range) < @intFromEnum(player_reach)) {
                    engagement.range = player_reach;
                }

                if (engagement.range != old_range) {
                    try world.events.push(.{ .range_changed = .{
                        .actor_id = player.id,
                        .target_id = enemy.id,
                        .old_range = old_range,
                        .new_range = engagement.range,
                    } });
                }
            }
        },
        .defender_succeeds => {
            // Enemy wins: +1 step in their direction
            const bonus_step: i8 = switch (enemy_footwork) {
                .advance => -1, // closer
                .retreat => 1, // farther
                .sidestep, .hold => 0,
            };
            if (bonus_step != 0) {
                const old_range = engagement.range;
                engagement.range = manoeuvre.adjustRange(engagement.range, bonus_step);

                // Apply floor at enemy's weapon reach
                const enemy_reach = getPrimaryWeaponReach(enemy);
                if (@intFromEnum(engagement.range) < @intFromEnum(enemy_reach)) {
                    engagement.range = enemy_reach;
                }

                if (engagement.range != old_range) {
                    try world.events.push(.{ .range_changed = .{
                        .actor_id = enemy.id,
                        .target_id = player.id,
                        .old_range = old_range,
                        .new_range = engagement.range,
                    } });
                }
            }
        },
        .stalemate => {
            // No bonus, but still apply floor at closer weapon reach if both advancing
            if (player_footwork == .advance and enemy_footwork == .advance) {
                const player_reach = getPrimaryWeaponReach(player);
                const enemy_reach = getPrimaryWeaponReach(enemy);
                // Use the longer reach as floor (defender's advantage in mutual advance)
                const floor_reach = if (@intFromEnum(player_reach) > @intFromEnum(enemy_reach))
                    player_reach
                else
                    enemy_reach;

                if (@intFromEnum(engagement.range) < @intFromEnum(floor_reach)) {
                    const old_range = engagement.range;
                    engagement.range = floor_reach;
                    try world.events.push(.{ .range_changed = .{
                        .actor_id = player.id,
                        .target_id = enemy.id,
                        .old_range = old_range,
                        .new_range = engagement.range,
                    } });
                }
            }
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const SlotMap = @import("../../slot_map.zig").SlotMap;
const body = @import("../../body.zig");
const weapon_list = @import("../../weapon_list.zig");

fn testId(index: u32) entity.ID {
    return .{ .index = index, .generation = 0 };
}

const TestAgent = struct {
    agent: *combat.Agent,
    sword: *weapon.Instance,
    agents: *SlotMap(*combat.Agent),

    fn deinit(self: TestAgent) void {
        self.agent.deinit();
        testing.allocator.destroy(self.sword);
        self.agents.deinit();
        testing.allocator.destroy(self.agents);
    }
};

fn makeTestAgent(alloc: std.mem.Allocator, speed: f32) !TestAgent {
    const agents = try alloc.create(SlotMap(*combat.Agent));
    agents.* = try SlotMap(*combat.Agent).init(alloc);
    errdefer {
        agents.deinit();
        alloc.destroy(agents);
    }

    const sword = try alloc.create(weapon.Instance);
    sword.* = .{ .id = testId(999), .template = &weapon_list.knights_sword };
    errdefer alloc.destroy(sword);

    return .{
        .agent = try combat.Agent.init(
            alloc,
            agents,
            .player,
            .shuffled_deck,
            stats.Block.splat(speed),
            try body.Body.fromPlan(alloc, &body.HumanoidPlan),
            stats.Resource.init(10, 10, 2),
            stats.Resource.init(3, 5, 3),
            .{ .single = sword },
        ),
        .sword = sword,
        .agents = agents,
    };
}

test "calculateManoeuvreScore uses speed, position, balance" {
    const alloc = testing.allocator;
    const test_agent = try makeTestAgent(alloc, 5.0);
    defer test_agent.deinit();

    // Default balance = 1.0, speed = 5 (normalized to 0.5), position = 0.5
    const score = calculateManoeuvreScore(test_agent.agent, .advance, 0.5);

    // Expected: 0.5 * 0.3 + 0.5 * 0.4 + 1.0 * 0.3 = 0.15 + 0.2 + 0.3 = 0.65
    try testing.expectApproxEqAbs(@as(f32, 0.65), score, 0.01);
}

test "calculateManoeuvreScore applies standing still penalty" {
    const alloc = testing.allocator;
    const test_agent = try makeTestAgent(alloc, 5.0);
    defer test_agent.deinit();

    const advance_score = calculateManoeuvreScore(test_agent.agent, .advance, 0.5);
    const hold_score = calculateManoeuvreScore(test_agent.agent, .hold, 0.5);

    try testing.expectApproxEqAbs(standing_still_penalty, advance_score - hold_score, 0.001);
}

test "resolveManoeuvreConflict: hold auto-loses to advance" {
    const alloc = testing.allocator;
    const aggressor = try makeTestAgent(alloc, 5.0);
    defer aggressor.deinit();
    const defender = try makeTestAgent(alloc, 5.0);
    defer defender.deinit();

    const engagement = combat.Engagement{};
    var prng = std.Random.DefaultPrng.init(12345);

    const outcome = resolveManoeuvreConflict(
        aggressor.agent,
        defender.agent,
        .advance,
        .hold,
        &engagement,
        prng.random(),
    );

    try testing.expectEqual(ManoeuvreOutcome.aggressor_succeeds, outcome.outcome);
}

test "resolveManoeuvreConflict: aggressor hold loses to defender advance" {
    const alloc = testing.allocator;
    const aggressor = try makeTestAgent(alloc, 5.0);
    defer aggressor.deinit();
    const defender = try makeTestAgent(alloc, 5.0);
    defer defender.deinit();

    const engagement = combat.Engagement{};
    var prng = std.Random.DefaultPrng.init(12345);

    const outcome = resolveManoeuvreConflict(
        aggressor.agent,
        defender.agent,
        .hold,
        .advance,
        &engagement,
        prng.random(),
    );

    try testing.expectEqual(ManoeuvreOutcome.defender_succeeds, outcome.outcome);
}

test "resolveManoeuvreConflict: both hold results in stalemate" {
    const alloc = testing.allocator;
    const aggressor = try makeTestAgent(alloc, 5.0);
    defer aggressor.deinit();
    const defender = try makeTestAgent(alloc, 5.0);
    defer defender.deinit();

    const engagement = combat.Engagement{};
    var prng = std.Random.DefaultPrng.init(12345);

    const outcome = resolveManoeuvreConflict(
        aggressor.agent,
        defender.agent,
        .hold,
        .hold,
        &engagement,
        prng.random(),
    );

    try testing.expectEqual(ManoeuvreOutcome.stalemate, outcome.outcome);
}

test "resolveManoeuvreConflict: faster agent tends to win" {
    const alloc = testing.allocator;
    const fast_agent = try makeTestAgent(alloc, 8.0);
    defer fast_agent.deinit();
    const slow_agent = try makeTestAgent(alloc, 3.0);
    defer slow_agent.deinit();

    const engagement = combat.Engagement{};
    var prng = std.Random.DefaultPrng.init(42);

    // Run multiple trials - faster agent should win majority
    var fast_wins: u32 = 0;
    for (0..20) |_| {
        const outcome = resolveManoeuvreConflict(
            fast_agent.agent,
            slow_agent.agent,
            .advance,
            .retreat,
            &engagement,
            prng.random(),
        );
        if (outcome.outcome == .aggressor_succeeds) fast_wins += 1;
    }

    // Fast agent (speed 8 vs 3) should win most contests
    try testing.expect(fast_wins >= 12);
}
