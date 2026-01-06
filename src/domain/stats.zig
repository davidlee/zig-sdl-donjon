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

pub const Template = Block;

const testing = std.testing;

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
};
