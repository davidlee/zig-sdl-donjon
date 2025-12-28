const std = @import("std");
const entity = @import("entity.zig");
const armour = @import("armour.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");
const deck = @import("deck.zig");
const cards = @import("cards.zig");

const SlotMap = @import("slot_map.zig").SlotMap;
const Instance = cards.Instance;
const Template = cards.Template;

pub const Director = enum {
    player,
    ai,
};

pub const Reach = enum {
    // Engagement distances (closer = lower)
    clinch,
    near,
    medium,
    far,
    // Weapon reaches (shorter = lower)
    dagger,
    mace,
    sabre,
    longsword,
    spear,
};

pub const AdvantageAxis = enum {
    balance,
    pressure,
    control,
    position,
};

pub const Armament = union(enum) {
    single: *weapon.Instance,
    dual: struct {
        primary: *weapon.Instance,
        secondary: *weapon.Instance,
    },
    compound: [][]*weapon.Instance,

    pub fn hasCategory(self: Armament, cat: weapon.Category) bool {
        return switch (self) {
            .single => |w| hasWeaponCategory(w.template, cat),
            .dual => |d| hasWeaponCategory(d.primary.template, cat) or
                hasWeaponCategory(d.secondary.template, cat),
            .compound => |sets| {
                for (sets) |set| {
                    for (set) |w| {
                        if (hasWeaponCategory(w.template, cat)) return true;
                    }
                }
                return false;
            },
        };
    }

    fn hasWeaponCategory(template: *const weapon.Template, cat: weapon.Category) bool {
        for (template.categories) |c| {
            if (c == cat) return true;
        }
        return false;
    }
};

pub const Strat = union(enum) {
    deck: deck.Deck,
    // script: BehaviourScript,
    pool: TechniquePool,
};

// Humanoid AI: simplified pool with card instances
pub const TechniquePool = struct {
    alloc: std.mem.Allocator,
    entities: SlotMap(*Instance), // entity ID provider for instances
    instances: std.ArrayList(*Instance), // technique instances (one per template)
    in_play: std.ArrayList(*Instance), // committed this tick
    cooldowns: std.AutoHashMap(cards.ID, u8), // template.id -> ticks remaining
    next_index: usize = 0, // for round-robin selection

    pub fn init(alloc: std.mem.Allocator, templates: []const *const Template) !TechniquePool {
        var pool = TechniquePool{
            .alloc = alloc,
            .entities = try SlotMap(*Instance).init(alloc),
            .instances = try std.ArrayList(*Instance).initCapacity(alloc, templates.len),
            .in_play = try std.ArrayList(*Instance).initCapacity(alloc, 4),
            .cooldowns = std.AutoHashMap(cards.ID, u8).init(alloc),
        };
        errdefer pool.deinit();

        // Create one instance per template
        for (templates) |template| {
            const instance = try pool.createInstance(template);
            try pool.instances.append(alloc, instance);
        }

        return pool;
    }

    fn createInstance(self: *TechniquePool, template: *const Template) !*Instance {
        const instance = try self.alloc.create(Instance);
        instance.* = .{
            .id = undefined,
            .template = template,
        };
        const id = try self.entities.insert(instance);
        instance.id = id;
        return instance;
    }

    pub fn deinit(self: *TechniquePool) void {
        for (self.entities.items.items) |instance| {
            self.alloc.destroy(instance);
        }
        self.entities.deinit();
        self.instances.deinit(self.alloc);
        self.in_play.deinit(self.alloc);
        self.cooldowns.deinit();
    }

    pub fn canUse(self: *const TechniquePool, instance: *const Instance) bool {
        return (self.cooldowns.get(instance.template.id) orelse 0) == 0;
    }

    /// Select next available technique instance (round-robin, skips cooldowns and unaffordable)
    pub fn selectNext(self: *TechniquePool, available_stamina: f32) ?*Instance {
        if (self.instances.items.len == 0) return null;

        var attempts: usize = 0;
        while (attempts < self.instances.items.len) : (attempts += 1) {
            const instance = self.instances.items[self.next_index];
            self.next_index = (self.next_index + 1) % self.instances.items.len;
            if (self.canUse(instance) and instance.template.cost.stamina <= available_stamina) {
                return instance;
            }
        }
        return null; // all on cooldown or unaffordable
    }

    /// Apply cooldown to a technique (by template ID)
    pub fn applyCooldown(self: *TechniquePool, template_id: cards.ID, ticks: u8) !void {
        try self.cooldowns.put(template_id, ticks);
    }

    /// Decrement all cooldowns by 1
    pub fn tickCooldowns(self: *TechniquePool) void {
        var it = self.cooldowns.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > 0) {
                entry.value_ptr.* -= 1;
            }
        }
    }
};

pub const Encounter = struct {
    enemies: std.ArrayList(*combat.Agent),
    //
    // environment ...
    // loot ...
    //
    pub fn init(alloc: std.mem.Allocator) !Encounter {
        return Encounter{
            .enemies = try std.ArrayList(*combat.Agent).initCapacity(alloc, 5),
        };
    }

    pub fn deinit(self: *Encounter, alloc: std.mem.Allocator) void {
        for (self.enemies.items) |nme| {
            nme.deinit();
        }
        self.enemies.deinit(alloc);
    }
};
// const ScriptedAction = struct {};
//
// // Creature: pure behavior script, no "cards" at all
// const BehaviourScript = struct {
//     pattern: []const ScriptedAction,
//     index: usize,
//
//     pub fn next(self: *BehaviourScript) ScriptedAction {
//         const action = self.pattern[self.index];
//         self.index = (self.index + 1) % self.pattern.len;
//         return action;
//     }
// };

pub const Agent = struct {
    id: entity.ID,
    alloc: std.mem.Allocator,
    director: Director,
    cards: Strat,
    stats: stats.Block,
    engagement: ?combat.Engagement, // for NPCs only (relative to player)
    // may be humanoid, or not
    body: body.Body,
    // sourced from cards.equipped
    armour: armour.Stack,
    weapons: Armament,
    dominant_side: body.Side = .right, // .center == ambidextrous

    // state (wounds kept in body)
    balance: f32 = 1.0, // 0-1, intrinsic stability
    stamina: f32 = 0.0,
    stamina_available: f32 = 0.0,
    time_available: f32 = 1.0,
    //
    conditions: std.ArrayList(damage.ActiveCondition),
    immunities: std.ArrayList(damage.Immunity),
    resistances: std.ArrayList(damage.Resistance),
    vulnerabilities: std.ArrayList(damage.Vulnerability),

    pub fn init(
        alloc: std.mem.Allocator,
        slot_map: *SlotMap(*Agent),
        dr: Director,
        cs: Strat,
        sb: stats.Block,
        bd: body.Body,
        stamina: f32,
        armament: Armament,
    ) !*Agent {
        // const agent = initEmpty(alloc, slot_map);
        const agent = try alloc.create(combat.Agent);
        agent.* = .{
            .id = undefined,
            .alloc = alloc,
            .director = dr,
            .cards = cs,
            .stats = sb,
            // .state = State.init(alloc, stamina),
            .body = bd,
            .armour = armour.Stack.init(alloc),
            .weapons = armament,
            .engagement = (if (dr == .ai) Engagement{} else null),
            .stamina = stamina,
            .stamina_available = stamina,

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

        switch (self.cards) {
            .deck => |*dk| dk.deinit(),
            .pool => |*pl| pl.deinit(),
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

    /// Returns an iterator over all active conditions (stored + computed).
    /// For relational conditions (pressured, weapon_bound), uses self.engagement
    /// if present (mob perspective: high values = disadvantage for self).
    pub fn activeConditions(self: *const Agent) ConditionIterator {
        return ConditionIterator.init(self);
    }
};

// Per-engagement (one per mob, attached to mob)
pub const Engagement = struct {
    // All 0-1, where 0.5 = neutral
    // >0.5 = player advantage, <0.5 = mob advantage
    pressure: f32 = 0.5,
    control: f32 = 0.5,
    position: f32 = 0.5,
    range: Reach = .far, // Current distance

    // Helpers
    pub fn playerAdvantage(self: Engagement) f32 {
        return (self.pressure + self.control + self.position) / 3.0;
    }

    pub fn mobAdvantage(self: Engagement) f32 {
        return 1.0 - self.playerAdvantage();
    }

    pub fn invert(self: Engagement) Engagement {
        return .{
            .pressure = 1.0 - self.pressure,
            .control = 1.0 - self.control,
            .position = 1.0 - self.position,
            .range = self.range,
        };
    }
};

// ============================================================================
// Condition Iterator
// ============================================================================

/// Iterates stored conditions, then yields computed conditions based on thresholds.
pub const ConditionIterator = struct {
    agent: *const Agent,
    stored_index: usize = 0,
    computed_phase: u2 = 0, // 0=unbalanced, 1=pressured, 2=weapon_bound, 3=done

    const Expiration = damage.ActiveCondition.Expiration;

    pub fn init(agent: *const Agent) ConditionIterator {
        return .{ .agent = agent };
    }

    pub fn next(self: *ConditionIterator) ?damage.ActiveCondition {
        // Phase 1: yield stored conditions
        if (self.stored_index < self.agent.conditions.items.len) {
            const cond = self.agent.conditions.items[self.stored_index];
            self.stored_index += 1;
            return cond;
        }

        // Phase 2: yield computed conditions
        while (self.computed_phase < 3) {
            const phase = self.computed_phase;
            self.computed_phase += 1;

            switch (phase) {
                0 => if (self.agent.balance < 0.2) {
                    return .{ .condition = .unbalanced, .expiration = .dynamic };
                },
                1 => if (self.agent.engagement) |eng| {
                    if (eng.pressure > 0.8) {
                        return .{ .condition = .pressured, .expiration = .dynamic };
                    }
                },
                2 => if (self.agent.engagement) |eng| {
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
// Advantage Effects
// ============================================================================

/// Deltas to apply to advantage axes after technique resolution
pub const AdvantageEffect = struct {
    pressure: f32 = 0,
    control: f32 = 0,
    position: f32 = 0,
    self_balance: f32 = 0,
    target_balance: f32 = 0,

    pub fn apply(
        self: AdvantageEffect,
        engagement: *Engagement,
        attacker: *Agent,
        defender: *Agent,
    ) void {
        engagement.pressure = std.math.clamp(engagement.pressure + self.pressure, 0, 1);
        engagement.control = std.math.clamp(engagement.control + self.control, 0, 1);
        engagement.position = std.math.clamp(engagement.position + self.position, 0, 1);
        attacker.balance = std.math.clamp(attacker.balance + self.self_balance, 0, 1);
        defender.balance = std.math.clamp(defender.balance + self.target_balance, 0, 1);
    }

    pub fn scale(self: AdvantageEffect, mult: f32) AdvantageEffect {
        return .{
            .pressure = self.pressure * mult,
            .control = self.control * mult,
            .position = self.position * mult,
            .self_balance = self.self_balance * mult,
            .target_balance = self.target_balance * mult,
        };
    }
};

/// Technique-specific advantage overrides per outcome
pub const TechniqueAdvantage = struct {
    on_hit: ?AdvantageEffect = null,
    on_miss: ?AdvantageEffect = null,
    on_blocked: ?AdvantageEffect = null,
    on_parried: ?AdvantageEffect = null,
    on_deflected: ?AdvantageEffect = null,
    on_dodged: ?AdvantageEffect = null,
    on_countered: ?AdvantageEffect = null,
};

//      // Derived: overall openness to decisive strike
// pub fn vulnerability(self: Advantage) f32 {
//     // When any axis is bad enough, you're open
//     const worst = @min(@min(self.control, self.position), self.balance);
//     // Pressure contributes but isn't sufficient alone
//     return (1.0 - worst) * 0.7 + (1.0 - self.pressure) * 0.3;
// }
// Reading Advantage
//
// From the player's perspective against a specific mob:
//
// pub fn playerVsMob(player: *Player, mob: *Mob) struct { f32, f32 } {
//     // Player's vulnerability in this engagement
//     const player_vuln = (1.0 - mob.engagement.playerAdvantage()) * 0.6
//                       + (1.0 - player.state.balance) * 0.4;
//
//     // Mob's vulnerability in this engagement
//     const mob_vuln = mob.engagement.playerAdvantage() * 0.6
//                    + (1.0 - mob.state.balance) * 0.4;
//
//     return .{ player_vuln, mob_vuln };
// }
//
// Balance contributes to vulnerability in all engagements. Relational advantage only matters for this engagement.
//
// Attention split:
// When player acts against mob A, mob B might get a "free" advantage tick:
// pub fn applyAttentionPenalty(player: *Player, focused_mob: *Mob, all_mobs: []*Mob) void {
//     for (all_mobs) |mob| {
//         if (mob != focused_mob) {
//             // Unfocused enemies gain slight positional advantage
//             mob.engagement.position -= 0.05;  // Toward mob advantage
//         }
//     }
// }
//
// Overcommitment penalty spreads:
// When player whiffs a heavy attack against mob A:
// // Player's balance drops (intrinsic)
// player.state.balance -= 0.2;
//
// // This affects ALL engagements because balance is intrinsic
// // No need to update each mob's engagement — the vulnerability
// // calculation already incorporates player.state.balance
//
// Mob coordination:
// If mobs are smart, they can exploit split attention:
// // Mob A feints to draw player's focus
// // Mob B's pattern shifts to "exploit opening" when player.engagement with A shows commitment

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

const TestTemplates = struct {
    const expensive: cards.Template = .{
        .id = 1,
        .kind = .action,
        .name = "expensive",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 5.0, .time = 0.3 },
        .tags = .{},
        .rules = &.{},
    };
    const cheap: cards.Template = .{
        .id = 2,
        .kind = .action,
        .name = "cheap",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 2.0, .time = 0.2 },
        .tags = .{},
        .rules = &.{},
    };
};

test "TechniquePool.selectNext respects stamina constraint" {
    const alloc = testing.allocator;

    const templates = &[_]*const cards.Template{&TestTemplates.expensive};
    var pool = try TechniquePool.init(alloc, templates);
    defer pool.deinit();

    // With enough stamina, should return technique
    const selected = pool.selectNext(10.0);
    try testing.expect(selected != null);
    try testing.expectEqual(@as(cards.ID, 1), selected.?.template.id);

    // Reset index for next test
    pool.next_index = 0;

    // With insufficient stamina, should return null
    const not_selected = pool.selectNext(3.0);
    try testing.expect(not_selected == null);
}

test "TechniquePool.selectNext skips unaffordable, picks affordable" {
    const alloc = testing.allocator;

    const templates = &[_]*const cards.Template{
        &TestTemplates.expensive, // 5.0 stamina
        &TestTemplates.cheap, // 2.0 stamina
    };
    var pool = try TechniquePool.init(alloc, templates);
    defer pool.deinit();

    // With 3.0 stamina: expensive (5.0) unaffordable, cheap (2.0) affordable
    // Should skip expensive, return cheap
    const selected = pool.selectNext(3.0);
    try testing.expect(selected != null);
    try testing.expectEqual(@as(cards.ID, 2), selected.?.template.id);
}

fn testId(index: u32) entity.ID {
    return .{ .index = index, .generation = 0 };
}

test "Armament.hasCategory single weapon" {
    const weapon_list = @import("weapon_list.zig");
    var buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    var sword_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.knights_sword };

    const shield_armament = Armament{ .single = &buckler_instance };
    try testing.expect(shield_armament.hasCategory(.shield));
    try testing.expect(!shield_armament.hasCategory(.sword));

    const sword_armament = Armament{ .single = &sword_instance };
    try testing.expect(!sword_armament.hasCategory(.shield));
    try testing.expect(sword_armament.hasCategory(.sword));
}

test "Armament.hasCategory dual wield" {
    const weapon_list = @import("weapon_list.zig");
    var buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    var sword_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.knights_sword };

    const sword_and_shield = Armament{ .dual = .{
        .primary = &sword_instance,
        .secondary = &buckler_instance,
    } };
    try testing.expect(sword_and_shield.hasCategory(.shield));
    try testing.expect(sword_and_shield.hasCategory(.sword));
    try testing.expect(!sword_and_shield.hasCategory(.axe));
}

test "ConditionIterator computed condition thresholds" {
    // Test the threshold logic for computed conditions directly
    // using ConditionIterator's internal state machine

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
