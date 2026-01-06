const std = @import("std");
const lib = @import("infra");
const combat = @import("combat.zig");
const cards = @import("cards.zig");
const entity = lib.entity;
const resolution = @import("resolution.zig");
const world = @import("world.zig");
const body = @import("body.zig");
const apply = @import("apply.zig");
const weapon_list = @import("weapon_list.zig");
const weapon = @import("weapon.zig");

const Agent = combat.Agent;
const Engagement = combat.Engagement;
const Technique = cards.Technique;
const Stakes = cards.Stakes;
const World = world.World;

// ============================================================================
// Committed Action
// ============================================================================

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

// ============================================================================
// Resolution Entry (result of a single interaction)
// ============================================================================

pub const ResolutionEntry = struct {
    attacker_id: entity.ID,
    defender_id: entity.ID,
    technique_id: cards.TechniqueID,
    outcome: resolution.Outcome,
    damage_dealt: f32, // 0 if miss/blocked
};

// ============================================================================
// Tick Result
// ============================================================================

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

// ============================================================================
// Tick Resolver
// ============================================================================

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
        // All draw styles now use combat_state.in_play
        // The AI director is responsible for populating in_play appropriately
        const registry = if (w) |world_ref| &world_ref.card_registry else return;
        const cs = mob.combat_state orelse return;
        var time_cursor: f32 = 0.0;

        for (cs.in_play.items) |card_id| {
            const card_instance = registry.get(card_id) orelse continue;
            const template = card_instance.template;
            const tech_expr = template.getTechniqueWithExpression() orelse continue;
            const time_cost = template.cost.time;

            try self.addAction(.{
                .actor = mob,
                .card = card_instance,
                .technique = tech_expr.technique,
                .expression = tech_expr.expression,
                .stakes = .guarded,
                .time_start = time_cursor,
                .time_end = time_cursor + time_cost,
            });

            time_cursor += time_cost;
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
            var targets = try apply.evaluateTargets(self.alloc, target_query, action.actor, w, action.target);
            defer targets.deinit(self.alloc);

            // Resolve against each target
            for (targets.items) |defender| {
                // Find defender's active defense (if any)
                const defense_tech = self.findDefensiveAction(defender, action.time_start, action.time_end);

                // Get engagement from encounter
                const engagement = self.getEngagement(w.encounter, action.actor, defender) orelse continue;

                // Check expression filter predicate
                if (action.card) |card| {
                    if (action.expression) |expr| {
                        if (!apply.expressionAppliesToTarget(expr, card, action.actor, defender, engagement)) {
                            continue; // Filter failed, skip this target
                        }
                    }
                }

                // Build contexts and resolve
                const attack_ctx = resolution.AttackContext{
                    .attacker = action.actor,
                    .defender = defender,
                    .technique = action.technique,
                    .weapon_template = self.getWeaponTemplate(action.actor),
                    .stakes = action.stakes,
                    .engagement = engagement,
                };

                const defense_ctx = resolution.DefenseContext{
                    .defender = defender,
                    .technique = defense_tech,
                    .weapon_template = self.getWeaponTemplate(defender),
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

    // -------------------------------------------------------------------------
    // Tick Cleanup (Note: Cost enforcement moved to apply.zig)
    // -------------------------------------------------------------------------

    /// Reset agent resources for next tick
    pub fn resetForNextTick(self: *TickResolver, agents: []*Agent) void {
        _ = self;
        for (agents) |agent| {
            agent.time_available = 1.0;
            agent.stamina.tick(); // refresh and reset available
            agent.focus.tick();
            // TODO: decrement cooldowns for always_available draw_style
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const ai = @import("ai.zig");
test "CommittedAction.compareByTime sorts correctly" {
    const alloc = std.testing.allocator;

    var resolver = try TickResolver.init(alloc);
    defer resolver.deinit();

    // Create mock technique for testing
    const mock_technique = Technique{
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

    const mock_technique = Technique{
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
