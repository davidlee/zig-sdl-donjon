# T018: Condition Definition & Computed-State Framework - Design

**Related**: `doc/issues/conditions.md`, `kanban/doing/T018.md`, `kanban/doing/T012.md`

## Summary

Refactor the condition system from hard-coded iterator phases to a declarative, data-driven framework with proper caching and event emission for computed states.

---

## Current Pain Points (recap)

1. **Hard-coded iterator**: 8-phase switch in `ConditionIterator.next()` (`agent.zig:310-372`)
2. **No metadata**: `ActiveCondition` only carries condition + expiration
3. **Blind predicates**: `hasCondition()` ignores computed states
4. **Missing events**: Computed conditions only diffed at end-of-turn with `engagement: null`
5. **Fixed buffer**: `ConditionSet[8]` will overflow as conditions grow

---

## Design Goals

1. Table-driven condition definitions - adding conditions = adding rows, not editing switches
2. Unified querying - `hasCondition` works for stored and computed states
3. Event emission for all condition transitions (including engagement-dependent)
4. Payload support for metadata (ratios, DoTs, FSM stages, stacks)
5. Development-mode cache validation

---

## Module Structure

New `src/domain/condition.zig` module containing:

```
condition.zig
├── ConditionDefinition      -- declarative definition table entry
├── ComputationType          -- how a condition is computed
├── ConditionPayload         -- optional metadata union
├── ConditionState           -- replaces ActiveCondition (condition + expiration + payload + source)
├── ConditionBitSet          -- type alias for StaticBitSet(Condition count)
├── ConditionCache           -- internal bitset cache per agent
├── EngagementConditionCache -- relational bitset cache (lives on Engagement)
├── ConditionIterator        -- data-driven iterator over definitions
└── condition_definitions    -- comptime table of all definitions
```

**Coupling**: `condition.zig` imports `damage.zig` for `Condition` enum and `CombatPenalties`. The enum stays in `damage.zig` since it's referenced by the penalty table there.

---

## Core Types

### ConditionDefinition

```zig
pub const ConditionDefinition = struct {
    condition: damage.Condition,
    computation: ComputationType,
    category: Category,

    pub const Category = enum {
        stored,      // explicitly added/removed via effects
        internal,    // computed from agent-local state (blood, pain, balance, sensory)
        relational,  // computed from engagement state (pressure, control)
        positional,  // computed from encounter positioning (flanked, surrounded)
    };
};
```

### ComputationType

Uses `cards.Comparator` (`lt, lte, eq, gte, gt`) consistently with existing predicate patterns like `Predicate.advantage_threshold`.

```zig
pub const ComputationType = union(enum) {
    stored,  // not computed; comes from agent.conditions array

    /// Active when resource.ratio() <op> value.
    /// Examples:
    ///   blood < 0.4 → hypovolemic_shock
    ///   pain >= 0.85 → agonized
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

    /// Active based on encounter-level positioning (flanking status).
    /// Computed on-demand via Encounter.assessFlanking().
    positional: PositionalCheck,
};

pub const PositionalCheck = enum {
    flanked,     // FlankingStatus.partial or .surrounded
    surrounded,  // FlankingStatus.surrounded only
};

pub const ResourceAccessor = enum { blood, pain, trauma, morale };
pub const SensoryType = enum { vision, hearing };
pub const EngagementMetric = enum { pressure, control };
```

**Self-describing semantics**: Each threshold reads exactly as its condition:
- `{ .resource = .blood, .op = .lt, .value = 0.4 }` → "blood ratio < 40%"
- `{ .resource = .pain, .op = .gte, .value = 0.85 }` → "pain ratio ≥ 85%"
- `{ .any = &.{ rt_pain_95, rt_trauma_95 } }` → "pain ≥ 95% OR trauma ≥ 95%"

No implicit inversions or magic conventions. The `.any` pattern mirrors `Predicate.any` for composite triggers.

### ConditionState (replaces ActiveCondition)

```zig
pub const ConditionState = struct {
    condition: damage.Condition,
    expiration: Expiration,
    payload: ConditionPayload = .none,
    source: ?entity.ID = null,  // who/what applied it

    pub const Expiration = union(enum) {
        dynamic,         // derived state - recomputed each query
        permanent,       // until dispelled/removed
        ticks: f32,      // countdown
        end_of_action,
        end_of_tick,
        end_of_combat,
    };
};

pub const ConditionPayload = union(enum) {
    none,
    ratio: f32,               // for computed conditions: the actual ratio that triggered
    dot: struct {
        kind: damage.Kind,
        amount: f32,
    },
    fsm: struct {
        stage: u8,
        progress: f32,
        next_condition: ?damage.Condition,  // e.g., adrenaline_surge -> adrenaline_crash
    },
    stacks: u8,
};
```

**T012 integration**: Pain/trauma conditions use `.ratio` payload to communicate the current ratio for UI/logging. The threshold that triggered is implicit from the condition itself (since table is ordered worst-first, we know which threshold matched).

---

## Condition Definitions Table

```zig
pub const condition_definitions = [_]ConditionDefinition{
    // === Stored conditions (no computation) ===
    .{ .condition = .stunned, .computation = .stored, .category = .stored },
    .{ .condition = .paralysed, .computation = .stored, .category = .stored },
    // ... all explicitly-applied conditions ...

    // === Internal computed: balance ===
    .{ .condition = .unbalanced, .computation = .{ .balance_threshold = .{ .op = .lt, .value = 0.2 } }, .category = .internal },

    // === Internal computed: blood loss (worst-first) ===
    // Blood starts full (ratio=1.0) and drains toward 0. Explicit .lt comparator.
    .{ .condition = .hypovolemic_shock, .computation = .{ .resource_threshold = .{ .resource = .blood, .op = .lt, .value = 0.4 } }, .category = .internal },
    .{ .condition = .bleeding_out, .computation = .{ .resource_threshold = .{ .resource = .blood, .op = .lt, .value = 0.6 } }, .category = .internal },
    .{ .condition = .lightheaded, .computation = .{ .resource_threshold = .{ .resource = .blood, .op = .lt, .value = 0.8 } }, .category = .internal },

    // === Internal computed: incapacitation (from either pain OR trauma) ===
    // Uses .any to mirror Predicate.any pattern - single condition, multiple triggers.
    .{ .condition = .incapacitated, .computation = .{ .any = &.{
        .{ .resource_threshold = .{ .resource = .pain, .op = .gte, .value = 0.95 } },
        .{ .resource_threshold = .{ .resource = .trauma, .op = .gte, .value = 0.95 } },
    } }, .category = .internal },

    // === Internal computed: pain (worst-first, T012) ===
    // Pain starts empty (ratio=0.0) and accumulates toward 1.0. Explicit .gte comparator.
    .{ .condition = .agonized, .computation = .{ .resource_threshold = .{ .resource = .pain, .op = .gte, .value = 0.85 } }, .category = .internal },
    .{ .condition = .suffering, .computation = .{ .resource_threshold = .{ .resource = .pain, .op = .gte, .value = 0.60 } }, .category = .internal },
    .{ .condition = .distracted, .computation = .{ .resource_threshold = .{ .resource = .pain, .op = .gte, .value = 0.30 } }, .category = .internal },

    // === Internal computed: trauma (worst-first, T012) ===
    // Trauma also starts empty and accumulates.
    .{ .condition = .reeling, .computation = .{ .resource_threshold = .{ .resource = .trauma, .op = .gte, .value = 0.90 } }, .category = .internal },
    .{ .condition = .trembling, .computation = .{ .resource_threshold = .{ .resource = .trauma, .op = .gte, .value = 0.70 } }, .category = .internal },
    .{ .condition = .unsteady, .computation = .{ .resource_threshold = .{ .resource = .trauma, .op = .gte, .value = 0.50 } }, .category = .internal },
    .{ .condition = .dazed, .computation = .{ .resource_threshold = .{ .resource = .trauma, .op = .gte, .value = 0.30 } }, .category = .internal },

    // === Internal computed: sensory ===
    // Vision/hearing degrade; condition when score drops below threshold.
    .{ .condition = .blinded, .computation = .{ .sensory_threshold = .{ .sense = .vision, .op = .lt, .value = 0.3 } }, .category = .internal },
    .{ .condition = .deafened, .computation = .{ .sensory_threshold = .{ .sense = .hearing, .op = .lt, .value = 0.3 } }, .category = .internal },

    // === Relational computed: engagement ===
    // Opponent pressure/control; condition when metric exceeds threshold.
    .{ .condition = .pressured, .computation = .{ .engagement_threshold = .{ .metric = .pressure, .op = .gt, .value = 0.8 } }, .category = .relational },
    .{ .condition = .weapon_bound, .computation = .{ .engagement_threshold = .{ .metric = .control, .op = .gt, .value = 0.8 } }, .category = .relational },

    // === Positional computed: encounter-level ===
    // Based on Encounter.assessFlanking() - computed on-demand, no cache.
    .{ .condition = .flanked, .computation = .{ .positional = .flanked }, .category = .positional },
    .{ .condition = .surrounded, .computation = .{ .positional = .surrounded }, .category = .positional },
};
```

**Readability**: Each row now reads naturally without hidden semantics:
- `blood .lt 0.4` → "hypovolemic shock when blood below 40%"
- `pain .gte 0.85` → "agonized when pain at or above 85%"
- `vision .lt 0.3` → "blinded when vision score below 30%"

### Comptime Table Validation

The iterator's worst-first logic relies on table ordering. Validate this invariant at compile time to catch accidental misordering:

```zig
/// Validate that resource thresholds appear in worst-first order.
/// - For .gte (accumulating): descending values (0.95 before 0.85 before 0.60)
/// - For .lt (draining): ascending values (0.4 before 0.6 before 0.8)
fn validateThresholdOrdering() void {
    comptime {
        var last_value: [std.meta.fields(ResourceAccessor).len]?f32 = .{null} ** std.meta.fields(ResourceAccessor).len;
        var last_op: [std.meta.fields(ResourceAccessor).len]?cards.Comparator = .{null} ** std.meta.fields(ResourceAccessor).len;

        for (condition_definitions) |def| {
            const rt = switch (def.computation) {
                .resource_threshold => |r| r,
                .any => |alts| blk: {
                    // For .any, validate each nested threshold independently
                    for (alts) |alt| {
                        if (alt == .resource_threshold) {
                            // Nested thresholds in .any don't participate in ordering
                            // (they're alternatives, not a sequence)
                        }
                    }
                    break :blk null;
                },
                else => null,
            };

            if (rt) |threshold| {
                const idx = @intFromEnum(threshold.resource);
                if (last_value[idx]) |prev| {
                    const op = last_op[idx].?;
                    // Validate ordering based on comparator
                    const valid = switch (op) {
                        .gte, .gt => threshold.value < prev,  // descending for accumulating
                        .lt, .lte => threshold.value > prev,  // ascending for draining
                        .eq => true,  // equality thresholds don't have ordering requirements
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
            }
        }
    }
}

comptime {
    validateThresholdOrdering();
}
```

This catches at compile time if someone accidentally puts `.distracted` (30%) before `.agonized` (85%).

---

## Condition Caching

### Internal Cache (on Agent)

```zig
pub const ConditionCache = struct {
    conditions: ConditionBitSet,

    pub fn recompute(self: *ConditionCache, agent: *const Agent) void {
        self.conditions = ConditionBitSet.initEmpty();
        for (condition_definitions) |def| {
            if (def.category == .internal and evaluate(def.computation, .{ .agent = agent })) {
                self.conditions.set(@intFromEnum(def.condition));
            }
        }
    }
};

/// Context for condition evaluation - different condition types need different context.
pub const EvalContext = struct {
    agent: *const Agent,
    engagement: ?*const Engagement = null,  // for relational conditions
    encounter: ?*const Encounter = null,    // for positional conditions
};

/// Evaluate whether a computation is active for the given context.
/// Uses cards.Comparator.compare() for all threshold checks.
fn evaluate(comp: ComputationType, ctx: EvalContext) bool {
    return switch (comp) {
        .stored => false,  // stored conditions not in cache
        .resource_threshold => |rt| rt.op.compare(ctx.agent.getResourceRatio(rt.resource), rt.value),
        .balance_threshold => |bt| bt.op.compare(ctx.agent.balance, bt.value),
        .sensory_threshold => |st| blk: {
            const score = switch (st.sense) {
                .vision => ctx.agent.body.visionScore(),
                .hearing => ctx.agent.body.hearingScore(),
            };
            break :blk st.op.compare(score, st.value);
        },
        .engagement_threshold => |et| if (ctx.engagement) |eng| blk: {
            const metric = switch (et.metric) {
                .pressure => eng.pressure,
                .control => eng.control,
            };
            break :blk et.op.compare(metric, et.value);
        } else false,
        .positional => |pc| if (ctx.encounter) |enc| blk: {
            const status = enc.assessFlanking(ctx.agent.id);
            break :blk switch (pc) {
                .flanked => status == .partial or status == .surrounded,
                .surrounded => status == .surrounded,
            };
        } else false,
        .any => |alternatives| {
            for (alternatives) |alt| {
                if (evaluate(alt, ctx)) return true;
            }
            return false;
        },
    };
}
```

**Note**: `cards.Comparator` currently has no `compare` method. T018 should add one:

```zig
pub const Comparator = enum {
    lt, lte, eq, gte, gt,

    pub fn compare(self: Comparator, lhs: f32, rhs: f32) bool {
        return switch (self) {
            .lt => lhs < rhs,
            .lte => lhs <= rhs,
            .eq => lhs == rhs,
            .gte => lhs >= rhs,
            .gt => lhs > rhs,
        };
    }
};
```

This makes the enum self-sufficient for evaluation and follows the pattern of other utility enums with helper methods.

### Relational Conditions (No Cache)

Relational conditions are cheap to compute (2-3 threshold checks per engagement) and have complex lifecycle concerns (two participants, engagement dissolution). Rather than caching, we:

1. **Compute on demand** when `hasConditionWithContext(condition, engagement)` is called
2. **Emit events** from metric-update sites by checking before/after

```zig
/// Compute relational conditions for an agent in this engagement.
/// Called on-demand, not cached.
pub fn computeRelationalConditions(
    self: *const Engagement,
    agent: *const Agent,
    perspective: Perspective,
) ConditionBitSet {
    var result = ConditionBitSet.initEmpty();

    // Get metrics from agent's perspective
    const effective = if (perspective == .inverted) self.invert() else self.*;

    for (condition_definitions) |def| {
        if (def.category == .relational) {
            if (evaluate(def.computation, .{ .agent = agent, .engagement = &effective })) {
                result.set(@intFromEnum(def.condition));
            }
        }
    }
    return result;
}

pub const Perspective = enum { normal, inverted };
```

**Event emission** happens when metrics change:

```zig
/// Update engagement pressure and emit condition events.
pub fn updatePressure(
    self: *Engagement,
    new_pressure: f32,
    first_agent: *const Agent,
    second_agent: *const Agent,
    events: *EventSystem,
) void {
    // Compute conditions before change
    const first_before = self.computeRelationalConditions(first_agent, .normal);
    const second_before = self.computeRelationalConditions(second_agent, .inverted);

    // Apply change
    self.pressure = new_pressure;

    // Compute conditions after change
    const first_after = self.computeRelationalConditions(first_agent, .normal);
    const second_after = self.computeRelationalConditions(second_agent, .inverted);

    // Emit events for changes
    emitConditionDiff(.{
        .agent = first_agent,
        .old = first_before,
        .new = first_after,
        .scope = .{ .relational = second_agent.id },
    }, events);
    emitConditionDiff(.{
        .agent = second_agent,
        .old = second_before,
        .new = second_after,
        .scope = .{ .relational = first_agent.id },
    }, events);
}
```

**Lifecycle**: When engagements dissolve (enemy dies, disengages), the relational conditions naturally cease to exist - there's no engagement to compute them from. No explicit cleanup needed.

---

## Cache Invalidation Strategy

### Invalidation Points

| Metric Changed | Scope | Trigger Location |
|----------------|-------|------------------|
| `blood.current` | internal | `applyDamage`, `agent.tick` |
| `pain.current` | internal | `applyDamage` (wound creation) |
| `trauma.current` | internal | `applyDamage` (wound creation) |
| `balance` | internal | `applyBalanceChange` |
| Body part integrity | internal | `applyWound` |
| `engagement.pressure` | relational | `updatePressure` |
| `engagement.control` | relational | `updateControl` |

**Internal conditions** use the agent's cached bitset; invalidation recomputes and diffs.
**Relational conditions** are computed on-demand; events are emitted by the metric-update functions themselves (see `updatePressure` above).

### Invalidation API (Internal Conditions)

```zig
/// Agent method for internal condition invalidation.
/// Call after blood/pain/trauma/balance/sensory changes.
pub fn invalidateConditionCache(self: *Agent, events: *EventSystem, is_player: bool) void {
    const old = self.condition_cache.conditions;
    self.condition_cache.recompute(self);
    const new = self.condition_cache.conditions;

    emitConditionDiff(.{
        .agent = self,
        .old = old,
        .new = new,
        .scope = .internal,
        .is_player = is_player,
    }, events);
}
```

**Relational conditions** don't use this API - they're handled inline by `updatePressure`/`updateControl` (see above).

### Development Check Mode

```zig
const build_options = @import("build_options");

pub fn assertCacheValid(agent: *const Agent) void {
    if (!build_options.debug_condition_cache) return;

    var fresh = ConditionCache{};
    fresh.recompute(agent);

    if (!agent.condition_cache.conditions.eql(fresh.conditions)) {
        std.debug.panic("Stale condition cache detected for agent {}", .{agent.id});
    }
}
```

Enabled via build option: `exe.root_module.addOptions("debug_condition_cache", true);`

---

## Iterator Refactor

```zig
pub const ConditionIterator = struct {
    agent: *const Agent,
    engagement: ?*const Engagement = null,
    encounter: ?*const Encounter = null,
    stored_index: usize = 0,
    def_index: usize = 0,
    yielded_resources: std.EnumSet(ResourceAccessor) = .{},

    pub fn init(agent: *const Agent) ConditionIterator {
        return .{ .agent = agent };
    }

    pub fn withEngagement(self: ConditionIterator, eng: *const Engagement) ConditionIterator {
        var copy = self;
        copy.engagement = eng;
        return copy;
    }

    pub fn withEncounter(self: ConditionIterator, enc: *const Encounter) ConditionIterator {
        var copy = self;
        copy.encounter = enc;
        return copy;
    }

    pub fn next(self: *ConditionIterator) ?ConditionState {
        // Phase 1: yield stored conditions
        if (self.stored_index < self.agent.conditions.items.len) {
            const stored = self.agent.conditions.items[self.stored_index];
            self.stored_index += 1;
            return stored;
        }

        // Phase 2: yield computed conditions from definition table
        while (self.def_index < condition_definitions.len) {
            const def = condition_definitions[self.def_index];
            self.def_index += 1;

            if (def.computation == .stored) continue;

            // Skip relational conditions if no engagement context
            if (def.category == .relational and self.engagement == null) continue;

            // For resource thresholds: only yield worst per resource
            if (def.computation == .resource_threshold) |rt| {
                if (self.yielded_resources.contains(rt.resource)) continue;
            }

            if (evaluate(def.computation, .{
                .agent = self.agent,
                .engagement = self.engagement,
                .encounter = self.encounter,
            })) {
                // Mark resource as yielded (worst-first in table)
                if (def.computation == .resource_threshold) |rt| {
                    self.yielded_resources.insert(rt.resource);
                }

                return .{
                    .condition = def.condition,
                    .expiration = .dynamic,
                    .payload = self.computePayload(def),
                };
            }
        }

        return null;
    }

    fn computePayload(self: *ConditionIterator, def: ConditionDefinition) ConditionPayload {
        return switch (def.computation) {
            .resource_threshold => |rt| .{ .ratio = self.agent.getResourceRatio(rt.resource) },
            else => .none,
        };
    }
};
```

---

## API Updates

### Agent.hasCondition

```zig
pub fn hasCondition(self: *const Agent, cond: damage.Condition) bool {
    return self.hasConditionWithContext(cond, .{});
}

pub const ConditionQueryContext = struct {
    engagement: ?*const Engagement = null,
    perspective: condition.Perspective = .normal,
    encounter: ?*const Encounter = null,
};

pub fn hasConditionWithContext(
    self: *const Agent,
    cond: damage.Condition,
    ctx: ConditionQueryContext,
) bool {
    // Check stored conditions
    for (self.conditions.items) |stored| {
        if (stored.condition == cond) return true;
    }

    // Check internal cache (balance, blood, pain, trauma, sensory)
    if (self.condition_cache.conditions.isSet(@intFromEnum(cond))) return true;

    // Compute relational conditions on-demand if engagement provided
    if (ctx.engagement) |eng| {
        const relational = eng.computeRelationalConditions(self, ctx.perspective);
        if (relational.isSet(@intFromEnum(cond))) return true;
    }

    // Compute positional conditions on-demand if encounter provided
    if (ctx.encounter) |enc| {
        const def = getDefinitionFor(cond);
        if (def.category == .positional) {
            if (evaluate(def.computation, .{ .agent = self, .encounter = enc })) {
                return true;
            }
        }
    }

    return false;
}
```

### Predicate Integration

Card predicates (`Predicate.has_condition`, `.lacks_condition`) already call `agent.hasCondition()`. Once that method consults caches, predicates automatically work for computed states.

For engagement-specific predicates, we may need a new predicate variant:

```zig
pub const Predicate = union(enum) {
    // ... existing ...
    has_condition: damage.Condition,
    lacks_condition: damage.Condition,
    target_has_condition: damage.Condition,  // NEW: checks target's conditions including relational
};
```

---

## Event Emission

### API Signature

```zig
pub const ConditionScope = union(enum) {
    internal,                    // balance, blood, pain, trauma, sensory
    relational: entity.ID,       // engagement-specific, includes opponent ID
};

pub const ConditionDiffParams = struct {
    agent: *const Agent,
    old: ConditionBitSet,
    new: ConditionBitSet,
    scope: ConditionScope,
    is_player: bool,
};

fn emitConditionDiff(params: ConditionDiffParams, events: *EventSystem) void {
    const actor = events.AgentMeta{ .id = params.agent.id, .player = params.is_player };

    // New conditions (in new but not old)
    var gained = params.new;
    gained.setIntersection(params.old.complement());
    var gained_iter = gained.iterator();
    while (gained_iter.next()) |cond_int| {
        events.push(.{ .condition_applied = .{
            .agent_id = params.agent.id,
            .condition = @enumFromInt(cond_int),
            .actor = actor,
            .scope = params.scope,  // NEW: includes scope for context
        } });
    }

    // Expired conditions (in old but not new)
    var lost = params.old;
    lost.setIntersection(params.new.complement());
    var lost_iter = lost.iterator();
    while (lost_iter.next()) |cond_int| {
        events.push(.{ .condition_expired = .{
            .agent_id = params.agent.id,
            .condition = @enumFromInt(cond_int),
            .actor = actor,
            .scope = params.scope,  // NEW: includes scope for context
        } });
    }
}
```

### Event Processor Simplification

`event_processor.agentEndTurnCleanup` can remove its ad-hoc `computedConditions` / `ConditionSet` diffing since cache invalidation handles events.

---

## Prerequisites

Before this design compiles:

### 1. `cards.Comparator.compare()` method

Add to `src/domain/cards.zig`:

```zig
pub const Comparator = enum {
    lt, lte, eq, gte, gt,

    pub fn compare(self: Comparator, lhs: f32, rhs: f32) bool {
        return switch (self) {
            .lt => lhs < rhs,
            .lte => lhs <= rhs,
            .eq => lhs == rhs,
            .gte => lhs >= rhs,
            .gt => lhs > rhs,
        };
    }
};
```

Small change, but the entire `evaluate()` function depends on it.

### 2. Event payload changes

`condition_applied` / `condition_expired` events need a `.scope` field:

```zig
// In events.zig, update the event payloads
condition_applied: struct {
    agent_id: entity.ID,
    condition: damage.Condition,
    actor: AgentMeta,
    scope: condition.ConditionScope,  // NEW
},
condition_expired: struct {
    agent_id: entity.ID,
    condition: damage.Condition,
    actor: AgentMeta,
    scope: condition.ConditionScope,  // NEW
},
```

---

## Migration Path

### Phase 1: Introduce Types (no behavior change)

1. Add `Comparator.compare()` method to `cards.zig`
2. Create `src/domain/condition.zig` with types above
3. Add `ConditionState` as alias for `damage.ActiveCondition` initially
4. Export from `damage.zig`: `pub const condition = @import("condition.zig");`

### Phase 2: Condition Definitions Table

1. Populate `condition_definitions` with all existing computed conditions (blood, balance, sensory, engagement)
2. Keep old `ConditionIterator` working alongside new table (test equivalence)

### Phase 3: Data-Driven Iterator

1. Replace `ConditionIterator` implementation with table-driven version
2. Verify all existing tests pass

### Phase 4: Caches + Event Emission

1. Add `condition_cache: ConditionCache` field to Agent
2. Wire invalidation points for internal conditions
3. Add `updatePressure`/`updateControl` wrappers that emit relational condition events
4. Add debug check mode (`assertCacheValid`)
5. Update `hasCondition` to consult caches + on-demand computation
6. Remove ad-hoc `ConditionSet` diffing from `event_processor`

### Phase 5: Combat Modifiers Integration

Update `src/domain/resolution/context.zig` to use the new system:

1. `CombatModifiers.forAttacker()` / `forDefender()` should iterate conditions via the new `ConditionIterator` (with appropriate context)
2. Remove any ad-hoc condition checks that duplicate what the framework now provides
3. Ensure `condition_penalties` table lookups work with cached + computed conditions
4. Verify no regression in penalty application (existing tests should pass)

This ensures condition penalties flow through a single source of truth rather than scattered ad-hoc logic.

### Phase 6: ConditionState Payloads

1. Migrate `agent.conditions` from `[]ActiveCondition` to `[]ConditionState`
2. Update `add_condition` effect to accept payload
3. Update logging to include payload where relevant

### Phase 7: T012 Integration

1. Add pain/trauma conditions to `Condition` enum (done in T012)
2. Add pain/trauma definitions to `condition_definitions` table
3. Add penalties to `condition_penalties` table
4. Wire wound → pain/trauma resource changes to cache invalidation

---

## Testing Strategy

### Unit Tests

- `condition_definitions` table covers all computed conditions currently yielded
- Iterator produces same results as old implementation (regression)
- Cache recompute matches fresh iterator evaluation
- `hasCondition` returns true for cached computed states
- Event diff emits correct `condition_applied`/`condition_expired`

### Integration Tests

- Combat resolution still applies correct penalties (no regression)
- Condition events appear in combat log for computed state transitions
- Engagement-dependent conditions emit events when engagement metrics change

### Debug Mode Tests

- Stale cache detection triggers panic in debug builds

---

## Resolved Questions

- **Blood ratio inversion**: Resolved by using explicit `cards.Comparator` - table reads naturally (`blood .lt 0.4`).
- **Incapacitation from multiple resources**: Resolved by using `ComputationType.any` (mirrors `Predicate.any`).
- **Engagement cache ownership**: Resolved by not caching relational conditions - compute on-demand, emit events from metric-update sites. Avoids lifecycle complexity entirely.
- **Positional conditions**: Resolved by computing on-demand via `Encounter.assessFlanking()`. No cache needed - follows same pattern as relational. Event emission deferred (can be added later by hooking topology changes).

---

## Appendix: ConditionBitSet Type

```zig
pub const ConditionBitSet = std.StaticBitSet(@typeInfo(damage.Condition).@"enum".fields.len);
```

This ensures the bitset automatically grows with the Condition enum - no manual cap like the old `[8]` buffer.
