/// TickResolver - executes committed actions for a combat tick.
///
/// Sorts committed actions, evaluates targets via apply/targeting, and
/// delegates to resolution to compute outcomes. No UI logic here.
const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const actions = @import("../actions.zig");
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

const plays = @import("../combat/plays.zig");

const Agent = combat.Agent;
const Engagement = combat.Engagement;
const Technique = actions.Technique;
const Stance = plays.Stance;
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

            // Look up card via action_registry (new system)
            const card_instance = w.action_registry.get(play.action) orelse continue;
            const template = card_instance.template;
            const tech_expr = template.getTechniqueWithExpression() orelse continue;

            // Recalculate duration from current play state (includes modifier effects)
            const duration = combat.getPlayDuration(play, &w.action_registry);

            // Resolve weapon from play's channels
            const channels = combat.getPlayChannels(play, &w.action_registry);
            const weapon_template = if (player.weaponForChannel(channels)) |ref|
                ref.template()
            else
                null;

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
                .weapon_template = weapon_template,
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
        const registry = &world_ref.action_registry;

        for (enc_state.current.slots()) |slot| {
            const play = slot.play;
            const card_instance = registry.get(play.action) orelse continue;
            const template = card_instance.template;
            const tech_expr = template.getTechniqueWithExpression() orelse continue;
            const duration = combat.getPlayDuration(play, registry);

            // Resolve weapon from play's channels
            const channels = combat.getPlayChannels(play, registry);
            const weapon_template = if (mob.weaponForChannel(channels)) |ref|
                ref.template()
            else
                null;

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
                .weapon_template = weapon_template,
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

                // Check weapon reach/range vs engagement range (resolution-time validation)
                const attack_mode = action.technique.attack_mode;
                if (attack_mode != .none) {
                    const wt = action.weapon_template orelse self.getWeaponTemplate(action.actor);

                    if (attack_mode == .ranged) {
                        // Ranged attack: check if target is within throw/projectile range
                        const ranged_profile = wt.ranged orelse continue; // No ranged capability
                        const max_range = switch (ranged_profile) {
                            .thrown => |t| t.range,
                            .projectile => |p| p.range,
                        };
                        if (@intFromEnum(engagement.range) > @intFromEnum(max_range)) {
                            // Out of range for ranged attack
                            try w.events.push(.{ .attack_out_of_range = .{
                                .attacker_id = action.actor.id,
                                .defender_id = defender.id,
                                .technique_id = action.technique.id,
                                .weapon_reach = max_range,
                                .engagement_range = engagement.range,
                            } });
                            continue;
                        }
                    } else {
                        // Melee attack: weapon reach must be >= engagement range
                        const weapon_mode: ?weapon.Offensive = switch (attack_mode) {
                            .swing => wt.swing,
                            .thrust => wt.thrust,
                            else => null,
                        };
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
                }

                // Compute attention penalty for non-primary target
                const attention_penalty = if (w.encounter) |enc| blk: {
                    if (enc.stateForConst(action.actor.id)) |state| {
                        break :blk state.attention.penaltyFor(defender.id);
                    }
                    break :blk @as(f32, 0);
                } else 0;

                // Get attacker's stance from encounter state
                const attacker_stance = if (w.encounter) |enc| blk: {
                    if (enc.stateForConst(action.actor.id)) |state| {
                        break :blk state.current.stance;
                    }
                    break :blk Stance.balanced;
                } else Stance.balanced;

                // Build contexts and resolve
                const attack_ctx = resolution.AttackContext{
                    .attacker = action.actor,
                    .defender = defender,
                    .technique = action.technique,
                    .weapon_template = action.weapon_template orelse self.getWeaponTemplate(action.actor),
                    .stakes = action.stakes,
                    .engagement = engagement,
                    .time_start = action.time_start,
                    .time_end = action.time_end,
                    .attention_penalty = attention_penalty,
                    .attacker_stance = attacker_stance,
                };

                // Compute defender's combat state (stationary, flanking)
                const defender_computed = if (w.encounter) |enc| blk: {
                    const is_stationary = if (enc.stateFor(defender.id)) |state|
                        !combat.hasFootworkInTimeline(&state.current.timeline, &w.action_registry)
                    else
                        true; // No timeline = stationary

                    break :blk resolution.ComputedCombatState{
                        .is_stationary = is_stationary,
                        .flanking = enc.assessFlanking(defender.id),
                    };
                } else resolution.ComputedCombatState{ .is_stationary = true };

                // Get defender's stance from encounter state
                const defender_stance = if (w.encounter) |enc| blk: {
                    if (enc.stateForConst(defender.id)) |state| {
                        break :blk state.current.stance;
                    }
                    break :blk Stance.balanced;
                } else Stance.balanced;

                // Check if defender has offensive action in overlapping time window
                const defender_is_attacking = self.isDefenderAttacking(defender.id, action.time_start, action.time_end);

                const defense_ctx = resolution.DefenseContext{
                    .defender = defender,
                    .technique = defense_tech,
                    .weapon_template = self.getWeaponTemplate(defender),
                    .engagement = engagement,
                    .computed = defender_computed,
                    // Use attack time window - defender's manoeuvres during this window provide bonus
                    .time_start = action.time_start,
                    .time_end = action.time_end,
                    .defender_stance = defender_stance,
                    .defender_is_attacking = defender_is_attacking,
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

    /// Check if defender has an offensive action overlapping the given time window.
    /// Used to determine weapon defense scaling (attacking = reduced parry contribution).
    fn isDefenderAttacking(self: *TickResolver, defender_id: entity.ID, time_start: f32, time_end: f32) bool {
        for (self.committed.items) |*action| {
            if (!action.actor.id.eql(defender_id)) continue;
            if (!self.isOffensiveAction(action)) continue;

            // Check time overlap
            if (action.time_end > time_start and action.time_start < time_end) {
                return true;
            }
        }
        return false;
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

    /// Get agent's primary weapon template (weapon channel).
    /// Falls back to knight's sword if agent has no weapon (temporary until unarmed combat).
    fn getWeaponTemplate(self: *TickResolver, agent: *Agent) *const weapon.Template {
        _ = self;
        if (agent.weaponForChannel(.{ .weapon = true })) |ref| {
            return ref.template();
        }
        // Fallback for unarmed/no-weapon case
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
    const mock_technique = actions.Technique{
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

    const mock_technique = actions.Technique{
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
