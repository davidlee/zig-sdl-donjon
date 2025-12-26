const std = @import("std");
const combat = @import("combat.zig");
const cards = @import("cards.zig");
const entity = @import("entity.zig");
const resolution = @import("resolution.zig");
const world = @import("world.zig");
const body = @import("body.zig");
const apply = @import("apply.zig");
const weapon_list = @import("weapon_list.zig");

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
    stakes: Stakes,
    time_start: f32, // when this action begins (0.0-1.0 within tick)
    time_end: f32, // when this action ends (time_start + cost.time)

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

    /// Extract committed actions from player's in_play cards
    pub fn commitPlayerCards(self: *TickResolver, player: *Agent) !void {
        const pd = switch (player.cards) {
            .deck => |*d| d,
            .pool => return, // player shouldn't use pool
        };

        var time_cursor: f32 = 0.0;

        for (pd.in_play.items) |card_instance| {
            const template = card_instance.template;
            const technique = template.technique orelse continue;
            const time_cost = template.cost.time;

            try self.addAction(.{
                .actor = player,
                .card = card_instance,
                .technique = technique,
                .stakes = .guarded, // TODO: get from card instance or UI
                .time_start = time_cursor,
                .time_end = time_cursor + time_cost,
            });

            time_cursor += time_cost;
        }
    }

    /// Commit actions for all mobs based on their strategy
    pub fn commitMobActions(self: *TickResolver, mobs: []*Agent) !void {
        for (mobs) |mob| {
            try self.commitSingleMob(mob);
        }
    }

    fn commitSingleMob(self: *TickResolver, mob: *Agent) !void {
        switch (mob.cards) {
            .pool => |*pool| {
                // Select next technique instance from pool
                if (pool.selectNext()) |instance| {
                    const technique = instance.template.technique orelse return;
                    const time_cost = instance.template.cost.time;

                    try self.addAction(.{
                        .actor = mob,
                        .card = instance,
                        .technique = technique,
                        .stakes = .guarded, // TODO: behavior-based stakes
                        .time_start = 0.0,
                        .time_end = time_cost,
                    });
                }
            },
            .deck => |*d| {
                // Deck-based mob: use in_play cards like player
                var time_cursor: f32 = 0.0;
                for (d.in_play.items) |card_instance| {
                    const template = card_instance.template;
                    const technique = template.technique orelse continue;
                    const time_cost = template.cost.time;

                    try self.addAction(.{
                        .actor = mob,
                        .card = card_instance,
                        .technique = technique,
                        .stakes = .guarded,
                        .time_start = time_cursor,
                        .time_end = time_cursor + time_cost,
                    });

                    time_cursor += time_cost;
                }
            },
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

            // Get targets for this action
            const target_query = self.getTargetQuery(action) orelse .all_enemies;
            var targets = try apply.evaluateTargets(self.alloc, target_query, action.actor, w);
            defer targets.deinit(self.alloc);

            // Resolve against each target
            for (targets.items) |defender| {
                // Find defender's active defense (if any)
                const defense_tech = self.findDefensiveAction(defender, action.time_start, action.time_end);

                // Get engagement (stored on mob)
                const engagement = self.getEngagement(action.actor, defender) orelse continue;

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

    fn getTargetQuery(self: *TickResolver, action: *const CommittedAction) ?cards.TargetQuery {
        _ = self;
        if (action.card) |card| {
            // Get target from first rule's first expression
            if (card.template.rules.len > 0) {
                const rule = card.template.rules[0];
                if (rule.expressions.len > 0) {
                    return rule.expressions[0].target;
                }
            }
        }
        return null; // default to all_enemies for offensive
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

    fn getEngagement(self: *TickResolver, attacker: *Agent, defender: *Agent) ?*Engagement {
        _ = self;
        // Engagement is stored on the mob (non-player)
        if (attacker.director == .player) {
            return if (defender.engagement) |*e| e else null;
        } else {
            return if (attacker.engagement) |*e| e else null;
        }
    }

    fn getWeaponTemplate(self: *TickResolver, agent: *Agent) *const weapon_list.weapon.Template {
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
            agent.stamina_available = agent.stamina;

            // Decrement cooldowns for pool-based
            switch (agent.cards) {
                .pool => |*pool| pool.tickCooldowns(),
                .deck => {},
            }
        }
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
    });
    try resolver.addAction(.{
        .actor = undefined,
        .card = null,
        .technique = &mock_technique,
        .stakes = .guarded,
        .time_start = 0.0,
        .time_end = 0.3,
    });
    try resolver.addAction(.{
        .actor = undefined,
        .card = null,
        .technique = &mock_technique,
        .stakes = .guarded,
        .time_start = 0.3,
        .time_end = 0.6,
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
    });

    try std.testing.expectEqual(@as(usize, 1), resolver.committed.items.len);

    resolver.reset();

    try std.testing.expectEqual(@as(usize, 0), resolver.committed.items.len);
}
