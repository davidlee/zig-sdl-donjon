/// Condition display helpers for combat UI.
///
/// Provides functions to iterate agent conditions, group by category,
/// and select worst per category for compact display.
const std = @import("std");
const damage = @import("../../../domain/damage.zig");
const combat = @import("../../../domain/combat.zig");
const types = @import("../types.zig");

const Color = types.Color;
const Condition = damage.Condition;
const Agent = combat.Agent;
const Engagement = combat.Engagement;

/// Condition categories for display grouping.
pub const Category = enum {
    blood,
    pain,
    trauma,
    adrenaline,
    engagement,
    sensory,
    status,
    critical,
};

/// Display info for a single condition.
pub const ConditionDisplay = struct {
    condition: Condition,
    category: Category,
    label: []const u8,
    color: Color,
    priority: u8, // higher = worse, show first
};

/// Colors for condition categories.
pub const category_colors = struct {
    pub const blood: Color = .{ .r = 255, .g = 80, .b = 80, .a = 255 }; // red
    pub const pain: Color = .{ .r = 255, .g = 160, .b = 80, .a = 255 }; // orange
    pub const trauma: Color = .{ .r = 255, .g = 220, .b = 80, .a = 255 }; // yellow
    pub const adrenaline_surge: Color = .{ .r = 80, .g = 255, .b = 120, .a = 255 }; // green
    pub const adrenaline_crash: Color = .{ .r = 180, .g = 80, .b = 255, .a = 255 }; // purple
    pub const engagement: Color = .{ .r = 100, .g = 180, .b = 255, .a = 255 }; // blue
    pub const sensory: Color = .{ .r = 160, .g = 160, .b = 160, .a = 255 }; // grey
    pub const status: Color = .{ .r = 200, .g = 200, .b = 200, .a = 255 }; // light grey
    pub const critical: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }; // white
};

/// Get display name for a condition.
pub fn conditionName(condition: Condition) []const u8 {
    return switch (condition) {
        .blinded => "BLINDED",
        .deafened => "DEAFENED",
        .silenced => "SILENCED",
        .stunned => "STUNNED",
        .paralysed => "PARALYSED",
        .confused => "CONFUSED",
        .prone => "PRONE",
        .winded => "WINDED",
        .shaken => "SHAKEN",
        .fearful => "FEARFUL",
        .nauseous => "NAUSEOUS",
        .surprised => "SURPRISED",
        .unconscious => "UNCONSCIOUS",
        .comatose => "COMATOSE",
        .asphyxiating => "ASPHYXIATING",
        .starving => "STARVING",
        .dehydrating => "DEHYDRATING",
        .exhausted => "EXHAUSTED",
        // Dwarven BAC
        .sober => "SOBER",
        .tipsy => "TIPSY",
        .buzzed => "BUZZED",
        .slurring => "SLURRING",
        .pissed => "PISSED",
        .hammered => "HAMMERED",
        .pickled => "PICKLED",
        .munted => "MUNTED",
        // Computed/relational
        .pressured => "PRESSURED",
        .weapon_bound => "BOUND",
        .unbalanced => "UNBALANCED",
        .stationary => "STATIONARY",
        .flanked => "FLANKED",
        .surrounded => "SURROUNDED",
        // Blood loss
        .lightheaded => "LIGHTHEADED",
        .bleeding_out => "BLEEDING",
        .hypovolemic_shock => "SHOCK",
        // Pain
        .distracted => "DISTRACTED",
        .suffering => "SUFFERING",
        .agonized => "AGONIZED",
        // Trauma
        .dazed => "DAZED",
        .unsteady => "UNSTEADY",
        .trembling => "TREMBLING",
        .reeling => "REELING",
        // Incapacitation
        .incapacitated => "INCAPACITATED",
        // Adrenaline
        .adrenaline_surge => "ADRENALINE",
        .adrenaline_crash => "CRASHING",
    };
}

/// Get category for a condition.
fn categoryFor(condition: Condition) Category {
    return switch (condition) {
        // Blood loss
        .lightheaded, .bleeding_out, .hypovolemic_shock => .blood,
        // Pain
        .distracted, .suffering, .agonized => .pain,
        // Trauma
        .dazed, .unsteady, .trembling, .reeling => .trauma,
        // Adrenaline
        .adrenaline_surge, .adrenaline_crash => .adrenaline,
        // Engagement
        .pressured, .weapon_bound, .unbalanced, .stationary, .flanked, .surrounded => .engagement,
        // Sensory
        .blinded, .deafened => .sensory,
        // Critical
        .incapacitated, .unconscious, .comatose => .critical,
        // Everything else is status
        else => .status,
    };
}

/// Get priority (severity) for a condition. Higher = worse.
fn priorityFor(condition: Condition) u8 {
    return switch (condition) {
        // Critical - highest priority
        .incapacitated => 100,
        .unconscious, .comatose => 95,
        // Blood - ordered by severity
        .hypovolemic_shock => 90,
        .bleeding_out => 80,
        .lightheaded => 70,
        // Pain - ordered by severity
        .agonized => 85,
        .suffering => 75,
        .distracted => 65,
        // Trauma - ordered by severity
        .reeling => 88,
        .trembling => 78,
        .unsteady => 68,
        .dazed => 58,
        // Adrenaline
        .adrenaline_crash => 60,
        .adrenaline_surge => 40, // surge is a buff, lower priority
        // Engagement
        .surrounded => 55,
        .flanked => 50,
        .pressured => 45,
        .weapon_bound => 45,
        .unbalanced => 40,
        .stationary => 30,
        // Sensory
        .blinded => 70,
        .deafened => 50,
        // Status effects - moderate priority
        .stunned, .paralysed => 85,
        .prone => 60,
        .winded => 50,
        .nauseous => 45,
        .confused => 55,
        // Low priority
        else => 20,
    };
}

/// Get color for a condition.
fn colorFor(condition: Condition) Color {
    // Special cases
    if (condition == .adrenaline_surge) return category_colors.adrenaline_surge;
    if (condition == .adrenaline_crash) return category_colors.adrenaline_crash;

    // By category
    return switch (categoryFor(condition)) {
        .blood => category_colors.blood,
        .pain => category_colors.pain,
        .trauma => category_colors.trauma,
        .adrenaline => category_colors.adrenaline_surge, // fallback
        .engagement => category_colors.engagement,
        .sensory => category_colors.sensory,
        .status => category_colors.status,
        .critical => category_colors.critical,
    };
}

/// Build display info for a condition.
fn displayFor(condition: Condition) ConditionDisplay {
    return .{
        .condition = condition,
        .category = categoryFor(condition),
        .label = conditionName(condition),
        .color = colorFor(condition),
        .priority = priorityFor(condition),
    };
}

/// Result buffer for getDisplayConditions.
pub const MaxConditions = 12;

pub const ConditionBuffer = struct {
    items: [MaxConditions]ConditionDisplay = undefined,
    len: usize = 0,

    pub fn append(self: *ConditionBuffer, item: ConditionDisplay) void {
        if (self.len < MaxConditions) {
            self.items[self.len] = item;
            self.len += 1;
        }
    }

    pub fn slice(self: *ConditionBuffer) []ConditionDisplay {
        return self.items[0..self.len];
    }

    pub fn constSlice(self: *const ConditionBuffer) []const ConditionDisplay {
        return self.items[0..self.len];
    }
};

/// Get display conditions for an agent, picking worst per category.
/// Returns conditions sorted by priority (worst first).
pub fn getDisplayConditions(agent: *const Agent, engagement_opt: ?Engagement) ConditionBuffer {
    var result = ConditionBuffer{};

    // Track worst condition per category
    var worst_by_category: [@typeInfo(Category).@"enum".fields.len]?ConditionDisplay =
        .{null} ** @typeInfo(Category).@"enum".fields.len;

    // Convert optional value to optional pointer for activeConditions
    var engagement_storage: Engagement = undefined;
    const engagement_ptr: ?*const Engagement = if (engagement_opt) |eng| blk: {
        engagement_storage = eng;
        break :blk &engagement_storage;
    } else null;

    // Iterate all active conditions
    var iter = agent.activeConditions(engagement_ptr);
    while (iter.next()) |ac| {
        const display = displayFor(ac.condition);
        const cat_idx = @intFromEnum(display.category);

        // Keep worst (highest priority) per category
        if (worst_by_category[cat_idx]) |existing| {
            if (display.priority > existing.priority) {
                worst_by_category[cat_idx] = display;
            }
        } else {
            worst_by_category[cat_idx] = display;
        }
    }

    // Collect non-null entries
    for (worst_by_category) |maybe_display| {
        if (maybe_display) |display| {
            result.append(display);
        }
    }

    // Sort by priority (highest first)
    std.mem.sort(ConditionDisplay, result.slice(), {}, struct {
        fn lessThan(_: void, a: ConditionDisplay, b: ConditionDisplay) bool {
            return a.priority > b.priority; // descending
        }
    }.lessThan);

    return result;
}

/// Check if agent is incapacitated (for special rendering).
pub fn isIncapacitated(agent: *const Agent) bool {
    return agent.hasCondition(.incapacitated) or
        agent.hasCondition(.unconscious) or
        agent.hasCondition(.comatose);
}

// ============================================================================
// Tests
// ============================================================================

test "categoryFor returns correct categories" {
    const testing = std.testing;

    try testing.expectEqual(Category.blood, categoryFor(.bleeding_out));
    try testing.expectEqual(Category.pain, categoryFor(.agonized));
    try testing.expectEqual(Category.trauma, categoryFor(.trembling));
    try testing.expectEqual(Category.adrenaline, categoryFor(.adrenaline_surge));
    try testing.expectEqual(Category.engagement, categoryFor(.pressured));
    try testing.expectEqual(Category.sensory, categoryFor(.blinded));
    try testing.expectEqual(Category.critical, categoryFor(.incapacitated));
}

test "priorityFor orders conditions correctly" {
    const testing = std.testing;

    // Incapacitated is highest
    try testing.expect(priorityFor(.incapacitated) > priorityFor(.agonized));
    // Pain ordering
    try testing.expect(priorityFor(.agonized) > priorityFor(.suffering));
    try testing.expect(priorityFor(.suffering) > priorityFor(.distracted));
    // Trauma ordering
    try testing.expect(priorityFor(.reeling) > priorityFor(.trembling));
    try testing.expect(priorityFor(.trembling) > priorityFor(.unsteady));
}
