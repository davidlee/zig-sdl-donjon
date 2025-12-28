const std = @import("std");
const combat = @import("combat.zig");
const cards = @import("cards.zig");
const entity = @import("entity.zig");
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
            const tech_expr = template.getTechniqueWithExpression() orelse continue;
            const time_cost = template.cost.time;

            try self.addAction(.{
                .actor = player,
                .card = card_instance,
                .technique = tech_expr.technique,
                .expression = tech_expr.expression,
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
                // Fill tick with techniques from pool (round-robin, respects stamina + predicates)
                var time_cursor: f32 = 0.0;
                var attempts: usize = 0;
                const max_attempts = pool.instances.items.len * 2; // prevent infinite loop
                while (time_cursor < 1.0 and attempts < max_attempts) {
                    attempts += 1;
                    const instance = pool.selectNext(mob.stamina_available) orelse break;

                    // Check predicates (weapon requirements, etc.)
                    if (!apply.canUseCard(instance.template, mob)) continue;

                    const tech_expr = instance.template.getTechniqueWithExpression() orelse continue;
                    const time_cost = instance.template.cost.time;

                    try self.addAction(.{
                        .actor = mob,
                        .card = instance,
                        .technique = tech_expr.technique,
                        .expression = tech_expr.expression,
                        .stakes = .guarded, // TODO: behavior-based stakes
                        .time_start = time_cursor,
                        .time_end = time_cursor + time_cost,
                    });

                    time_cursor += time_cost;
                    mob.stamina_available -= instance.template.cost.stamina;
                    attempts = 0; // reset attempts on success
                }
            },
            .deck => |*d| {
                // Deck-based mob: use in_play cards like player
                var time_cursor: f32 = 0.0;
                for (d.in_play.items) |card_instance| {
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

            // Get targets for this action (from expression, or default to all_enemies)
            const target_query = if (action.expression) |expr| expr.target else .all_enemies;
            var targets = try apply.evaluateTargets(self.alloc, target_query, action.actor, w);
            defer targets.deinit(self.alloc);

            // Resolve against each target
            for (targets.items) |defender| {
                // Find defender's active defense (if any)
                const defense_tech = self.findDefensiveAction(defender, action.time_start, action.time_end);

                // Get engagement (stored on mob)
                const engagement = self.getEngagement(action.actor, defender) orelse continue;

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

    fn getEngagement(self: *TickResolver, attacker: *Agent, defender: *Agent) ?*Engagement {
        _ = self;
        // Engagement is stored on the mob (non-player)
        if (attacker.director == .player) {
            return if (defender.engagement) |*e| e else null;
        } else {
            return if (attacker.engagement) |*e| e else null;
        }
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

test "commitSingleMob fills tick with multiple pool techniques" {
    const alloc = std.testing.allocator;
    const slot_map = @import("slot_map.zig");
    const stats = @import("stats.zig");
    const armour = @import("armour.zig");

    // Create test templates (0.3s each, 2.0 stamina each)
    const test_technique = Technique.byID(.swing);
    const test_rule: cards.Rule = .{
        .trigger = .on_play,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = test_technique },
            .filter = null,
            .target = .all_enemies,
        }},
    };
    const template1: cards.Template = .{
        .id = 1,
        .kind = .action,
        .name = "t1",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 2.0, .time = 0.3 },
        .tags = .{ .offensive = true },
        .rules = &.{test_rule},
    };
    const template2: cards.Template = .{
        .id = 2,
        .kind = .action,
        .name = "t2",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 2.0, .time = 0.3 },
        .tags = .{ .defensive = true },
        .rules = &.{test_rule},
    };

    // Create pool with both templates
    const templates = &[_]*const cards.Template{ &template1, &template2 };
    const pool = try combat.TechniquePool.init(alloc, templates);
    // Note: pool ownership transfers to mob, mob.deinit() handles cleanup

    // Create agent with pool
    var agents = try slot_map.SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const test_body = try body.Body.fromPlan(alloc, &body.HumanoidPlan);
    var mob = try alloc.create(Agent);
    mob.* = .{
        .id = undefined,
        .alloc = alloc,
        .director = .ai,
        .cards = .{ .pool = pool },
        .stats = stats.Block.splat(5),
        .body = test_body,
        .armour = armour.Stack.init(alloc),
        .weapons = undefined,
        .engagement = Engagement{},
        .stamina = 10.0,
        .stamina_available = 10.0,
        .conditions = try std.ArrayList(@import("damage.zig").ActiveCondition).initCapacity(alloc, 1),
        .resistances = try std.ArrayList(@import("damage.zig").Resistance).initCapacity(alloc, 1),
        .immunities = try std.ArrayList(@import("damage.zig").Immunity).initCapacity(alloc, 1),
        .vulnerabilities = try std.ArrayList(@import("damage.zig").Vulnerability).initCapacity(alloc, 1),
    };
    const id = try agents.insert(mob);
    mob.id = id;
    defer mob.deinit();

    // Create resolver and commit
    var resolver = try TickResolver.init(alloc);
    defer resolver.deinit();

    try resolver.commitSingleMob(mob);

    // With 10 stamina and 2.0 per technique, should fit 3-4 techniques
    // With 0.3s per technique, should fit 3 techniques before time exceeds 1.0
    // (0.0-0.3, 0.3-0.6, 0.6-0.9 = 3 techniques, 0.9s total)
    try std.testing.expect(resolver.committed.items.len >= 3);

    // Verify time sequencing
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), resolver.committed.items[0].time_start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), resolver.committed.items[1].time_start, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), resolver.committed.items[2].time_start, 0.001);
}

test "commitSingleMob stops when stamina exhausted" {
    const alloc = std.testing.allocator;
    const slot_map = @import("slot_map.zig");
    const stats = @import("stats.zig");
    const armour = @import("armour.zig");

    const test_technique = Technique.byID(.swing);
    const test_rule: cards.Rule = .{
        .trigger = .on_play,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = test_technique },
            .filter = null,
            .target = .all_enemies,
        }},
    };
    const template1: cards.Template = .{
        .id = 1,
        .kind = .action,
        .name = "t1",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 4.0, .time = 0.2 }, // 4 stamina each
        .tags = .{ .offensive = true },
        .rules = &.{test_rule},
    };

    const templates = &[_]*const cards.Template{&template1};
    const pool = try combat.TechniquePool.init(alloc, templates);
    // Note: pool ownership transfers to mob, mob.deinit() handles cleanup

    var agents = try slot_map.SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const test_body = try body.Body.fromPlan(alloc, &body.HumanoidPlan);
    var mob = try alloc.create(Agent);
    mob.* = .{
        .id = undefined,
        .alloc = alloc,
        .director = .ai,
        .cards = .{ .pool = pool },
        .stats = stats.Block.splat(5),
        .body = test_body,
        .armour = armour.Stack.init(alloc),
        .weapons = undefined,
        .engagement = Engagement{},
        .stamina = 10.0,
        .stamina_available = 10.0, // Only enough for 2 techniques (8 stamina)
        .conditions = try std.ArrayList(@import("damage.zig").ActiveCondition).initCapacity(alloc, 1),
        .resistances = try std.ArrayList(@import("damage.zig").Resistance).initCapacity(alloc, 1),
        .immunities = try std.ArrayList(@import("damage.zig").Immunity).initCapacity(alloc, 1),
        .vulnerabilities = try std.ArrayList(@import("damage.zig").Vulnerability).initCapacity(alloc, 1),
    };
    const id = try agents.insert(mob);
    mob.id = id;
    defer mob.deinit();

    var resolver = try TickResolver.init(alloc);
    defer resolver.deinit();

    try resolver.commitSingleMob(mob);

    // With 10 stamina and 4.0 per technique, should only fit 2 techniques
    try std.testing.expectEqual(@as(usize, 2), resolver.committed.items.len);
}
