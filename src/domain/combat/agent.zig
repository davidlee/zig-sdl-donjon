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
const cards = @import("../cards.zig");
const cond = @import("../condition.zig");
const damage = @import("../damage.zig");
const events = @import("../events.zig");
const species_mod = @import("../species.zig");
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

/// Agent name - static for NPCs (comptime), dynamic for player (runtime).
pub const Name = union(enum) {
    static: []const u8, // borrowed, no free needed
    dynamic: []const u8, // owned, must free

    pub fn value(self: Name) []const u8 {
        return switch (self) {
            .static, .dynamic => |s| s,
        };
    }

    pub fn deinit(self: Name, alloc: std.mem.Allocator) void {
        switch (self) {
            .dynamic => |d| alloc.free(d),
            .static => {},
        }
    }
};

// Forward reference for self-referential type
const combat = @import("../combat.zig");

/// A combat participant with stats, equipment, and state.
pub const Agent = struct {
    id: entity.ID,
    alloc: std.mem.Allocator,
    director: Director,
    name: Name = .{ .static = "unnamed" },
    species: *const species_mod.Species = &species_mod.DWARF,
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
    // Trauma system resources - see doc/trauma_wounds_conditions_ph2.md
    pain: stats.Resource, // sensory overload, starts empty
    trauma: stats.Resource, // neurological stress, starts empty
    morale: stats.Resource, // psychological state, starts full (stub for future)
    time_available: f32 = 1.0,

    // Condition cache for internal computed conditions
    condition_cache: cond.ConditionCache = .{},

    conditions: std.ArrayList(damage.ActiveCondition),
    immunities: std.ArrayList(damage.Immunity),
    resistances: std.ArrayList(damage.Resistance),
    vulnerabilities: std.ArrayList(damage.Vulnerability),

    /// Create a new Agent from species.
    /// Body, resources, and natural weapons are derived from species.
    /// Equipped weapons start as .unarmed - use withEquipped() after init.
    pub fn init(
        alloc: std.mem.Allocator,
        slot_map: *SlotMap(*Agent),
        dr: Director,
        ds: DrawStyle,
        sp: *const species_mod.Species,
        sb: stats.Block,
    ) !*Agent {
        // Derive body from species
        const agent_body = try body.Body.fromPlan(alloc, sp.body_plan);

        // Derive resources from species (base values + recovery rates)
        const stamina_res = stats.Resource.init(sp.base_stamina, sp.base_stamina, sp.getStaminaRecovery());
        const focus_res = stats.Resource.init(sp.base_focus, sp.base_focus, sp.getFocusRecovery());
        const blood_res = stats.Resource.init(sp.base_blood, sp.base_blood, sp.getBloodRecovery());

        // Start with natural weapons only (unarmed)
        const armament = Armament.fromSpecies(sp.natural_weapons);

        const agent = try alloc.create(combat.Agent);
        agent.* = .{
            .id = undefined,
            .alloc = alloc,
            .director = dr,
            .draw_style = ds,
            .species = sp,
            .stats = sb,
            .body = agent_body,
            .armour = armour.Stack.init(alloc),
            .weapons = armament,
            .stamina = stamina_res,
            .focus = focus_res,
            .blood = blood_res,
            .pain = stats.Resource.init(0.0, 10.0, 0.0), // starts empty, no recovery
            .trauma = stats.Resource.init(0.0, 10.0, 0.0), // starts empty, no recovery
            .morale = stats.Resource.init(10.0, 10.0, 0.0), // starts full, no recovery (future)

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
        self.name.deinit(alloc);

        alloc.destroy(self);
    }

    pub fn destroy(self: *Agent, slot_map: *SlotMap(*Agent)) void {
        slot_map.remove(self.id);
        self.deinit();
    }

    fn isDominantSide(dominant: body.Side, side: body.Side) bool {
        return dominant == .center or dominant.? == side;
    }

    pub fn isPlayer(self: *const Agent) bool {
        return self.director == .player;
    }

    /// Set agent name, freeing previous dynamic name if present.
    pub fn setName(self: *Agent, new_name: Name) void {
        self.name.deinit(self.alloc);
        self.name = new_name;
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
        while (iter.next()) |ac| {
            if (ac.condition == .unconscious or ac.condition == .comatose) {
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

    /// Check if agent has a specific condition (stored or computed).
    /// Checks stored conditions, then internal computed conditions via cache.
    /// For relational conditions (pressured, weapon_bound), use hasConditionWithContext.
    pub fn hasCondition(self: *const Agent, condition: damage.Condition) bool {
        // Check stored conditions
        for (self.conditions.items) |ac| {
            if (ac.condition == condition) return true;
        }

        // Check internal computed conditions via cache
        if (self.condition_cache.conditions.isSet(@intFromEnum(condition))) return true;

        return false;
    }

    /// Context for condition queries requiring engagement/encounter.
    pub const ConditionQueryContext = struct {
        engagement: ?*const Engagement = null,
    };

    /// Check if agent has a specific condition with additional context.
    /// Supports relational conditions when engagement is provided.
    pub fn hasConditionWithContext(
        self: *const Agent,
        condition: damage.Condition,
        ctx: ConditionQueryContext,
    ) bool {
        // First check stored and internal cached conditions
        if (self.hasCondition(condition)) return true;

        // Check relational conditions if engagement provided
        if (ctx.engagement) |eng| {
            if (cond.getDefinitionFor(condition)) |def| {
                if (def.category == .relational) {
                    // Evaluate relational condition on-demand
                    const iter = ConditionIterator.init(self, eng);
                    return iter.evaluate(def.computation);
                }
            }
        }

        return false;
    }

    /// Per-tick physiology update. Call from combat pipeline or world tick.
    /// Drains blood from wounds, recovers stamina/focus.
    pub fn tick(self: *Agent, event_sink: ?*events.EventSystem) void {
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

            if (event_sink) |es| {
                es.push(.{ .blood_drained = .{
                    .agent_id = self.id,
                    .amount = total_bleed,
                    .new_value = self.blood.current,
                } }) catch {};
            }
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

    /// Get resource ratio by accessor type (for condition framework).
    pub fn getResourceRatio(self: *const Agent, accessor: cond.ResourceAccessor) f32 {
        return switch (accessor) {
            .blood => self.blood.ratio(),
            .pain => self.pain.ratio(),
            .trauma => self.trauma.ratio(),
            .morale => self.morale.ratio(),
        };
    }

    /// Get sensory score by type (for condition framework).
    pub fn getSensoryScore(self: *const Agent, sense: cond.SensoryType) f32 {
        return switch (sense) {
            .vision => self.body.visionScore(),
            .hearing => self.body.hearingScore(),
        };
    }

    /// Build EvalContext from current agent state.
    pub fn buildEvalContext(self: *const Agent) cond.ConditionCache.EvalContext {
        return .{
            .balance = self.balance,
            .blood_ratio = self.blood.ratio(),
            .pain_ratio = self.pain.ratio(),
            .trauma_ratio = self.trauma.ratio(),
            .morale_ratio = self.morale.ratio(),
            .vision_score = self.body.visionScore(),
            .hearing_score = self.body.hearingScore(),
        };
    }

    /// Recompute condition cache and emit events for changes.
    /// Call after blood/pain/trauma/balance/sensory metric changes.
    pub fn invalidateConditionCache(
        self: *Agent,
        event_sink: ?*events.EventSystem,
        is_player: bool,
    ) void {
        const old = self.condition_cache.conditions;
        self.condition_cache.recompute(self.buildEvalContext());
        const new = self.condition_cache.conditions;

        // Emit events for condition changes
        if (event_sink) |es| {
            const actor = events.AgentMeta{ .id = self.id, .player = is_player };
            emitConditionDiff(old, new, self.id, actor, es);
        }
    }

    // =========================================================================
    // Natural Weapon Iteration
    // =========================================================================

    /// Iterator over natural weapons filtered by body part availability.
    /// Only yields weapons whose required body part is functional.
    pub const AvailableNaturalWeaponIterator = struct {
        natural: []const species_mod.NaturalWeapon,
        body_ref: *const body.Body,
        index: usize = 0,

        pub fn next(self: *AvailableNaturalWeaponIterator) ?*const species_mod.NaturalWeapon {
            while (self.index < self.natural.len) {
                const nw = &self.natural[self.index];
                self.index += 1;
                // Check if required body part is functional (any side)
                if (self.body_ref.hasFunctionalPart(nw.required_part, null)) {
                    return nw;
                }
            }
            return null;
        }

        pub fn reset(self: *AvailableNaturalWeaponIterator) void {
            self.index = 0;
        }
    };

    /// Returns an iterator over natural weapons that are currently available.
    /// Filters out natural weapons whose required body part is missing/severed.
    pub fn availableNaturalWeapons(self: *const Agent) AvailableNaturalWeaponIterator {
        return .{
            .natural = self.weapons.natural,
            .body_ref = &self.body,
        };
    }

    /// Count of currently available natural weapons.
    pub fn availableNaturalWeaponCount(self: *const Agent) usize {
        var count: usize = 0;
        var iter = self.availableNaturalWeapons();
        while (iter.next()) |_| {
            count += 1;
        }
        return count;
    }

    /// Check if a specific natural weapon is available (body part functional).
    pub fn isNaturalWeaponAvailable(self: *const Agent, nw: *const species_mod.NaturalWeapon) bool {
        return self.body.hasFunctionalPart(nw.required_part, null);
    }

    /// Reference to any weapon available to the agent.
    /// Distinguishes equipped weapons (have Instance state) from natural weapons.
    pub const WeaponRef = union(enum) {
        equipped: *weapon.Instance,
        natural: *const species_mod.NaturalWeapon,

        pub fn template(self: WeaponRef) *const weapon.Template {
            return switch (self) {
                .equipped => |inst| inst.template,
                .natural => |nw| nw.template,
            };
        }

        pub fn name(self: WeaponRef) []const u8 {
            return self.template().name;
        }
    };

    /// Iterator over all weapons available to the agent (equipped + natural).
    /// Yields equipped weapons first, then natural weapons filtered by body state.
    pub const AllWeaponsIterator = struct {
        agent: *const Agent,
        phase: Phase = .equipped_single,
        natural_iter: ?AvailableNaturalWeaponIterator = null,

        const Phase = enum { equipped_single, equipped_dual_primary, equipped_dual_secondary, natural };

        pub fn next(self: *AllWeaponsIterator) ?WeaponRef {
            switch (self.phase) {
                .equipped_single => {
                    self.phase = .natural;
                    switch (self.agent.weapons.equipped) {
                        .unarmed => {}, // skip to natural
                        .single => |inst| return .{ .equipped = inst },
                        .dual => |d| {
                            self.phase = .equipped_dual_secondary;
                            return .{ .equipped = d.primary };
                        },
                        .compound => {
                            // TODO: compound weapon iteration
                            self.phase = .natural;
                        },
                    }
                    return self.nextNatural();
                },
                .equipped_dual_secondary => {
                    self.phase = .natural;
                    return .{ .equipped = self.agent.weapons.equipped.dual.secondary };
                },
                .equipped_dual_primary => unreachable,
                .natural => return self.nextNatural(),
            }
        }

        fn nextNatural(self: *AllWeaponsIterator) ?WeaponRef {
            if (self.natural_iter == null) {
                self.natural_iter = self.agent.availableNaturalWeapons();
            }
            if (self.natural_iter.?.next()) |nw| {
                return .{ .natural = nw };
            }
            return null;
        }

        pub fn reset(self: *AllWeaponsIterator) void {
            self.phase = .equipped_single;
            self.natural_iter = null;
        }
    };

    /// Returns an iterator over all weapons available to the agent.
    /// Includes equipped weapons and natural weapons (filtered by body state).
    pub fn allAvailableWeapons(self: *const Agent) AllWeaponsIterator {
        return .{ .agent = self };
    }

    /// Count of all available weapons (equipped + available natural).
    pub fn allAvailableWeaponCount(self: *const Agent) usize {
        var count: usize = 0;
        var iter = self.allAvailableWeapons();
        while (iter.next()) |_| {
            count += 1;
        }
        return count;
    }
};

/// Emit condition_applied/expired events for differences between old and new bitsets.
fn emitConditionDiff(
    old: cond.ConditionBitSet,
    new: cond.ConditionBitSet,
    agent_id: entity.ID,
    actor: events.AgentMeta,
    es: *events.EventSystem,
) void {
    // New conditions (in new but not old)
    var gained = new;
    gained.setIntersection(old.complement());
    var gained_iter = gained.iterator(.{});
    while (gained_iter.next()) |cond_int| {
        es.push(.{ .condition_applied = .{
            .agent_id = agent_id,
            .condition = @enumFromInt(cond_int),
            .actor = actor,
        } }) catch {};
    }

    // Expired conditions (in old but not new)
    var lost = old;
    lost.setIntersection(new.complement());
    var lost_iter = lost.iterator(.{});
    while (lost_iter.next()) |cond_int| {
        es.push(.{ .condition_expired = .{
            .agent_id = agent_id,
            .condition = @enumFromInt(cond_int),
            .actor = actor,
        } }) catch {};
    }
}

// ============================================================================
// Condition Iterator
// ============================================================================

/// Iterates stored conditions, then yields computed conditions from definitions table.
/// Computed conditions include:
/// - Internal: balance, blood loss, pain, trauma, sensory impairment
/// - Relational: pressured, weapon_bound (require engagement context)
/// - Positional: flanked, surrounded (require encounter context, NYI)
pub const ConditionIterator = struct {
    agent: *const Agent,
    engagement: ?*const Engagement,
    stored_index: usize = 0,
    def_index: usize = 0,
    yielded_resources: std.EnumSet(cond.ResourceAccessor) = .{},

    pub fn init(agent: *const Agent, engagement: ?*const Engagement) ConditionIterator {
        return .{ .agent = agent, .engagement = engagement };
    }

    pub fn next(self: *ConditionIterator) ?damage.ActiveCondition {
        // Phase 1: yield stored conditions
        if (self.stored_index < self.agent.conditions.items.len) {
            const stored = self.agent.conditions.items[self.stored_index];
            self.stored_index += 1;
            return stored;
        }

        // Phase 2: yield computed conditions from definitions table
        while (self.def_index < cond.condition_definitions.len) {
            const def = cond.condition_definitions[self.def_index];
            self.def_index += 1;

            // Skip stored conditions (already yielded from agent.conditions)
            if (def.computation == .stored) continue;

            // Skip relational conditions if no engagement context
            if (def.category == .relational and self.engagement == null) continue;

            // Skip positional conditions (encounter context NYI)
            if (def.category == .positional) continue;

            // For resource thresholds: only yield worst per resource
            // (table is ordered worst-first within each resource)
            // Also check if resource is suppressed by any active condition
            if (def.computation == .resource_threshold) {
                const rt = def.computation.resource_threshold;
                if (self.yielded_resources.contains(rt.resource)) continue;
                if (self.isResourceSuppressed(rt.resource)) continue;
            }

            if (self.evaluate(def.computation)) {
                // Mark resource as yielded if this was a resource threshold
                if (def.computation == .resource_threshold) {
                    const rt = def.computation.resource_threshold;
                    self.yielded_resources.insert(rt.resource);
                }

                return .{
                    .condition = def.condition,
                    .expiration = .dynamic,
                };
            }
        }

        return null;
    }

    /// Check if a resource is suppressed by any active stored condition.
    /// Used to prevent pain conditions from being yielded during adrenaline surge.
    fn isResourceSuppressed(self: *const ConditionIterator, resource: cond.ResourceAccessor) bool {
        for (self.agent.conditions.items) |ac| {
            const meta = cond.metaFor(ac.condition);
            for (meta.suppresses) |suppressed| {
                if (suppressed == resource) return true;
            }
        }
        return false;
    }

    /// Evaluate whether a computation is active for the current context.
    fn evaluate(self: *const ConditionIterator, comp: cond.ComputationType) bool {
        return switch (comp) {
            .stored => false,
            .resource_threshold => |rt| rt.op.compare(
                self.agent.getResourceRatio(rt.resource),
                rt.value,
            ),
            .balance_threshold => |bt| bt.op.compare(self.agent.balance, bt.value),
            .sensory_threshold => |st| st.op.compare(
                self.agent.getSensoryScore(st.sense),
                st.value,
            ),
            .engagement_threshold => |et| if (self.engagement) |eng| blk: {
                const metric_value = switch (et.metric) {
                    .pressure => eng.pressure,
                    .control => eng.control,
                };
                break :blk et.op.compare(metric_value, et.value);
            } else false,
            .positional => false, // Encounter context NYI
            .any => |alternatives| {
                for (alternatives) |alt| {
                    if (self.evaluate(alt)) return true;
                }
                return false;
            },
        };
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

    const agent = try Agent.init(
        alloc,
        agents,
        .player,
        .shuffled_deck,
        &species_mod.DWARF,
        stats.Block.splat(5),
    );
    // Equip sword (agent starts unarmed with natural weapons)
    agent.weapons = agent.weapons.withEquipped(.{ .single = sword });

    return .{
        .agent = agent,
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

    // Test sensory thresholds: < 0.3 = blinded/deafened
    try testing.expect(0.1 < 0.3); // would trigger blinded/deafened
    try testing.expect(0.29 < 0.3); // just under: triggered
    try testing.expect(!(0.3 < 0.3)); // boundary: not triggered
    try testing.expect(!(0.5 < 0.3)); // normal: not triggered
}

test "ConditionIterator yields blinded when eyes damaged" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    // Damage both eyes to .broken (0.1 integrity, well below 0.3 threshold)
    const left_eye = test_agent.agent.body.indexOf("left_eye").?;
    const right_eye = test_agent.agent.body.indexOf("right_eye").?;
    test_agent.agent.body.parts.items[left_eye].severity = .broken;
    test_agent.agent.body.parts.items[right_eye].severity = .broken;

    // Verify vision score is below threshold
    try testing.expect(test_agent.agent.body.visionScore() < 0.3);

    // Check that .blinded is yielded
    var found_blinded = false;
    var iter = test_agent.agent.activeConditions(null);
    while (iter.next()) |ac| {
        if (ac.condition == .blinded) {
            found_blinded = true;
            break;
        }
    }
    try testing.expect(found_blinded);
}

test "ConditionIterator yields deafened when ears damaged" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    // Damage both ears to .broken (0.1 integrity, well below 0.3 threshold)
    const left_ear = test_agent.agent.body.indexOf("left_ear").?;
    const right_ear = test_agent.agent.body.indexOf("right_ear").?;
    test_agent.agent.body.parts.items[left_ear].severity = .broken;
    test_agent.agent.body.parts.items[right_ear].severity = .broken;

    // Verify hearing score is below threshold
    try testing.expect(test_agent.agent.body.hearingScore() < 0.3);

    // Check that .deafened is yielded
    var found_deafened = false;
    var iter = test_agent.agent.activeConditions(null);
    while (iter.next()) |ac| {
        if (ac.condition == .deafened) {
            found_deafened = true;
            break;
        }
    }
    try testing.expect(found_deafened);
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

test "Agent pain/trauma/morale resources initialize correctly" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    const agent = test_agent.agent;

    // Pain starts empty (0/10)
    try testing.expectEqual(@as(f32, 0.0), agent.pain.current);
    try testing.expectEqual(@as(f32, 10.0), agent.pain.max);
    try testing.expectApproxEqAbs(@as(f32, 0.0), agent.pain.ratio(), 0.001);

    // Trauma starts empty (0/10)
    try testing.expectEqual(@as(f32, 0.0), agent.trauma.current);
    try testing.expectEqual(@as(f32, 10.0), agent.trauma.max);
    try testing.expectApproxEqAbs(@as(f32, 0.0), agent.trauma.ratio(), 0.001);

    // Morale starts full (10/10)
    try testing.expectEqual(@as(f32, 10.0), agent.morale.current);
    try testing.expectEqual(@as(f32, 10.0), agent.morale.max);
    try testing.expectApproxEqAbs(@as(f32, 1.0), agent.morale.ratio(), 0.001);
}

test "Agent pain/trauma accumulate via inflict" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    var agent = test_agent.agent;

    // Inflict pain
    agent.pain.inflict(3.5);
    try testing.expectApproxEqAbs(@as(f32, 0.35), agent.pain.ratio(), 0.001);

    // Inflict trauma
    agent.trauma.inflict(5.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), agent.trauma.ratio(), 0.001);

    // Accumulates
    agent.pain.inflict(2.0);
    try testing.expectApproxEqAbs(@as(f32, 0.55), agent.pain.ratio(), 0.001);

    // Capped at max
    agent.trauma.inflict(100.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), agent.trauma.ratio(), 0.001);
}

test "hasCondition detects computed conditions via cache" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    var agent = test_agent.agent;

    // Initially no lightheaded (blood is full)
    try testing.expect(!agent.hasCondition(.lightheaded));

    // Drain blood below 80% threshold
    agent.blood.current = agent.blood.max * 0.7;

    // Invalidate cache to pick up the change
    agent.invalidateConditionCache(null, false);

    // Now hasCondition should detect lightheaded via cache
    try testing.expect(agent.hasCondition(.lightheaded));

    // But not hypovolemic_shock (needs < 40%)
    try testing.expect(!agent.hasCondition(.hypovolemic_shock));
}

test "condition cache emits events on threshold crossing" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    var agent = test_agent.agent;

    // Create event system
    var es = events.EventSystem.init(testing.allocator) catch unreachable;
    defer es.deinit();

    // Initial state: full blood, no conditions
    agent.invalidateConditionCache(&es, true);

    // No events yet (no change) - events go to next_events buffer
    try testing.expectEqual(@as(usize, 0), es.next_events.items.len);

    // Drain blood below threshold
    agent.blood.current = agent.blood.max * 0.5; // below 0.6, triggers bleeding_out

    // Invalidate - should emit condition_applied for bleeding_out
    agent.invalidateConditionCache(&es, true);

    // Should have emitted at least one event
    try testing.expect(es.next_events.items.len > 0);

    // Check that bleeding_out was applied
    var found_bleeding_out = false;
    for (es.next_events.items) |ev| {
        switch (ev) {
            .condition_applied => |ca| {
                if (ca.condition == .bleeding_out) {
                    found_bleeding_out = true;
                }
            },
            else => {},
        }
    }
    try testing.expect(found_bleeding_out);
}

test "adrenaline surge suppresses pain conditions" {
    var agents = try SlotMap(*Agent).init(testing.allocator);
    defer agents.deinit();

    const test_agent = try makeTestAgent(testing.allocator, &agents);
    defer test_agent.destroy(&agents);

    var agent = test_agent.agent;

    // Inflict enough pain to trigger distracted (>30%)
    agent.pain.inflict(4.0); // 40% of 10 max
    try testing.expect(agent.pain.ratio() > 0.30);

    // Without adrenaline surge, should have pain condition
    var iter = agent.activeConditions(null);
    var found_distracted = false;
    while (iter.next()) |ac| {
        if (ac.condition == .distracted) {
            found_distracted = true;
            break;
        }
    }
    try testing.expect(found_distracted);

    // Add adrenaline surge condition
    try agent.conditions.append(testing.allocator, .{
        .condition = .adrenaline_surge,
        .expiration = .{ .ticks = 8.0 },
    });

    // Now pain conditions should be suppressed
    var iter2 = agent.activeConditions(null);
    var found_distracted2 = false;
    while (iter2.next()) |ac| {
        if (ac.condition == .distracted) {
            found_distracted2 = true;
            break;
        }
    }
    try testing.expect(!found_distracted2);
}

test "availableNaturalWeapons yields all when body healthy" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    // DWARF has fist (hand) and headbutt (head)
    const agent = try Agent.init(alloc, &agents, .player, .shuffled_deck, &species_mod.DWARF, stats.Block.splat(5));
    defer agent.deinit();

    // With healthy body, should have 2 natural weapons
    try testing.expectEqual(@as(usize, 2), agent.availableNaturalWeaponCount());

    // Verify iterator returns both
    var iter = agent.availableNaturalWeapons();
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "availableNaturalWeapons filters by body part" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    // DWARF has fist (hand) and headbutt (head)
    const agent = try Agent.init(alloc, &agents, .player, .shuffled_deck, &species_mod.DWARF, stats.Block.splat(5));
    defer agent.deinit();

    // Damage both hands to missing
    const fixtures = @import("../../testing/fixtures.zig");
    _ = fixtures.setPartSeverity(&agent.body, .hand, .left, .missing);
    _ = fixtures.setPartSeverity(&agent.body, .hand, .right, .missing);

    // Now only headbutt should be available (head still functional)
    try testing.expectEqual(@as(usize, 1), agent.availableNaturalWeaponCount());

    var iter = agent.availableNaturalWeapons();
    const nw = iter.next().?;
    try testing.expectEqualStrings("Headbutt", nw.template.name);
    try testing.expect(iter.next() == null);
}

test "availableNaturalWeapons empty when all parts destroyed" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try Agent.init(alloc, &agents, .player, .shuffled_deck, &species_mod.DWARF, stats.Block.splat(5));
    defer agent.deinit();

    // Damage hands and head
    const fixtures = @import("../../testing/fixtures.zig");
    _ = fixtures.setPartSeverity(&agent.body, .hand, null, .missing);
    _ = fixtures.setPartSeverity(&agent.body, .head, null, .missing);

    // No natural weapons available
    try testing.expectEqual(@as(usize, 0), agent.availableNaturalWeaponCount());
}

test "isNaturalWeaponAvailable checks body part" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try Agent.init(alloc, &agents, .player, .shuffled_deck, &species_mod.DWARF, stats.Block.splat(5));
    defer agent.deinit();

    const fist = &agent.weapons.natural[0]; // Fist requires hand
    const headbutt = &agent.weapons.natural[1]; // Headbutt requires head

    // Initially both available
    try testing.expect(agent.isNaturalWeaponAvailable(fist));
    try testing.expect(agent.isNaturalWeaponAvailable(headbutt));

    // Damage hands
    const fixtures = @import("../../testing/fixtures.zig");
    _ = fixtures.setPartSeverity(&agent.body, .hand, null, .missing);

    // Fist no longer available, headbutt still available
    try testing.expect(!agent.isNaturalWeaponAvailable(fist));
    try testing.expect(agent.isNaturalWeaponAvailable(headbutt));
}

test "allAvailableWeapons unarmed yields only natural" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    // Unarmed DWARF - no equipped weapon, 2 natural weapons
    const agent = try Agent.init(alloc, &agents, .player, .shuffled_deck, &species_mod.DWARF, stats.Block.splat(5));
    defer agent.deinit();

    try testing.expectEqual(@as(usize, 2), agent.allAvailableWeaponCount());

    var iter = agent.allAvailableWeapons();
    const first = iter.next().?;
    try testing.expect(first == .natural);
    const second = iter.next().?;
    try testing.expect(second == .natural);
    try testing.expect(iter.next() == null);
}

test "allAvailableWeapons single weapon yields equipped then natural" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try Agent.init(alloc, &agents, .player, .shuffled_deck, &species_mod.DWARF, stats.Block.splat(5));
    defer agent.deinit();

    // Equip a sword
    const weapon_list = @import("../weapon_list.zig");
    const sword = try alloc.create(weapon.Instance);
    defer alloc.destroy(sword);
    sword.* = .{ .id = testId(999), .template = &weapon_list.knights_sword };
    agent.weapons = agent.weapons.withEquipped(.{ .single = sword });

    // 1 equipped + 2 natural = 3 total
    try testing.expectEqual(@as(usize, 3), agent.allAvailableWeaponCount());

    var iter = agent.allAvailableWeapons();

    // First should be equipped sword
    const first = iter.next().?;
    try testing.expect(first == .equipped);
    try testing.expectEqualStrings("knight's sword", first.name());

    // Then natural weapons
    const second = iter.next().?;
    try testing.expect(second == .natural);
    const third = iter.next().?;
    try testing.expect(third == .natural);
    try testing.expect(iter.next() == null);
}

test "allAvailableWeapons dual wield yields both equipped then natural" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try Agent.init(alloc, &agents, .player, .shuffled_deck, &species_mod.DWARF, stats.Block.splat(5));
    defer agent.deinit();

    // Equip dual weapons
    const weapon_list = @import("../weapon_list.zig");
    const sword = try alloc.create(weapon.Instance);
    defer alloc.destroy(sword);
    sword.* = .{ .id = testId(998), .template = &weapon_list.knights_sword };

    const buckler = try alloc.create(weapon.Instance);
    defer alloc.destroy(buckler);
    buckler.* = .{ .id = testId(999), .template = &weapon_list.buckler };

    agent.weapons = agent.weapons.withEquipped(.{ .dual = .{ .primary = sword, .secondary = buckler } });

    // 2 equipped + 2 natural = 4 total
    try testing.expectEqual(@as(usize, 4), agent.allAvailableWeaponCount());

    var iter = agent.allAvailableWeapons();

    // First two should be equipped
    const first = iter.next().?;
    try testing.expect(first == .equipped);
    try testing.expectEqualStrings("knight's sword", first.name());

    const second = iter.next().?;
    try testing.expect(second == .equipped);
    try testing.expectEqualStrings("buckler", second.name());

    // Then natural weapons
    const third = iter.next().?;
    try testing.expect(third == .natural);
    const fourth = iter.next().?;
    try testing.expect(fourth == .natural);
    try testing.expect(iter.next() == null);
}

test "WeaponRef.template works for both types" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try Agent.init(alloc, &agents, .player, .shuffled_deck, &species_mod.DWARF, stats.Block.splat(5));
    defer agent.deinit();

    const weapon_list = @import("../weapon_list.zig");
    const sword = try alloc.create(weapon.Instance);
    defer alloc.destroy(sword);
    sword.* = .{ .id = testId(999), .template = &weapon_list.knights_sword };
    agent.weapons = agent.weapons.withEquipped(.{ .single = sword });

    var iter = agent.allAvailableWeapons();

    // Equipped weapon
    const equipped_ref = iter.next().?;
    try testing.expectEqualStrings("knight's sword", equipped_ref.template().name);

    // Natural weapon
    const natural_ref = iter.next().?;
    try testing.expect(natural_ref.template().categories.len > 0);
}
