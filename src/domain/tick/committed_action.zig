const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const cards = @import("../cards.zig");
const combat = @import("../combat.zig");
const resolution = @import("../resolution.zig");

const Agent = combat.Agent;
const Technique = cards.Technique;
const Stakes = cards.Stakes;

/// A single action committed by an agent for this tick
pub const CommittedAction = struct {
    actor: *Agent,
    card: ?*cards.Instance, // null for pool-based mobs (no card instance)
    technique: *const Technique,
    expression: ?*const cards.Expression, // the expression this action came from (for filter evaluation)
    stakes: Stakes,
    time_start: f32, // when this action begins (0.0-1.0 within tick)
    time_end: f32, // when this action ends (time_start + cost.time)
    target: ?entity.ID = null, // elected target for .single targeting (from Play.target)
    // From Play modifiers (set during commit phase)
    damage_mult: f32 = 1.0,
    advantage_override: ?combat.TechniqueAdvantage = null,

    /// Compare by time_start for sorting
    pub fn compareByTime(_: void, a: CommittedAction, b: CommittedAction) bool {
        return a.time_start < b.time_start;
    }
};

/// Result of a single interaction
pub const ResolutionEntry = struct {
    attacker_id: entity.ID,
    defender_id: entity.ID,
    technique_id: cards.TechniqueID,
    outcome: resolution.Outcome,
    damage_dealt: f32, // 0 if miss/blocked
};

/// Collection of resolution results for a tick
pub const TickResult = struct {
    alloc: std.mem.Allocator,
    resolutions: std.ArrayList(ResolutionEntry),

    pub fn init(alloc: std.mem.Allocator) !TickResult {
        return .{
            .alloc = alloc,
            .resolutions = try std.ArrayList(ResolutionEntry).initCapacity(alloc, 8),
        };
    }

    pub fn deinit(self: *TickResult) void {
        self.resolutions.deinit(self.alloc);
    }
};
