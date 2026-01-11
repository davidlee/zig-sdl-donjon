/// Height/exposure helpers for selecting hit locations.
///
/// Encapsulates target height weighting and exposure selection logic used by
/// the resolution pipeline. No rendering or combat orchestration occurs here.
const std = @import("std");
const combat = @import("../combat.zig");
const actions = @import("../actions.zig");
const body = @import("../body.zig");
const world = @import("../world.zig");

const Agent = combat.Agent;
const Technique = actions.Technique;
const World = world.World;

// ============================================================================
// Hit Location Selection
// ============================================================================

/// Height weighting multipliers for hit location selection
pub const height_weight = struct {
    pub const primary: f32 = 2.0; // target height
    pub const secondary: f32 = 1.0; // secondary height (if set)
    pub const adjacent: f32 = 0.5; // adjacent to target
    pub const off_target: f32 = 0.1; // opposite height
};

/// Calculate weight multiplier for exposure based on attack height
pub fn getHeightMultiplier(
    exp_height: body.Height,
    target_height: body.Height,
    secondary_height: ?body.Height,
) f32 {
    // Primary target
    if (exp_height == target_height) {
        return height_weight.primary;
    }

    // Secondary target (e.g., swing high->mid)
    if (secondary_height) |sec| {
        if (exp_height == sec) {
            return height_weight.secondary;
        }
    }

    // Adjacent height
    if (exp_height.adjacent(target_height)) {
        return height_weight.adjacent;
    }

    // Off-target (opposite height)
    return height_weight.off_target;
}

/// Select hit location from exposure table with height weighting
pub fn selectHitLocationFromExposures(
    exposures: []const body.Exposure,
    target_height: body.Height,
    secondary_height: ?body.Height,
    guard_height: ?body.Height,
    covers_adjacent: bool,
    roll: f32,
) ?usize {
    // Calculate weighted probabilities
    var total_weight: f32 = 0;
    var weights: [64]f32 = undefined; // max 64 exposures

    for (exposures, 0..) |exp, i| {
        var w = exp.base_chance;

        // Apply attack height targeting
        w *= getHeightMultiplier(exp.height, target_height, secondary_height);

        // Apply defense coverage (reduces exposure of guarded zone)
        if (guard_height) |gh| {
            if (exp.height == gh) {
                w *= 0.3; // guarded zone is hard to hit
            } else if (covers_adjacent and exp.height.adjacent(gh)) {
                w *= 0.6; // adjacent zone partially covered
            }
        }

        weights[i] = w;
        total_weight += w;
    }

    if (total_weight <= 0) return null;

    // Weighted random selection
    const target = roll * total_weight;
    var cumulative: f32 = 0;
    for (weights[0..exposures.len], 0..) |w, i| {
        cumulative += w;
        if (target <= cumulative) {
            return i;
        }
    }

    return exposures.len - 1; // fallback to last
}

/// Find body part index by tag and side
pub fn findPartIndex(parts: []const body.Part, tag: body.PartTag, side: body.Side) ?body.PartIndex {
    for (parts, 0..) |part, i| {
        if (part.tag == tag and part.side == side) {
            return @intCast(i);
        }
    }
    return null;
}

/// Select a target body part based on technique and defense
pub fn selectHitLocation(
    w: *World,
    defender: *Agent,
    technique: *const Technique,
    defense_technique: ?*const Technique,
) !body.PartIndex {
    const exposures = &body.humanoid_exposures; // TODO: get from defender's body type

    // Get defense guard position
    const guard_height: ?body.Height = if (defense_technique) |dt| dt.guard_height else null;
    const covers_adjacent: bool = if (defense_technique) |dt| dt.covers_adjacent else false;

    const roll = try w.drawRandom(.combat);

    // Select from exposure table
    if (selectHitLocationFromExposures(
        exposures,
        technique.target_height,
        technique.secondary_height,
        guard_height,
        covers_adjacent,
        roll,
    )) |exp_idx| {
        const exp = exposures[exp_idx];

        // Find the actual body part index
        if (findPartIndex(defender.body.parts.items, exp.tag, exp.side)) |part_idx| {
            return part_idx;
        }
    }

    // Fallback to torso (should always exist)
    return findPartIndex(defender.body.parts.items, .torso, .center) orelse 0;
}

// ============================================================================
// Tests
// ============================================================================

test "Height.adjacent returns true for mid to any, false for low/high" {
    try std.testing.expect(body.Height.low.adjacent(.mid));
    try std.testing.expect(body.Height.high.adjacent(.mid));
    try std.testing.expect(body.Height.mid.adjacent(.low));
    try std.testing.expect(body.Height.mid.adjacent(.high));

    // Low and high are not adjacent
    try std.testing.expect(!body.Height.low.adjacent(.high));
    try std.testing.expect(!body.Height.high.adjacent(.low));
}

test "getHeightMultiplier returns correct weights" {
    // Primary target
    try std.testing.expectApproxEqAbs(
        height_weight.primary,
        getHeightMultiplier(.mid, .mid, null),
        0.001,
    );

    // Secondary target
    try std.testing.expectApproxEqAbs(
        height_weight.secondary,
        getHeightMultiplier(.mid, .high, .mid),
        0.001,
    );

    // Adjacent to primary
    try std.testing.expectApproxEqAbs(
        height_weight.adjacent,
        getHeightMultiplier(.mid, .high, null),
        0.001,
    );

    // Off-target (low when targeting high, no secondary)
    try std.testing.expectApproxEqAbs(
        height_weight.off_target,
        getHeightMultiplier(.low, .high, null),
        0.001,
    );
}

test "selectHitLocationFromExposures favors target height" {
    // Simple test exposures: one per height zone
    const test_exposures = [_]body.Exposure{
        .{ .tag = .head, .side = .center, .base_chance = 0.33, .height = .high },
        .{ .tag = .torso, .side = .center, .base_chance = 0.34, .height = .mid },
        .{ .tag = .thigh, .side = .left, .base_chance = 0.33, .height = .low },
    };

    // With roll = 0.0, should always pick first weighted option
    // Targeting mid: mid gets 2x weight, others get less
    // Weights: high=0.33*0.5=0.165, mid=0.34*2.0=0.68, low=0.33*0.1=0.033
    // Total = 0.878, cumulative at mid = 0.165 + 0.68 = 0.845

    // Roll = 0.0 * total should give first entry (high)
    const result_low_roll = selectHitLocationFromExposures(
        &test_exposures,
        .mid, // target
        null, // no secondary
        null, // no guard
        false,
        0.0,
    );
    try std.testing.expectEqual(@as(?usize, 0), result_low_roll); // head (first)

    // Roll = 0.5 should land in mid range
    const result_mid_roll = selectHitLocationFromExposures(
        &test_exposures,
        .mid,
        null,
        null,
        false,
        0.5,
    );
    try std.testing.expectEqual(@as(?usize, 1), result_mid_roll); // torso

    // Roll = 0.99 should land in low range
    const result_high_roll = selectHitLocationFromExposures(
        &test_exposures,
        .mid,
        null,
        null,
        false,
        0.99,
    );
    try std.testing.expectEqual(@as(?usize, 2), result_high_roll); // thigh
}

test "selectHitLocationFromExposures defense coverage reduces hit chance" {
    const test_exposures = [_]body.Exposure{
        .{ .tag = .head, .side = .center, .base_chance = 0.5, .height = .high },
        .{ .tag = .thigh, .side = .left, .base_chance = 0.5, .height = .low },
    };

    // Attack high, guard high - high zone heavily reduced
    // Without guard: high=0.5*2.0=1.0, low=0.5*0.1=0.05
    // With guard: high=0.5*2.0*0.3=0.3, low=0.5*0.1=0.05
    // Total without = 1.05, with = 0.35

    // Roll 0.5 without guard should hit head (high)
    const no_guard = selectHitLocationFromExposures(
        &test_exposures,
        .high,
        null,
        null, // no guard
        false,
        0.5,
    );
    try std.testing.expectEqual(@as(?usize, 0), no_guard); // head

    // Roll 0.99 with high guard should more likely hit low
    const with_guard = selectHitLocationFromExposures(
        &test_exposures,
        .high,
        null,
        .high, // guard matches attack
        false,
        0.95,
    );
    try std.testing.expectEqual(@as(?usize, 1), with_guard); // thigh
}

test "selectHitLocationFromExposures secondary height gets normal weight" {
    const test_exposures = [_]body.Exposure{
        .{ .tag = .head, .side = .center, .base_chance = 0.33, .height = .high },
        .{ .tag = .torso, .side = .center, .base_chance = 0.34, .height = .mid },
        .{ .tag = .thigh, .side = .left, .base_chance = 0.33, .height = .low },
    };

    // Attack high with secondary mid (like a swing)
    // high = 0.33 * 2.0 = 0.66 (primary)
    // mid = 0.34 * 1.0 = 0.34 (secondary)
    // low = 0.33 * 0.1 = 0.033 (off-target)
    // Total = 1.033

    // Mid zone should have significant weight (not the 0.5x of adjacent)
    const result = selectHitLocationFromExposures(
        &test_exposures,
        .high, // primary
        .mid, // secondary
        null,
        false,
        0.7, // should land in mid
    );
    try std.testing.expectEqual(@as(?usize, 1), result); // torso
}
