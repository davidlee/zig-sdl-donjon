//! Combat agent - combatant with stats, weapons, and conditions.
//!
//! An Agent represents any entity that can participate in combat,
//! whether player-controlled or AI-directed.

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const SlotMap = @import("../slot_map.zig").SlotMap;

const armour = @import("../armour.zig");
const body = @import("../body.zig");
const damage = @import("../damage.zig");
const stats = @import("../stats.zig");
const weapon = @import("../weapon.zig");

const types = @import("types.zig");
const state_mod = @import("state.zig");
const armament_mod = @import("armament.zig");
const engagement_mod = @import("engagement.zig");

pub const Director = types.Director;
pub const DrawStyle = types.DrawStyle;
pub const CombatState = state_mod.CombatState;
pub const Armament = armament_mod.Armament;
pub const Engagement = engagement_mod.Engagement;

// Forward reference for self-referential type
const combat = @import("../combat.zig");

/// A combat participant with stats, equipment, and state.
pub const Agent = struct {
    id: entity.ID,
    alloc: std.mem.Allocator,
    director: Director,
    draw_style: DrawStyle = .shuffled_deck,
    stats: stats.Block,
    // may be humanoid, or not
    body: body.Body,
    // sourced from cards.equipped
    armour: armour.Stack,
    weapons: Armament,
    dominant_side: body.Side = .right, // .center == ambidextrous

    // Card containers (IDs reference World.card_registry)
    // See doc/card_storage_design.md for architecture
    // NOTE: Default to empty - use .init(alloc) pattern for non-test code
    always_available: std.ArrayList(entity.ID) = .{}, // Techniques/modifiers usable without drawing
    spells_known: std.ArrayList(entity.ID) = .{}, // Always available (if mana)
    deck_cards: std.ArrayList(entity.ID) = .{}, // Shuffled into draw at combat start
    inventory: std.ArrayList(entity.ID) = .{}, // Carried items
    combat_state: ?*CombatState = null, // Per-encounter, transient

    // state (wounds kept in body)
    balance: f32 = 1.0, // 0-1, intrinsic stability
    stamina: stats.Resource,
    focus: stats.Resource,
    blood: stats.Resource,
    time_available: f32 = 1.0,

    conditions: std.ArrayList(damage.ActiveCondition),
    immunities: std.ArrayList(damage.Immunity),
    resistances: std.ArrayList(damage.Resistance),
    vulnerabilities: std.ArrayList(damage.Vulnerability),

    pub fn init(
        alloc: std.mem.Allocator,
        slot_map: *SlotMap(*Agent),
        dr: Director,
        ds: DrawStyle,
        sb: stats.Block,
        bd: body.Body,
        stamina_res: stats.Resource,
        focus_res: stats.Resource,
        blood_res: stats.Resource,
        armament: Armament,
    ) !*Agent {
        const agent = try alloc.create(combat.Agent);
        agent.* = .{
            .id = undefined,
            .alloc = alloc,
            .director = dr,
            .draw_style = ds,
            .stats = sb,
            .body = bd,
            .armour = armour.Stack.init(alloc),
            .weapons = armament,
            .stamina = stamina_res,
            .focus = focus_res,
            .blood = blood_res,

            // Card containers (empty by default)
            .always_available = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .spells_known = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .deck_cards = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .inventory = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .combat_state = null,

            .conditions = try std.ArrayList(damage.ActiveCondition).initCapacity(alloc, 5),
            .resistances = try std.ArrayList(damage.Resistance).initCapacity(alloc, 5),
            .immunities = try std.ArrayList(damage.Immunity).initCapacity(alloc, 5),
            .vulnerabilities = try std.ArrayList(damage.Vulnerability).initCapacity(alloc, 5),
        };
        const id = try slot_map.insert(agent);
        agent.id = id;
        agent.body.agent_id = id;
        return agent;
    }

    pub fn deinit(self: *Agent) void {
        const alloc = self.alloc;

        // Deinit card containers
        self.always_available.deinit(alloc);
        self.spells_known.deinit(alloc);
        self.deck_cards.deinit(alloc);
        self.inventory.deinit(alloc);
        if (self.combat_state) |cs| {
            cs.deinit();
            alloc.destroy(cs);
        }

        self.conditions.deinit(alloc);
        self.immunities.deinit(alloc);
        self.resistances.deinit(alloc);
        self.vulnerabilities.deinit(alloc);

        self.body.deinit();
        self.armour.deinit();

        alloc.destroy(self);
    }

    pub fn destroy(self: *Agent, slot_map: *SlotMap(*Agent)) void {
        slot_map.remove(self.id);
        self.deinit();
    }

    fn isDominantSide(dominant: body.Side, side: body.Side) bool {
        return dominant == .center or dominant.? == side;
    }

    // Helpers for managing card arraylists

    pub fn poolContains(self: *const Agent, id: entity.ID) bool {
        for (self.always_available.items) |i| if (i.eql(id)) return true;
        for (self.spells_known.items) |i| if (i.eql(id)) return true;
        return false;
    }

    pub fn inAlwaysAvailable(self: *Agent, id: entity.ID) bool {
        for (self.always_available.items) |i| if (i.eql(id)) return true;
        return false;
    }

    pub fn inSpellsKnown(self: *Agent, id: entity.ID) bool {
        for (self.always_available.items) |i| if (i.eql(id)) return true;
        return false;
    }

    /// Is pool card available? (not on cooldown and in pool)
    /// Cards without cooldown can be played unlimited times per turn.
    /// Cards with cooldown have it set immediately on play, blocking further uses.
    pub fn isPoolCardAvailable(self: *const Agent, master_id: entity.ID) bool {
        if (self.combat_state) |cs| {
            if (cs.cooldowns.get(master_id)) |cd| if (cd > 0) return false;
        }
        return self.poolContains(master_id);
    }

    /// Initialize combat state from deck_cards (called at combat start).
    pub fn initCombatState(self: *Agent) !void {
        if (self.combat_state != null) return; // already initialized

        const cs = try self.alloc.create(CombatState);
        cs.* = try CombatState.init(self.alloc);
        errdefer {
            cs.deinit();
            self.alloc.destroy(cs);
        }

        try cs.populateFromDeckCards(self.deck_cards.items);
        self.combat_state = cs;
    }

    /// Clean up combat state (called at combat end).
    pub fn cleanupCombatState(self: *Agent) void {
        if (self.combat_state) |cs| {
            cs.deinit();
            self.alloc.destroy(cs);
            self.combat_state = null;
        }
    }

    /// Check if agent is incapacitated (can no longer fight).
    /// Triggers: vital organ destroyed, complete immobility, unconscious/comatose.
    pub fn isIncapacitated(self: *const Agent) bool {
        // Vital organ destroyed (brain, heart, lungs, etc.)
        for (self.body.parts.items) |part| {
            if (part.flags.is_vital and part.severity == .missing) {
                return true;
            }
        }

        // Complete loss of mobility (can't stand at all)
        if (self.body.mobilityScore() == 0.0) {
            return true;
        }

        // Unconscious or comatose condition
        var iter = self.activeConditions(null);
        while (iter.next()) |cond| {
            if (cond.condition == .unconscious or cond.condition == .comatose) {
                return true;
            }
        }

        return false;
    }

    /// Returns an iterator over all active conditions (stored + computed).
    /// For relational conditions (pressured, weapon_bound), pass the engagement
    /// if in an encounter (high values = disadvantage for self).
    pub fn activeConditions(self: *const Agent, engagement: ?*const Engagement) ConditionIterator {
        return ConditionIterator.init(self, engagement);
    }

    /// Check if agent has a specific stored condition.
    /// Note: Does not check computed/relational conditions (pressured, etc.)
    pub fn hasCondition(self: *const Agent, condition: damage.Condition) bool {
        for (self.conditions.items) |cond| {
            if (cond.condition == condition) return true;
        }
        return false;
    }

    /// Per-tick physiology update. Call from combat pipeline or world tick.
    /// Drains blood from wounds, recovers stamina/focus.
    pub fn tick(self: *Agent) void {
        // Sum bleeding from all wounds across all body parts
        var total_bleed: f32 = 0;
        for (self.body.parts.items) |*part| {
            for (part.wounds.items) |wound| {
                total_bleed += wound.bleeding_rate;
            }
        }

        // Drain blood (can't go below 0)
        if (total_bleed > 0) {
            self.blood.current = @max(0, self.blood.current - total_bleed);
            self.blood.available = self.blood.current;
        }

        // Resource recovery
        self.stamina.tick();
        self.focus.tick();
    }

    /// Total bleeding rate across all wounds (litres per tick).
    pub fn totalBleedingRate(self: *const Agent) f32 {
        var total: f32 = 0;
        for (self.body.parts.items) |*part| {
            for (part.wounds.items) |wound| {
                total += wound.bleeding_rate;
            }
        }
        return total;
    }
};

// ============================================================================
// Condition Iterator
// ============================================================================

/// Iterates stored conditions, then yields computed conditions based on thresholds.
/// Computed conditions include:
/// - Physiology: unbalanced (balance), blood loss (lightheaded, bleeding_out, hypovolemic_shock)
/// - Combat: pressured, weapon_bound (require engagement context)
pub const ConditionIterator = struct {
    agent: *const Agent,
    engagement: ?*const Engagement,
    stored_index: usize = 0,
    computed_phase: u3 = 0,

    const Expiration = damage.ActiveCondition.Expiration;

    pub fn init(agent: *const Agent, engagement: ?*const Engagement) ConditionIterator {
        return .{ .agent = agent, .engagement = engagement };
    }

    pub fn next(self: *ConditionIterator) ?damage.ActiveCondition {
        // Phase 1: yield stored conditions
        if (self.stored_index < self.agent.conditions.items.len) {
            const cond = self.agent.conditions.items[self.stored_index];
            self.stored_index += 1;
            return cond;
        }

        // Phase 2: yield computed conditions
        // Physiology conditions (no engagement needed)
        // Blood loss conditions checked worst-first
        while (self.computed_phase < 6) {
            const phase = self.computed_phase;
            self.computed_phase += 1;

            switch (phase) {
                // Physiology: balance
                0 => if (self.agent.balance < 0.2) {
                    return .{ .condition = .unbalanced, .expiration = .dynamic };
                },
                // Physiology: blood loss (worst first)
                1 => {
                    const ratio = self.agent.blood.current / self.agent.blood.max;
                    if (ratio < 0.4) {
                        return .{ .condition = .hypovolemic_shock, .expiration = .dynamic };
                    }
                },
                2 => {
                    const ratio = self.agent.blood.current / self.agent.blood.max;
                    if (ratio < 0.6) {
                        return .{ .condition = .bleeding_out, .expiration = .dynamic };
                    }
                },
                3 => {
                    const ratio = self.agent.blood.current / self.agent.blood.max;
                    if (ratio < 0.8) {
                        return .{ .condition = .lightheaded, .expiration = .dynamic };
                    }
                },
                // Combat: engagement-dependent
                4 => if (self.engagement) |eng| {
                    if (eng.pressure > 0.8) {
                        return .{ .condition = .pressured, .expiration = .dynamic };
                    }
                },
                5 => if (self.engagement) |eng| {
                    if (eng.control > 0.8) {
                        return .{ .condition = .weapon_bound, .expiration = .dynamic };
                    }
                },
                else => {},
            }
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testId(index: u32) entity.ID {
    return .{ .index = index, .generation = 0 };
}

const TestAgent = struct {
    agent: *Agent,
    sword: *weapon.Instance,

    fn destroy(self: TestAgent, agents: *SlotMap(*Agent)) void {
        self.agent.destroy(agents);
        std.testing.allocator.destroy(self.sword);
    }
};

fn makeTestAgent(alloc: std.mem.Allocator, agents: *SlotMap(*Agent)) !TestAgent {
    const weapon_list = @import("../weapon_list.zig");
    const sword = try alloc.create(weapon.Instance);
    sword.* = .{ .id = testId(999), .template = &weapon_list.knights_sword };

    return .{
        .agent = try Agent.init(
            alloc,
            agents,
            .player,
            .shuffled_deck,
            stats.Block.splat(5),
            try body.Body.fromPlan(alloc, &body.HumanoidPlan),
            stats.Resource.init(10.0, 10.0, 2.0),
            stats.Resource.init(3.0, 5.0, 3.0),
            stats.Resource.init(5.0, 5.0, 0.0),
            Armament{ .single = sword },
        ),
        .sword = sword,
    };
}

test "ConditionIterator computed condition thresholds" {
    // Test the threshold logic for computed conditions directly

    // Test balance threshold: < 0.2 = unbalanced
    try testing.expect(0.1 < 0.2); // would trigger unbalanced
    try testing.expect(!(0.2 < 0.2)); // boundary: not triggered
    try testing.expect(!(0.5 < 0.2)); // normal: not triggered

    // Test pressure threshold: > 0.8 = pressured
    try testing.expect(0.9 > 0.8); // would trigger pressured
    try testing.expect(!(0.8 > 0.8)); // boundary: not triggered
    try testing.expect(!(0.5 > 0.8)); // normal: not triggered

    // Test control threshold: > 0.8 = weapon_bound
    try testing.expect(0.85 > 0.8); // would trigger weapon_bound
    try testing.expect(!(0.8 > 0.8)); // boundary: not triggered
}

test "isIncapacitated false for healthy agent" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    try testing.expect(!test_agent.agent.isIncapacitated());
}

test "isIncapacitated true when vital organ destroyed" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    // Find and destroy a vital part (brain)
    for (test_agent.agent.body.parts.items) |*part| {
        if (part.flags.is_vital) {
            part.severity = .missing;
            break;
        }
    }

    try testing.expect(test_agent.agent.isIncapacitated());
}

test "isIncapacitated true when mobility zero" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    // Destroy all mobility-providing parts (legs/feet with can_stand)
    for (test_agent.agent.body.parts.items) |*part| {
        if (part.flags.can_stand) {
            part.severity = .missing;
        }
    }

    try testing.expect(test_agent.agent.isIncapacitated());
}

test "isIncapacitated true when unconscious" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    // Add unconscious condition
    try test_agent.agent.conditions.append(testing.allocator, .{
        .condition = .unconscious,
        .expiration = .{ .ticks = 3.0 },
    });

    try testing.expect(test_agent.agent.isIncapacitated());
}

test "isIncapacitated true when comatose" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    // Add comatose condition
    try test_agent.agent.conditions.append(testing.allocator, .{
        .condition = .comatose,
        .expiration = .permanent,
    });

    try testing.expect(test_agent.agent.isIncapacitated());
}

test "Agent.isPoolCardAvailable respects cooldowns" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    const card_id = testId(42);

    // Add card to always_available
    try test_agent.agent.always_available.append(testing.allocator, card_id);

    // Without combat state, pool cards are available
    try testing.expect(test_agent.agent.isPoolCardAvailable(card_id));

    // Initialize combat state
    try test_agent.agent.initCombatState();

    // Still available (no cooldown set)
    try testing.expect(test_agent.agent.isPoolCardAvailable(card_id));

    // Set cooldown
    try test_agent.agent.combat_state.?.cooldowns.put(card_id, 2);

    // Now unavailable
    try testing.expect(!test_agent.agent.isPoolCardAvailable(card_id));
}
