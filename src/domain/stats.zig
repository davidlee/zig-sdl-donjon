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
};
