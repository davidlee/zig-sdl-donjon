/// Stat blocks and resource helpers for agents.
///
/// Defines Resource, Scaling, and computed stat accessors shared by combat
/// systems. This module is pure data/logic with no rendering.
const std = @import("std");
const lib = @import("infra");

/// A resource with commit/spend semantics for turn-based commitment flow.
/// - `current`: actual resource value
/// - `available`: uncommitted amount for this turn (≤ current)
pub const Resource = struct {
    current: f32,
    available: f32,
    default: f32,
    max: f32,
    per_turn: f32, // per-turn recovery

    pub fn init(default: f32, max: f32, per_turn: f32) Resource {
        return .{
            .current = default,
            .available = default,
            .default = default,
            .max = max,
            .per_turn = per_turn,
        };
    }

    /// Commit without spending (stamina on card selection).
    /// Returns false if insufficient available.
    pub fn commit(self: *Resource, amount: f32) bool {
        if (self.available >= amount) {
            self.available -= amount;
            return true;
        }
        return false;
    }

    /// Reverse a commitment (card withdrawn during commit phase).
    pub fn uncommit(self: *Resource, amount: f32) void {
        self.available = @min(self.available + amount, self.current);
    }

    /// Spend immediately (Focus actions, or one-shot costs).
    /// Returns false if insufficient available.
    pub fn spend(self: *Resource, amount: f32) bool {
        if (self.available >= amount) {
            self.available -= amount;
            self.current -= amount;
            return true;
        }
        return false;
    }

    /// Finalize commitments - current catches down to available (stamina at resolution).
    pub fn finalize(self: *Resource) void {
        self.current = self.available;
    }

    /// End of turn refresh.
    pub fn tick(self: *Resource) void {
        self.current = @min(self.current + self.per_turn, self.max);
        self.available = self.current;
    }

    /// Start of encounter reset.
    pub fn reset(self: *Resource) void {
        self.current = self.default;
        self.available = self.default;
    }

    /// Inflict damage that accumulates (for pain/trauma which increase toward max).
    /// Inverse of spend - adds to current, capped at max.
    pub fn inflict(self: *Resource, amount: f32) void {
        self.current = @min(self.current + amount, self.max);
        self.available = self.current;
    }

    /// Current as ratio of max (0.0 to 1.0).
    pub fn ratio(self: *const Resource) f32 {
        return if (self.max > 0) self.current / self.max else 0;
    }
};

pub const Scaling = struct {
    stats: CheckSignature,
    ratio: f32 = 1.0,
};

pub const CheckSignature = union(enum) {
    stat: Accessor,
    average: [2]Accessor,
};

pub const Accessor = enum {
    power,
    speed,
    agility,
    dexterity,
    fortitude,
    endurance,
    acuity,
    will,
    intuition,
    presence,
};

/// Returns true if the accessor represents a velocity-contributing stat
/// (affects swing/thrust speed → energy scales quadratically).
/// Returns false for mass/force-contributing stats (energy scales linearly).
pub fn isVelocityStat(accessor: Accessor) bool {
    return switch (accessor) {
        .speed, .dexterity, .agility => true,
        else => false,
    };
}

pub const Template = Block;

const testing = std.testing;

test "isVelocityStat classifies accessors for energy scaling (T038)" {
    // Velocity stats: speed, dexterity, agility → quadratic energy scaling
    try testing.expect(isVelocityStat(.speed));
    try testing.expect(isVelocityStat(.dexterity));
    try testing.expect(isVelocityStat(.agility));

    // Mass/force stats: power, fortitude, etc. → linear energy scaling
    try testing.expect(!isVelocityStat(.power));
    try testing.expect(!isVelocityStat(.fortitude));
    try testing.expect(!isVelocityStat(.endurance));
    try testing.expect(!isVelocityStat(.acuity));
    try testing.expect(!isVelocityStat(.will));
    try testing.expect(!isVelocityStat(.intuition));
    try testing.expect(!isVelocityStat(.presence));
}

test "Resource commit/finalize flow (stamina pattern)" {
    // Stamina: commit on card selection, finalize at resolution
    var stamina = Resource.init(10.0, 10.0, 2.0);

    // Commit 3 stamina for a card
    try testing.expect(stamina.commit(3.0));
    try testing.expectEqual(@as(f32, 7.0), stamina.available);
    try testing.expectEqual(@as(f32, 10.0), stamina.current); // not spent yet

    // Commit another 4
    try testing.expect(stamina.commit(4.0));
    try testing.expectEqual(@as(f32, 3.0), stamina.available);

    // Can't commit more than available
    try testing.expect(!stamina.commit(5.0));
    try testing.expectEqual(@as(f32, 3.0), stamina.available); // unchanged

    // Finalize: current catches down to available
    stamina.finalize();
    try testing.expectEqual(@as(f32, 3.0), stamina.current);
    try testing.expectEqual(@as(f32, 3.0), stamina.available);
}

test "Resource uncommit restores availability" {
    var stamina = Resource.init(10.0, 10.0, 2.0);

    _ = stamina.commit(6.0);
    try testing.expectEqual(@as(f32, 4.0), stamina.available);

    // Withdraw card, get stamina back
    stamina.uncommit(6.0);
    try testing.expectEqual(@as(f32, 10.0), stamina.available);

    // Uncommit can't exceed current
    stamina.uncommit(100.0);
    try testing.expectEqual(@as(f32, 10.0), stamina.available);
}

test "Resource spend deducts immediately (focus pattern)" {
    // Focus: spent immediately during commit phase
    var focus = Resource.init(3.0, 5.0, 3.0);

    try testing.expect(focus.spend(1.0));
    try testing.expectEqual(@as(f32, 2.0), focus.current);
    try testing.expectEqual(@as(f32, 2.0), focus.available);

    // Can't spend more than available
    try testing.expect(!focus.spend(3.0));
    try testing.expectEqual(@as(f32, 2.0), focus.current); // unchanged
}

test "Resource tick refreshes capped at max" {
    var res = Resource.init(5.0, 10.0, 3.0);

    // Deplete it
    _ = res.spend(4.0);
    try testing.expectEqual(@as(f32, 1.0), res.current);

    // Tick adds per_turn, syncs available
    res.tick();
    try testing.expectEqual(@as(f32, 4.0), res.current);
    try testing.expectEqual(@as(f32, 4.0), res.available);

    // Tick again
    res.tick();
    try testing.expectEqual(@as(f32, 7.0), res.current);

    // Tick caps at max
    res.tick();
    res.tick();
    try testing.expectEqual(@as(f32, 10.0), res.current);
}

test "Resource reset returns to default" {
    var res = Resource.init(5.0, 10.0, 3.0);

    // Modify state
    _ = res.spend(3.0);
    res.tick();

    // Reset brings back to default
    res.reset();
    try testing.expectEqual(@as(f32, 5.0), res.current);
    try testing.expectEqual(@as(f32, 5.0), res.available);
}

test "Resource inflict accumulates toward max" {
    // Pain/trauma pattern: starts empty, accumulates
    var pain = Resource.init(0.0, 10.0, 0.0);

    try testing.expectEqual(@as(f32, 0.0), pain.current);

    pain.inflict(3.0);
    try testing.expectEqual(@as(f32, 3.0), pain.current);
    try testing.expectEqual(@as(f32, 3.0), pain.available);

    pain.inflict(5.0);
    try testing.expectEqual(@as(f32, 8.0), pain.current);

    // Capped at max
    pain.inflict(10.0);
    try testing.expectEqual(@as(f32, 10.0), pain.current);
}

test "Resource ratio returns current/max" {
    var res = Resource.init(5.0, 10.0, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), res.ratio(), 0.001);

    res.inflict(3.0);
    try testing.expectApproxEqAbs(@as(f32, 0.8), res.ratio(), 0.001);

    // Edge case: max of 0
    var zero_max = Resource.init(0.0, 0.0, 0.0);
    try testing.expectEqual(@as(f32, 0.0), zero_max.ratio());
}

// Stat scale constants - used for normalization and damage formulas
pub const STAT_BASELINE: f32 = 5.0; // average/default stat value
pub const STAT_MAX: f32 = 10.0; // maximum stat value for normalization

/// Compute additive scaling multiplier from stat value.
/// Returns 1.0 at baseline (STAT_BASELINE), with ratio determining sensitivity.
/// Example: stat=7, ratio=1.2 → 1.0 + (0.7 - 0.5) * 1.2 = 1.24
pub fn scalingMultiplier(stat_value: f32, ratio: f32) f32 {
    const baseline_norm = STAT_BASELINE / STAT_MAX;
    const stat_norm = Block.normalize(stat_value);
    return 1.0 + (stat_norm - baseline_norm) * ratio;
}

test "scalingMultiplier returns 1.0 at baseline" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), scalingMultiplier(5.0, 1.2), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), scalingMultiplier(5.0, 0.5), 0.001);
}

test "scalingMultiplier scales by ratio" {
    // stat 7 with ratio 1.2: 1.0 + (0.7 - 0.5) * 1.2 = 1.24
    try testing.expectApproxEqAbs(@as(f32, 1.24), scalingMultiplier(7.0, 1.2), 0.001);
    // stat 3 with ratio 1.2: 1.0 + (0.3 - 0.5) * 1.2 = 0.76
    try testing.expectApproxEqAbs(@as(f32, 0.76), scalingMultiplier(3.0, 1.2), 0.001);
    // stat 10 with ratio 1.2: 1.0 + (1.0 - 0.5) * 1.2 = 1.6
    try testing.expectApproxEqAbs(@as(f32, 1.6), scalingMultiplier(10.0, 1.2), 0.001);
    // stat 1 with ratio 1.2: 1.0 + (0.1 - 0.5) * 1.2 = 0.52
    try testing.expectApproxEqAbs(@as(f32, 0.52), scalingMultiplier(1.0, 1.2), 0.001);
}

pub const Block = packed struct {
    // physical
    power: f32,
    speed: f32,
    agility: f32,
    dexterity: f32,
    fortitude: f32,
    endurance: f32,
    // mental
    acuity: f32,
    will: f32,
    intuition: f32,
    presence: f32,

    pub fn splat(num: f32) Block {
        return Block{
            .power = num,
            .speed = num,
            .agility = num,
            .dexterity = num,
            .fortitude = num,
            .endurance = num,
            // mental
            .acuity = num,
            .will = num,
            .intuition = num,
            .presence = num,
        };
    }

    pub fn get(self: *Block, a: Accessor) f32 {
        return switch (a) {
            .power => self.power,
            .speed => self.speed,
            .agility => self.agility,
            .dexterity => self.dexterity,
            .fortitude => self.fortitude,
            .endurance => self.endurance,
            .acuity => self.acuity,
            .will => self.will,
            .intuition => self.intuition,
            .presence => self.presence,
        };
    }

    pub fn getConst(self: *const Block, a: Accessor) f32 {
        return switch (a) {
            .power => self.power,
            .speed => self.speed,
            .agility => self.agility,
            .dexterity => self.dexterity,
            .fortitude => self.fortitude,
            .endurance => self.endurance,
            .acuity => self.acuity,
            .will => self.will,
            .intuition => self.intuition,
            .presence => self.presence,
        };
    }

    /// Normalize a raw stat value to 0-1 range.
    /// Baseline: stat of 5 → 0.5, stat of 10 → 1.0.
    pub fn normalize(value: f32) f32 {
        return std.math.clamp(value / STAT_MAX, 0.0, 1.0);
    }

    test "Block.normalize scales stats to 0-1" {
        try testing.expectApproxEqAbs(@as(f32, 0.5), Block.normalize(5.0), 0.001);
        try testing.expectApproxEqAbs(@as(f32, 1.0), Block.normalize(10.0), 0.001);
        try testing.expectApproxEqAbs(@as(f32, 0.0), Block.normalize(0.0), 0.001);
        try testing.expectApproxEqAbs(@as(f32, 1.0), Block.normalize(15.0), 0.001); // clamped
    }
};
