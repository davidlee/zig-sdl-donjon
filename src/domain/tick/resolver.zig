/// TickResolver - executes committed actions for a combat tick.
///
/// Sorts committed actions, evaluates targets via apply/targeting, and
/// delegates to resolution to compute outcomes. No UI logic here.
const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const cards = @import("../cards.zig");
const combat = @import("../combat.zig");
const events = @import("../events.zig");
const resolution = @import("../resolution.zig");
const world = @import("../world.zig");
const weapon_list = @import("../weapon_list.zig");
const weapon = @import("../weapon.zig");

// Narrow dependency: only targeting, not full apply module
const targeting = @import("../apply/targeting.zig");

// Local data types
const committed_action = @import("committed_action.zig");
pub const CommittedAction = committed_action.CommittedAction;
pub const ResolutionEntry = committed_action.ResolutionEntry;
pub const TickResult = committed_action.TickResult;

const Agent = combat.Agent;
const Engagement = combat.Engagement;
const Technique = cards.Technique;
const World = world.World;

pub const TickResolver = struct {
    alloc: std.mem.Allocator,
    committed: std.ArrayList(CommittedAction),

    pub fn init(alloc: std.mem.Allocator) !TickResolver {
        return .{
            .alloc = alloc,
            .committed = try std.ArrayList(CommittedAction).initCapacity(alloc, 8),
        };
    }

    pub fn deinit(self: *TickResolver) void {
        self.committed.deinit(self.alloc);
    }

    pub fn reset(self: *TickResolver) void {
        self.committed.clearRetainingCapacity();
    }

    /// Add a committed action to the tick
    pub fn addAction(self: *TickResolver, action: CommittedAction) !void {
        try self.committed.append(self.alloc, action);
    }

    /// Sort all committed actions by time
    pub fn sortByTime(self: *TickResolver) void {
        std.mem.sort(
            CommittedAction,
            self.committed.items,
            {},
            CommittedAction.compareByTime,
        );
    }

    /// Extract committed actions from player's plays (with modifiers from commit phase)
    pub fn commitPlayerCards(self: *TickResolver, player: *Agent, w: *World) !void {
        // Get slots from AgentEncounterState (populated during commit phase)
        const enc = w.encounter orelse return;
        const enc_state = enc.stateFor(player.id) orelse return;

        for (enc_state.current.slots()) |slot| {
            const play = slot.play;

            // Look up card via card_registry (new system)
            const card_instance = w.card_registry.get(play.action) orelse continue;
            const template = card_instance.template;
            const tech_expr = template.getTechniqueWithExpression() orelse continue;

            // Recalculate duration from current play state (includes modifier effects)
            const duration = combat.getPlayDuration(play, &w.card_registry);

            try self.addAction(.{
                .actor = player,
                .card = card_instance,
                .technique = tech_expr.technique,
                .expression = tech_expr.expression,
                .stakes = play.effectiveStakes(),
                .time_start = slot.time_start,
                .time_end = slot.time_start + duration,
                .target = play.target,
                .source = play.source,
                .damage_mult = play.damage_mult,
                .advantage_override = play.advantage_override,
            });
        }
    }

    /// Commit actions for all mobs based on their strategy
    pub fn commitMobActions(self: *TickResolver, mobs: []*Agent, w: *World) !void {
        for (mobs) |mob| {
            try self.commitSingleMob(mob, w);
        }
    }

    fn commitSingleMob(self: *TickResolver, mob: *Agent, w: ?*World) !void {
        const world_ref = w orelse return;
        const enc = world_ref.encounter orelse return;
        const enc_state = enc.stateFor(mob.id) orelse return;
        const registry = &world_ref.card_registry;

        for (enc_state.current.slots()) |slot| {
            const play = slot.play;
            const card_instance = registry.get(play.action) orelse continue;
            const template = card_instance.template;
            const tech_expr = template.getTechniqueWithExpression() orelse continue;
            const duration = combat.getPlayDuration(play, registry);

            try self.addAction(.{
                .actor = mob,
                .card = card_instance,
                .technique = tech_expr.technique,
                .expression = tech_expr.expression,
                .stakes = play.effectiveStakes(),
                .time_start = slot.time_start,
                .time_end = slot.time_start + duration,
                .target = play.target,
                .source = play.source,
                .damage_mult = play.damage_mult,
                .advantage_override = play.advantage_override,
            });
        }
    }

    /// Resolve all committed actions and return results
    pub fn resolve(self: *TickResolver, w: *World) !TickResult {
        self.sortByTime();

        var result = try TickResult.init(self.alloc);
        errdefer result.deinit();

        // Process each offensive action
        for (self.committed.items) |*action| {
            // Skip defensive actions (they modify how we defend, not attack)
            if (!self.isOffensiveAction(action)) continue;

            // Get targets for this action (from expression, or default to all_enemies)
            const target_query = if (action.expression) |expr| expr.target else .all_enemies;
            var targets = try targeting.evaluateTargets(self.alloc, target_query, action.actor, w, action.target);
            defer targets.deinit(self.alloc);

            // Resolve against each target
            for (targets.items) |defender| {
                // Skip self-targeting (no engagement with self)
                if (defender.id.eql(action.actor.id)) continue;

                // Find defender's active defense (if any)
                const defense_tech = self.findDefensiveAction(defender, action.time_start, action.time_end);

                // Get engagement from encounter
                const engagement = self.getEngagement(w.encounter, action.actor, defender) orelse continue;

                // Check expression filter predicate
                if (action.card) |card| {
                    if (action.expression) |expr| {
                        if (!targeting.expressionAppliesToTarget(expr, card, action.actor, defender, engagement)) {
                            continue; // Filter failed, skip this target
                        }
                    }
                }

                // Check weapon reach vs engagement range (resolution-time range validation)
                const attack_mode = action.technique.attack_mode;
                if (attack_mode != .none) {
                    // Offensive technique - must have weapon reach >= engagement range
                    const weapon_mode = action.actor.weapons.getOffensiveMode(attack_mode);
                    if (weapon_mode) |wm| {
                        if (@intFromEnum(wm.reach) < @intFromEnum(engagement.range)) {
                            // Out of range - emit event and skip this target
                            try w.events.push(.{ .attack_out_of_range = .{
                                .attacker_id = action.actor.id,
                                .defender_id = defender.id,
                                .technique_id = action.technique.id,
                                .weapon_reach = wm.reach,
                                .engagement_range = engagement.range,
                            } });
                            continue;
                        }
                    } else {
                        // No weapon for this attack mode - can't attack
                        continue;
                    }
                }

                // Compute attention penalty for non-primary target
                const attention_penalty = if (w.encounter) |enc| blk: {
                    if (enc.stateForConst(action.actor.id)) |state| {
                        break :blk state.attention.penaltyFor(defender.id);
                    }
                    break :blk @as(f32, 0);
                } else 0;

                // Build contexts and resolve
                const attack_ctx = resolution.AttackContext{
                    .attacker = action.actor,
                    .defender = defender,
                    .technique = action.technique,
                    .weapon_template = self.getWeaponTemplate(action.actor),
                    .stakes = action.stakes,
                    .engagement = engagement,
                    .time_start = action.time_start,
                    .time_end = action.time_end,
                    .attention_penalty = attention_penalty,
                };

                // Compute defender's combat state (stationary, flanking)
                const defender_computed = if (w.encounter) |enc| blk: {
                    const is_stationary = if (enc.stateFor(defender.id)) |state|
                        !combat.hasFootworkInTimeline(&state.current.timeline, &w.card_registry)
                    else
                        true; // No timeline = stationary

                    break :blk resolution.ComputedCombatState{
                        .is_stationary = is_stationary,
                        .flanking = enc.assessFlanking(defender.id),
                    };
                } else resolution.ComputedCombatState{ .is_stationary = true };

                const defense_ctx = resolution.DefenseContext{
                    .defender = defender,
                    .technique = defense_tech,
                    .weapon_template = self.getWeaponTemplate(defender),
                    .engagement = engagement,
                    .computed = defender_computed,
                    // Use attack time window - defender's manoeuvres during this window provide bonus
                    .time_start = action.time_start,
                    .time_end = action.time_end,
                };

                // Select hit location
                const target_part = try resolution.selectHitLocation(
                    w,
                    defender,
                    action.technique,
                    defense_tech,
                );

                // Resolve the technique
                const res = try resolution.resolveTechniqueVsDefense(
                    w,
                    attack_ctx,
                    defense_ctx,
                    target_part,
                );

                // Record result
                try result.resolutions.append(self.alloc, .{
                    .attacker_id = action.actor.id,
                    .defender_id = defender.id,
                    .technique_id = action.technique.id,
                    .outcome = res.outcome,
                    .damage_dealt = if (res.damage_packet) |p| p.amount else 0,
                });
            }
        }

        return result;
    }

    // -------------------------------------------------------------------------
    // Helper functions for resolution
    // -------------------------------------------------------------------------

    fn isOffensiveAction(self: *TickResolver, action: *const CommittedAction) bool {
        _ = self;
        // All actions now have card instances with proper tags
        return if (action.card) |card| card.template.tags.offensive else false;
    }

    fn findDefensiveAction(
        self: *TickResolver,
        defender: *Agent,
        attack_start: f32,
        attack_end: f32,
    ) ?*const Technique {
        // Find a defensive action from defender that overlaps this time window
        for (self.committed.items) |*action| {
            if (action.actor != defender) continue;

            // All actions now have card instances with proper tags
            const is_defensive = if (action.card) |card| card.template.tags.defensive else false;
            if (!is_defensive) continue;

            // Check time overlap
            if (action.time_end > attack_start and action.time_start < attack_end) {
                return action.technique;
            }
        }
        return null; // passive defense
    }

    fn getEngagement(self: *TickResolver, encounter: ?*combat.Encounter, attacker: *Agent, defender: *Agent) ?*Engagement {
        _ = self;
        const enc = encounter orelse return null;
        return enc.getEngagement(attacker.id, defender.id);
    }

    fn getWeaponTemplate(self: *TickResolver, agent: *Agent) *const weapon.Template {
        _ = self;
        _ = agent;
        // TODO: get from agent's equipped weapon
        // For now, use knight's sword as default
        return &weapon_list.knights_sword;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CommittedAction.compareByTime sorts correctly" {
    const alloc = std.testing.allocator;

    var resolver = try TickResolver.init(alloc);
    defer resolver.deinit();

    // Create mock technique for testing
    const mock_technique = cards.Technique{
        .id = .swing,
        .name = "test",
        .damage = .{
            .instances = &.{},
            .scaling = .{ .ratio = 1.0, .stats = .{ .stat = .power } },
        },
        .difficulty = 0.5,
    };

    // Add actions out of order
    try resolver.addAction(.{
        .actor = undefined,
        .card = null,
        .technique = &mock_technique,
        .stakes = .guarded,
        .time_start = 0.6,
        .time_end = 0.9,
        .expression = null,
    });
    try resolver.addAction(.{
        .actor = undefined,
        .card = null,
        .technique = &mock_technique,
        .stakes = .guarded,
        .time_start = 0.0,
        .time_end = 0.3,
        .expression = null,
    });
    try resolver.addAction(.{
        .actor = undefined,
        .card = null,
        .technique = &mock_technique,
        .stakes = .guarded,
        .time_start = 0.3,
        .time_end = 0.6,
        .expression = null,
    });

    resolver.sortByTime();

    try std.testing.expectApproxEqAbs(@as(f32, 0.0), resolver.committed.items[0].time_start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), resolver.committed.items[1].time_start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), resolver.committed.items[2].time_start, 0.001);
}

test "TickResolver.reset clears committed actions" {
    const alloc = std.testing.allocator;

    var resolver = try TickResolver.init(alloc);
    defer resolver.deinit();

    const mock_technique = cards.Technique{
        .id = .swing,
        .name = "test",
        .damage = .{
            .instances = &.{},
            .scaling = .{ .ratio = 1.0, .stats = .{ .stat = .power } },
        },
        .difficulty = 0.5,
    };

    try resolver.addAction(.{
        .actor = undefined,
        .card = null,
        .technique = &mock_technique,
        .stakes = .guarded,
        .time_start = 0.0,
        .time_end = 0.3,
        .expression = null,
    });

    try std.testing.expectEqual(@as(usize, 1), resolver.committed.items.len);

    resolver.reset();

    try std.testing.expectEqual(@as(usize, 0), resolver.committed.items.len);
}

// NOTE: Tests for TechniquePool-based mob behavior removed during Phase 7 migration.
// The new unified draw_style system uses combat_state.in_play for all agent types.
// Add new tests when always_available/scripted draw styles are fully implemented.
