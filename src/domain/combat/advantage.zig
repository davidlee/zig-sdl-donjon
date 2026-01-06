//! Combat advantage types - deltas and technique-specific overrides.
//!
//! These types represent advantage effects applied after combat resolution.

const std = @import("std");
const engagement_mod = @import("engagement.zig");
const agent_mod = @import("agent.zig");

pub const Engagement = engagement_mod.Engagement;
pub const Agent = agent_mod.Agent;

/// Deltas to apply to advantage axes after technique resolution.
/// Signs: positive = toward player advantage, negative = toward mob advantage.
pub const AdvantageEffect = struct {
    pressure: f32 = 0,
    control: f32 = 0,
    position: f32 = 0,
    self_balance: f32 = 0,
    target_balance: f32 = 0,

    /// Apply advantage deltas to engagement and agent balance.
    pub fn apply(
        self: AdvantageEffect,
        eng: *Engagement,
        attacker: *Agent,
        defender: *Agent,
    ) void {
        eng.pressure = std.math.clamp(eng.pressure + self.pressure, 0, 1);
        eng.control = std.math.clamp(eng.control + self.control, 0, 1);
        eng.position = std.math.clamp(eng.position + self.position, 0, 1);
        attacker.balance = std.math.clamp(attacker.balance + self.self_balance, 0, 1);
        defender.balance = std.math.clamp(defender.balance + self.target_balance, 0, 1);
    }

    /// Scale all deltas by a multiplier (e.g., for stakes).
    pub fn scale(self: AdvantageEffect, mult: f32) AdvantageEffect {
        return .{
            .pressure = self.pressure * mult,
            .control = self.control * mult,
            .position = self.position * mult,
            .self_balance = self.self_balance * mult,
            .target_balance = self.target_balance * mult,
        };
    }
};

/// Technique-specific advantage overrides per outcome.
/// Null fields fall back to default advantage effects.
pub const TechniqueAdvantage = struct {
    on_hit: ?AdvantageEffect = null,
    on_miss: ?AdvantageEffect = null,
    on_blocked: ?AdvantageEffect = null,
    on_parried: ?AdvantageEffect = null,
    on_deflected: ?AdvantageEffect = null,
    on_dodged: ?AdvantageEffect = null,
    on_countered: ?AdvantageEffect = null,
};
