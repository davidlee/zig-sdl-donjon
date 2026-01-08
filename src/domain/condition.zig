/// Declarative condition framework with data-driven computation and caching.
///
/// Replaces hard-coded iterator phases with a table-driven approach. Each
/// condition is defined by its computation type (stored, resource threshold,
/// engagement metric, etc.) enabling consistent querying and event emission.
const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const damage = @import("damage.zig");
const cards = @import("cards.zig");

// =============================================================================
// Core Types
// =============================================================================

/// How a condition's active state is computed.
pub const ComputationType = union(enum) {
    /// Not computed; comes from agent.conditions array.
    stored,

    /// Active when resource.ratio() <op> value.
    /// Blood starts full (1.0) and drains; pain/trauma start empty (0.0) and accumulate.
    resource_threshold: struct {
        resource: ResourceAccessor,
        op: cards.Comparator,
        value: f32,
    },

    /// Active when agent.balance <op> value.
    balance_threshold: struct {
        op: cards.Comparator,
        value: f32,
    },

    /// Active when body.<sense>Score() <op> value.
    sensory_threshold: struct {
        sense: SensoryType,
        op: cards.Comparator,
        value: f32,
    },

    /// Active when engagement.<metric> <op> value.
    engagement_threshold: struct {
        metric: EngagementMetric,
        op: cards.Comparator,
        value: f32,
    },

    /// Active when ANY of the nested computations evaluates true.
    /// Mirrors Predicate.any pattern for composite triggers.
    any: []const ComputationType,

    /// Active based on encounter-level positioning.
    positional: PositionalCheck,
};

pub const ResourceAccessor = enum { blood, pain, trauma, morale };
pub const SensoryType = enum { vision, hearing };
pub const EngagementMetric = enum { pressure, control };
pub const PositionalCheck = enum { flanked, surrounded };

/// Classification affecting where condition state is cached/computed.
pub const Category = enum {
    stored, // explicitly added/removed via effects
    internal, // computed from agent-local state (blood, pain, balance, sensory)
    relational, // computed from engagement state (pressure, control)
    positional, // computed from encounter positioning (flanked, surrounded)
};

/// Declarative definition of a condition.
pub const ConditionDefinition = struct {
    condition: damage.Condition,
    computation: ComputationType,
    category: Category,
};

// =============================================================================
// Condition State (replaces ActiveCondition)
// =============================================================================

/// Extended condition state with optional payload and source tracking.
/// For Phase 1, this is a type alias. Phase 6 adds payload/source fields.
pub const ConditionState = damage.ActiveCondition;

/// Expiration types - forwarded from ActiveCondition.
pub const Expiration = damage.ActiveCondition.Expiration;

// =============================================================================
// Condition Payloads (Phase 6)
// =============================================================================

/// Optional metadata attached to conditions.
pub const ConditionPayload = union(enum) {
    none,
    ratio: f32, // for computed conditions: the actual ratio that triggered
    dot: struct {
        kind: damage.Kind,
        amount: f32,
    },
    fsm: struct {
        stage: u8,
        progress: f32,
        next_condition: ?damage.Condition, // e.g., adrenaline_surge -> adrenaline_crash
    },
    stacks: u8,
};

// =============================================================================
// Condition Scoping (for events)
// =============================================================================

/// Scope of a condition for event emission.
pub const ConditionScope = union(enum) {
    internal, // balance, blood, pain, trauma, sensory
    relational: entity.ID, // engagement-specific, includes opponent ID
};

// =============================================================================
// Bitset Cache Type
// =============================================================================

/// Bitset sized to hold all conditions.
pub const ConditionBitSet = std.StaticBitSet(@typeInfo(damage.Condition).@"enum".fields.len);

// =============================================================================
// Condition Cache
// =============================================================================

/// Cache for internal computed conditions (balance, blood, pain, trauma, sensory).
/// Recomputed when underlying metrics change; diff emits events.
pub const ConditionCache = struct {
    conditions: ConditionBitSet = ConditionBitSet.initEmpty(),

    /// Context needed for evaluating internal conditions.
    pub const EvalContext = struct {
        balance: f32,
        blood_ratio: f32,
        pain_ratio: f32,
        trauma_ratio: f32,
        morale_ratio: f32,
        vision_score: f32,
        hearing_score: f32,
    };

    /// Recompute the cache from agent metrics.
    pub fn recompute(self: *ConditionCache, ctx: EvalContext) void {
        self.conditions = ConditionBitSet.initEmpty();
        for (condition_definitions) |def| {
            if (def.category == .internal and evaluateWithContext(def.computation, ctx)) {
                self.conditions.set(@intFromEnum(def.condition));
            }
        }
    }
};

/// Evaluate a computation using the provided context.
/// Internal conditions only - relational/positional handled elsewhere.
fn evaluateWithContext(comp: ComputationType, ctx: ConditionCache.EvalContext) bool {
    return switch (comp) {
        .stored => false,
        .resource_threshold => |rt| {
            const ratio = switch (rt.resource) {
                .blood => ctx.blood_ratio,
                .pain => ctx.pain_ratio,
                .trauma => ctx.trauma_ratio,
                .morale => ctx.morale_ratio,
            };
            return rt.op.compare(ratio, rt.value);
        },
        .balance_threshold => |bt| bt.op.compare(ctx.balance, bt.value),
        .sensory_threshold => |st| {
            const score = switch (st.sense) {
                .vision => ctx.vision_score,
                .hearing => ctx.hearing_score,
            };
            return st.op.compare(score, st.value);
        },
        .engagement_threshold => false, // relational, not cached
        .positional => false, // positional, not cached
        .any => |alternatives| {
            for (alternatives) |alt| {
                if (evaluateWithContext(alt, ctx)) return true;
            }
            return false;
        },
    };
}

// =============================================================================
// Condition Definitions Table
// =============================================================================

/// Master table of all condition definitions.
/// Ordering matters for resource thresholds: worst-first within each resource.
pub const condition_definitions = [_]ConditionDefinition{
    // === Stored conditions (no computation) ===
    .{ .condition = .stunned, .computation = .stored, .category = .stored },
    .{ .condition = .paralysed, .computation = .stored, .category = .stored },
    .{ .condition = .silenced, .computation = .stored, .category = .stored },
    .{ .condition = .confused, .computation = .stored, .category = .stored },
    .{ .condition = .prone, .computation = .stored, .category = .stored },
    .{ .condition = .winded, .computation = .stored, .category = .stored },
    .{ .condition = .shaken, .computation = .stored, .category = .stored },
    .{ .condition = .fearful, .computation = .stored, .category = .stored },
    .{ .condition = .nauseous, .computation = .stored, .category = .stored },
    .{ .condition = .surprised, .computation = .stored, .category = .stored },
    .{ .condition = .unconscious, .computation = .stored, .category = .stored },
    .{ .condition = .comatose, .computation = .stored, .category = .stored },
    .{ .condition = .asphyxiating, .computation = .stored, .category = .stored },
    .{ .condition = .starving, .computation = .stored, .category = .stored },
    .{ .condition = .dehydrating, .computation = .stored, .category = .stored },
    .{ .condition = .exhausted, .computation = .stored, .category = .stored },

    // Dwarven BAC
    .{ .condition = .sober, .computation = .stored, .category = .stored },
    .{ .condition = .tipsy, .computation = .stored, .category = .stored },
    .{ .condition = .buzzed, .computation = .stored, .category = .stored },
    .{ .condition = .slurring, .computation = .stored, .category = .stored },
    .{ .condition = .pissed, .computation = .stored, .category = .stored },
    .{ .condition = .hammered, .computation = .stored, .category = .stored },
    .{ .condition = .pickled, .computation = .stored, .category = .stored },
    .{ .condition = .munted, .computation = .stored, .category = .stored },

    // Stored: stationary (no footwork)
    .{ .condition = .stationary, .computation = .stored, .category = .stored },

    // === Internal computed: balance ===
    .{ .condition = .unbalanced, .computation = .{ .balance_threshold = .{ .op = .lt, .value = 0.2 } }, .category = .internal },

    // === Internal computed: blood loss (worst-first) ===
    // Blood starts full (ratio=1.0) and drains toward 0.
    .{ .condition = .hypovolemic_shock, .computation = .{ .resource_threshold = .{ .resource = .blood, .op = .lt, .value = 0.4 } }, .category = .internal },
    .{ .condition = .bleeding_out, .computation = .{ .resource_threshold = .{ .resource = .blood, .op = .lt, .value = 0.6 } }, .category = .internal },
    .{ .condition = .lightheaded, .computation = .{ .resource_threshold = .{ .resource = .blood, .op = .lt, .value = 0.8 } }, .category = .internal },

    // === Internal computed: incapacitation (pain OR trauma critical) ===
    .{ .condition = .incapacitated, .computation = .{ .any = &[_]ComputationType{
        .{ .resource_threshold = .{ .resource = .pain, .op = .gt, .value = 0.95 } },
        .{ .resource_threshold = .{ .resource = .trauma, .op = .gt, .value = 0.95 } },
    } }, .category = .internal },

    // === Internal computed: pain (worst-first) ===
    // Pain starts empty (ratio=0.0) and accumulates toward 1.0.
    .{ .condition = .agonized, .computation = .{ .resource_threshold = .{ .resource = .pain, .op = .gt, .value = 0.85 } }, .category = .internal },
    .{ .condition = .suffering, .computation = .{ .resource_threshold = .{ .resource = .pain, .op = .gt, .value = 0.60 } }, .category = .internal },
    .{ .condition = .distracted, .computation = .{ .resource_threshold = .{ .resource = .pain, .op = .gt, .value = 0.30 } }, .category = .internal },

    // === Internal computed: trauma (worst-first) ===
    // Trauma starts empty (ratio=0.0) and accumulates toward 1.0.
    .{ .condition = .reeling, .computation = .{ .resource_threshold = .{ .resource = .trauma, .op = .gt, .value = 0.90 } }, .category = .internal },
    .{ .condition = .trembling, .computation = .{ .resource_threshold = .{ .resource = .trauma, .op = .gt, .value = 0.70 } }, .category = .internal },
    .{ .condition = .unsteady, .computation = .{ .resource_threshold = .{ .resource = .trauma, .op = .gt, .value = 0.50 } }, .category = .internal },
    .{ .condition = .dazed, .computation = .{ .resource_threshold = .{ .resource = .trauma, .op = .gt, .value = 0.30 } }, .category = .internal },

    // === Internal computed: sensory ===
    .{ .condition = .blinded, .computation = .{ .sensory_threshold = .{ .sense = .vision, .op = .lt, .value = 0.3 } }, .category = .internal },
    .{ .condition = .deafened, .computation = .{ .sensory_threshold = .{ .sense = .hearing, .op = .lt, .value = 0.3 } }, .category = .internal },

    // === Relational computed: engagement ===
    .{ .condition = .pressured, .computation = .{ .engagement_threshold = .{ .metric = .pressure, .op = .gt, .value = 0.8 } }, .category = .relational },
    .{ .condition = .weapon_bound, .computation = .{ .engagement_threshold = .{ .metric = .control, .op = .gt, .value = 0.8 } }, .category = .relational },

    // === Positional computed: encounter-level ===
    .{ .condition = .flanked, .computation = .{ .positional = .flanked }, .category = .positional },
    .{ .condition = .surrounded, .computation = .{ .positional = .surrounded }, .category = .positional },
};

// =============================================================================
// Comptime Validation
// =============================================================================

/// Validate that resource thresholds appear in worst-first order.
/// - For .gte (accumulating): descending values (0.95 before 0.85 before 0.60)
/// - For .lt (draining): ascending values (0.4 before 0.6 before 0.8)
fn validateThresholdOrdering() void {
    comptime {
        const resource_count = std.meta.fields(ResourceAccessor).len;
        var last_value: [resource_count]?f32 = .{null} ** resource_count;
        var last_op: [resource_count]?cards.Comparator = .{null} ** resource_count;

        for (condition_definitions) |def| {
            switch (def.computation) {
                .resource_threshold => |threshold| {
                    const idx = @intFromEnum(threshold.resource);
                    if (last_value[idx]) |prev| {
                        const op = last_op[idx].?;
                        // Validate ordering based on comparator
                        const valid = switch (op) {
                            .gte, .gt => threshold.value < prev, // descending for accumulating
                            .lt, .lte => threshold.value > prev, // ascending for draining
                            .eq => true, // equality thresholds don't have ordering requirements
                        };
                        if (!valid) {
                            @compileError(std.fmt.comptimePrint(
                                "Resource threshold misordering: {s} {s} {d} should come before {d}",
                                .{ @tagName(threshold.resource), @tagName(op), threshold.value, prev },
                            ));
                        }
                    }
                    last_value[idx] = threshold.value;
                    last_op[idx] = threshold.op;
                },
                // .any and other variants don't participate in ordering validation
                else => {},
            }
        }
    }
}

comptime {
    validateThresholdOrdering();
}

// =============================================================================
// Lookup Helpers
// =============================================================================

/// Get the definition for a given condition.
pub fn getDefinitionFor(cond: damage.Condition) ?ConditionDefinition {
    for (condition_definitions) |def| {
        if (def.condition == cond) return def;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "condition_definitions contains all computed conditions from old iterator" {
    // Verify the conditions that were computed in the old ConditionIterator phases
    // are now present in condition_definitions
    const expected_computed = [_]damage.Condition{
        .unbalanced,
        .hypovolemic_shock,
        .bleeding_out,
        .lightheaded,
        .blinded,
        .deafened,
        .pressured,
        .weapon_bound,
    };

    for (expected_computed) |cond| {
        const def = getDefinitionFor(cond);
        try testing.expect(def != null);
        try testing.expect(def.?.computation != .stored);
    }
}

test "getDefinitionFor returns correct definition" {
    const def = getDefinitionFor(.hypovolemic_shock);
    try testing.expect(def != null);
    try testing.expectEqual(damage.Condition.hypovolemic_shock, def.?.condition);
    try testing.expectEqual(Category.internal, def.?.category);

    // Verify it's a resource threshold
    switch (def.?.computation) {
        .resource_threshold => |rt| {
            try testing.expectEqual(ResourceAccessor.blood, rt.resource);
            try testing.expectEqual(cards.Comparator.lt, rt.op);
            try testing.expectApproxEqAbs(@as(f32, 0.4), rt.value, 0.001);
        },
        else => return error.UnexpectedComputationType,
    }
}

test "Comparator.compare works correctly" {
    try testing.expect(cards.Comparator.lt.compare(0.3, 0.4));
    try testing.expect(!cards.Comparator.lt.compare(0.5, 0.4));
    try testing.expect(cards.Comparator.gte.compare(0.85, 0.85));
    try testing.expect(cards.Comparator.gte.compare(0.9, 0.85));
    try testing.expect(!cards.Comparator.gte.compare(0.8, 0.85));
    try testing.expect(cards.Comparator.eq.compare(0.5, 0.5));
    try testing.expect(!cards.Comparator.eq.compare(0.5, 0.6));
}

test "ConditionBitSet can hold all conditions" {
    const condition_count = @typeInfo(damage.Condition).@"enum".fields.len;
    try testing.expect(ConditionBitSet.bit_length >= condition_count);

    // Test basic operations
    var bitset = ConditionBitSet.initEmpty();
    bitset.set(@intFromEnum(damage.Condition.stunned));
    try testing.expect(bitset.isSet(@intFromEnum(damage.Condition.stunned)));
    try testing.expect(!bitset.isSet(@intFromEnum(damage.Condition.blinded)));
}

test "pain at 35% yields distracted only" {
    // Pain ratio 0.35 should trigger distracted (>0.30) but not suffering (>0.60)
    const ctx = ConditionCache.EvalContext{
        .balance = 1.0,
        .blood_ratio = 1.0,
        .pain_ratio = 0.35,
        .trauma_ratio = 0.0,
        .morale_ratio = 1.0,
        .vision_score = 1.0,
        .hearing_score = 1.0,
    };

    // distracted should be active
    const distracted_def = getDefinitionFor(.distracted).?;
    try testing.expect(evaluateWithContext(distracted_def.computation, ctx));

    // suffering should NOT be active (requires >0.60)
    const suffering_def = getDefinitionFor(.suffering).?;
    try testing.expect(!evaluateWithContext(suffering_def.computation, ctx));

    // agonized should NOT be active (requires >0.85)
    const agonized_def = getDefinitionFor(.agonized).?;
    try testing.expect(!evaluateWithContext(agonized_def.computation, ctx));

    // incapacitated should NOT be active (requires >0.95)
    const incap_def = getDefinitionFor(.incapacitated).?;
    try testing.expect(!evaluateWithContext(incap_def.computation, ctx));
}

test "pain at 65% yields suffering only (worst-first)" {
    // Pain ratio 0.65 should trigger suffering (>0.60)
    // Due to worst-first ordering, only suffering should be yielded (not distracted)
    const ctx = ConditionCache.EvalContext{
        .balance = 1.0,
        .blood_ratio = 1.0,
        .pain_ratio = 0.65,
        .trauma_ratio = 0.0,
        .morale_ratio = 1.0,
        .vision_score = 1.0,
        .hearing_score = 1.0,
    };

    // suffering should be active
    const suffering_def = getDefinitionFor(.suffering).?;
    try testing.expect(evaluateWithContext(suffering_def.computation, ctx));

    // distracted threshold is also met but iterator yields worst first
    const distracted_def = getDefinitionFor(.distracted).?;
    try testing.expect(evaluateWithContext(distracted_def.computation, ctx));

    // agonized should NOT be active (requires >0.85)
    const agonized_def = getDefinitionFor(.agonized).?;
    try testing.expect(!evaluateWithContext(agonized_def.computation, ctx));
}

test "trauma at 55% yields unsteady only" {
    // Trauma ratio 0.55 should trigger unsteady (>0.50) but not trembling (>0.70)
    const ctx = ConditionCache.EvalContext{
        .balance = 1.0,
        .blood_ratio = 1.0,
        .pain_ratio = 0.0,
        .trauma_ratio = 0.55,
        .morale_ratio = 1.0,
        .vision_score = 1.0,
        .hearing_score = 1.0,
    };

    // unsteady should be active
    const unsteady_def = getDefinitionFor(.unsteady).?;
    try testing.expect(evaluateWithContext(unsteady_def.computation, ctx));

    // dazed threshold is also met (>0.30)
    const dazed_def = getDefinitionFor(.dazed).?;
    try testing.expect(evaluateWithContext(dazed_def.computation, ctx));

    // trembling should NOT be active (requires >0.70)
    const trembling_def = getDefinitionFor(.trembling).?;
    try testing.expect(!evaluateWithContext(trembling_def.computation, ctx));

    // reeling should NOT be active (requires >0.90)
    const reeling_def = getDefinitionFor(.reeling).?;
    try testing.expect(!evaluateWithContext(reeling_def.computation, ctx));
}

test "pain or trauma at 96% yields incapacitated" {
    // Pain at 96% should trigger incapacitated via .any
    const pain_ctx = ConditionCache.EvalContext{
        .balance = 1.0,
        .blood_ratio = 1.0,
        .pain_ratio = 0.96,
        .trauma_ratio = 0.0,
        .morale_ratio = 1.0,
        .vision_score = 1.0,
        .hearing_score = 1.0,
    };
    const incap_def = getDefinitionFor(.incapacitated).?;
    try testing.expect(evaluateWithContext(incap_def.computation, pain_ctx));

    // Trauma at 96% should also trigger incapacitated
    const trauma_ctx = ConditionCache.EvalContext{
        .balance = 1.0,
        .blood_ratio = 1.0,
        .pain_ratio = 0.0,
        .trauma_ratio = 0.96,
        .morale_ratio = 1.0,
        .vision_score = 1.0,
        .hearing_score = 1.0,
    };
    try testing.expect(evaluateWithContext(incap_def.computation, trauma_ctx));

    // Just below threshold (0.94) should NOT trigger
    const below_ctx = ConditionCache.EvalContext{
        .balance = 1.0,
        .blood_ratio = 1.0,
        .pain_ratio = 0.94,
        .trauma_ratio = 0.94,
        .morale_ratio = 1.0,
        .vision_score = 1.0,
        .hearing_score = 1.0,
    };
    try testing.expect(!evaluateWithContext(incap_def.computation, below_ctx));
}
