//! Combat engagement - relational state between combatants.
//!
//! Engagement tracks pressure, control, and position between two agents.
//! AgentPair provides canonical ordering for engagement lookups.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const types = @import("types.zig");

pub const Reach = types.Reach;

/// Canonical pair of agent IDs for engagement lookups.
/// Lower index is always stored as 'a' to ensure consistent hashing.
pub const AgentPair = struct {
    a: entity.ID, // lower index
    b: entity.ID, // higher index

    pub fn canonical(x: entity.ID, y: entity.ID) AgentPair {
        std.debug.assert(x.index != y.index); // self-engagement is invalid
        return if (x.index < y.index)
            .{ .a = x, .b = y }
        else
            .{ .a = y, .b = x };
    }
};

/// Per-engagement relational state between two agents.
/// All values 0-1, where 0.5 = neutral.
/// >0.5 = player/first agent advantage, <0.5 = opponent advantage.
pub const Engagement = struct {
    pressure: f32 = 0.5,
    control: f32 = 0.5,
    position: f32 = 0.5,
    range: Reach = .sabre, // Current distance

    /// Compute overall advantage for the player/first agent.
    pub fn playerAdvantage(self: Engagement) f32 {
        return (self.pressure + self.control + self.position) / 3.0;
    }

    /// Compute overall advantage for the opponent.
    pub fn mobAdvantage(self: Engagement) f32 {
        return 1.0 - self.playerAdvantage();
    }

    /// Return engagement from opponent's perspective.
    pub fn invert(self: Engagement) Engagement {
        return .{
            .pressure = 1.0 - self.pressure,
            .control = 1.0 - self.control,
            .position = 1.0 - self.position,
            .range = self.range,
        };
    }
};

/// Flanking status derived from engagement count and position values.
pub const FlankingStatus = enum {
    none, // single opponent or controlled positioning
    partial, // 2 opponents with some angle disadvantage
    surrounded, // 3+ opponents or severe angle disadvantage
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "AgentPair.canonical produces consistent key regardless of order" {
    const id_low = entity.ID{ .index = 1, .generation = 0 };
    const id_high = entity.ID{ .index = 5, .generation = 0 };

    const pair_ab = AgentPair.canonical(id_low, id_high);
    const pair_ba = AgentPair.canonical(id_high, id_low);

    try testing.expectEqual(pair_ab.a.index, pair_ba.a.index);
    try testing.expectEqual(pair_ab.b.index, pair_ba.b.index);
    try testing.expectEqual(@as(u32, 1), pair_ab.a.index);
    try testing.expectEqual(@as(u32, 5), pair_ab.b.index);
}

test "Engagement.invert mirrors values" {
    const eng = Engagement{
        .pressure = 0.7,
        .control = 0.3,
        .position = 0.6,
        .range = .sabre,
    };
    const inv = eng.invert();

    try testing.expectApproxEqAbs(@as(f32, 0.3), inv.pressure, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), inv.control, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), inv.position, 0.001);
    try testing.expectEqual(Reach.sabre, inv.range);
}

test "Engagement.playerAdvantage averages axes" {
    const eng = Engagement{
        .pressure = 0.6,
        .control = 0.4,
        .position = 0.8,
    };
    try testing.expectApproxEqAbs(@as(f32, 0.6), eng.playerAdvantage(), 0.001);
}
