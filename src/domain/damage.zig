/// Damage model, conditions, and packet creation helpers.
///
/// Defines damage types, resistances, conditions, and serialization helpers
/// used by resolution. Does not apply damage to agents directly.
const std = @import("std");
const lib = @import("infra");
const PartTag = @import("body.zig").PartTag;
const Scaling = @import("stats.zig").Scaling;
const armour = @import("armour.zig");

pub const Immunity = union(enum) {
    condition: Condition,
    damage: Kind,
    // dot_effect
    // magic / etc
};

pub const Resistance = struct {
    damage: Kind,

    threshold: f32, // no damage below this number
    ratio: f32, // multiplier for remainder
};

pub const Vulnerability = struct {
    damage: Kind,
    ratio: f32,
    // maybe: threshold -> trigger (DoT / Effect / Special ..)
};

pub const Susceptibility = struct {
    condition: Condition,
    // trigger: null, // TODO:
};

// pub const TemporaryCondition = struct {
//     condition: Condition,
//     time_remaining: f32,
//     // todo: conditions like recovering stamina / advantage, etc
//     // random chance per tick
//     // on_remove: null,  // TODO: function - check for sepsis, apply lesser condition, etc
// };

pub const ActiveCondition = struct {
    condition: Condition,
    expiration: union(enum) {
        dynamic, // derived state
        permanent, // until dispelled / removed
        ticks: f32, // countdown
        end_of_action,
        end_of_tick,
        end_of_combat,
    },
};

pub const Condition = enum {
    blinded,
    deafened,
    silenced,
    stunned,
    paralysed,
    confused,
    prone,
    winded,
    shaken,
    fearful,
    nauseous,
    surprised,
    unconscious,
    comatose,
    asphyxiating, // Open question: not DoT because the intensity is creature specific, not part of the effect
    starving,
    dehydrating,
    exhausted,

    // dwarven BAC
    sober,
    tipsy,
    buzzed,
    slurring,
    pissed,
    hammered,
    pickled,
    munted,

    // computed: advantage
    pressured,
    weapon_bound,
    unbalanced,
    stationary, // no footwork in timeline this tick

    // computed: multi-opponent positioning
    flanked, // 1+ enemy with angle advantage
    surrounded, // 3+ enemies or 2+ with angle advantage

    // computed: blood loss (ratio of current/max)
    lightheaded, // < 80% blood - minor impairment
    bleeding_out, // < 60% blood - serious impairment
    hypovolemic_shock, // < 40% blood - critical, near unconscious
};

// ============================================================================
// Combat Penalties (data-driven condition modifiers)
// ============================================================================

/// Aggregate combat penalties from conditions, wounds, etc.
/// Additive fields sum; multiplicative fields compound.
pub const CombatPenalties = struct {
    // Offensive
    hit_chance: f32 = 0, // additive: -0.15 = 15% less likely to hit
    damage_mult: f32 = 1.0, // multiplicative: 0.8 = 80% damage

    // Defensive
    defense_mult: f32 = 1.0, // active defense (block/parry) effectiveness
    dodge_mod: f32 = 0, // passive evasion modifier

    // Mobility
    footwork_mult: f32 = 1.0, // manoeuvre score multiplier

    /// Combine two penalty sets (additive stack, multiplicative compound)
    pub fn combine(self: CombatPenalties, other: CombatPenalties) CombatPenalties {
        return .{
            .hit_chance = self.hit_chance + other.hit_chance,
            .damage_mult = self.damage_mult * other.damage_mult,
            .defense_mult = self.defense_mult * other.defense_mult,
            .dodge_mod = self.dodge_mod + other.dodge_mod,
            .footwork_mult = self.footwork_mult * other.footwork_mult,
        };
    }

    pub const none = CombatPenalties{};
};

/// Condition penalty table, indexed by @intFromEnum(Condition).
/// Conditions with context-dependent effects (blinded, winded) are handled separately.
pub const condition_penalties = init: {
    const count = @typeInfo(Condition).@"enum".fields.len;
    var table: [count]CombatPenalties = undefined;
    for (&table) |*p| p.* = .{}; // default: no penalty

    // Physical impairment
    table[@intFromEnum(Condition.stunned)] = .{
        .hit_chance = -0.20,
        .damage_mult = 0.7,
        .defense_mult = 0.3,
        .dodge_mod = -0.30,
    };
    table[@intFromEnum(Condition.prone)] = .{
        .hit_chance = -0.15,
        .damage_mult = 0.8,
        .dodge_mod = -0.25,
    };
    table[@intFromEnum(Condition.unbalanced)] = .{
        .hit_chance = -0.10,
        .dodge_mod = -0.15,
    };

    // Mental
    table[@intFromEnum(Condition.confused)] = .{ .hit_chance = -0.15 };
    table[@intFromEnum(Condition.shaken)] = .{ .hit_chance = -0.10, .damage_mult = 0.9 };
    table[@intFromEnum(Condition.fearful)] = .{ .hit_chance = -0.10, .damage_mult = 0.9 };

    // Incapacitation
    table[@intFromEnum(Condition.paralysed)] = .{
        .defense_mult = 0.0,
        .dodge_mod = -0.40,
    };
    table[@intFromEnum(Condition.surprised)] = .{
        .defense_mult = 0.5,
        .dodge_mod = -0.20,
    };
    table[@intFromEnum(Condition.unconscious)] = .{
        .defense_mult = 0.0,
        .dodge_mod = -0.50,
    };
    table[@intFromEnum(Condition.comatose)] = .{
        .defense_mult = 0.0,
        .dodge_mod = -0.50,
    };

    // Engagement pressure
    table[@intFromEnum(Condition.pressured)] = .{ .defense_mult = 0.85 };
    table[@intFromEnum(Condition.weapon_bound)] = .{ .defense_mult = 0.7 };

    // Blood loss
    table[@intFromEnum(Condition.lightheaded)] = .{
        .hit_chance = -0.05,
        .damage_mult = 0.9,
    };
    table[@intFromEnum(Condition.bleeding_out)] = .{
        .hit_chance = -0.15,
        .damage_mult = 0.8,
        .defense_mult = 0.9,
    };
    table[@intFromEnum(Condition.hypovolemic_shock)] = .{
        .hit_chance = -0.30,
        .damage_mult = 0.6,
        .defense_mult = 0.75,
        .dodge_mod = -0.20,
        .footwork_mult = 0.5,
    };

    // Sensory impairment
    // Note: .blinded has special-case handling in forAttacker() based on attack mode
    table[@intFromEnum(Condition.deafened)] = .{
        .defense_mult = 0.9, // can't hear opponent's footwork
    };

    break :init table;
};

/// Look up penalties for a condition. Returns .none for conditions
/// that require context (blinded, winded) or combat state (stationary, flanked).
pub fn penaltiesFor(condition: Condition) CombatPenalties {
    return condition_penalties[@intFromEnum(condition)];
}

pub const DoTEffect = union(enum) {
    bleeding: f32,
    burning: f32,
    freezing: f32,
    corroding: f32,
    diseased: f32, // probably needs modelling
    poisoned: f32, // probably needs modelling
};

pub const Kind = enum {
    // physical
    bludgeon,
    pierce,
    slash,
    crush,
    shatter,

    // elemental
    fire,
    frost,
    lightning,
    corrosion,

    // energy
    beam,
    plasma,
    radiation,

    // biological
    asphyxiation,
    starvation,
    dehydration,
    infection,
    necrosis,

    // magical
    arcane,
    divine,
    death,
    disintegration,
    transmutation,
    channeling,
    binding,

    fn isPhysical(self: *Kind) bool {
        return self.kind() == .physical;
    }

    fn isMagical(self: *Kind) bool {
        return self.kind() == .magical;
    }

    fn isElemental(self: *Kind) bool {
        return self.kind() == .elemental;
    }

    fn isBiological(self: *Kind) bool {
        return self.kind() == .biological;
    }

    fn kind(self: *Kind) Category {
        return switch (self) {
            .bludgeon....shatter => .physical,
            .fire....corrosion => .elemental,
            .asphyxiation....necrosis => .biological,
            .arcane....binding => .magical,
        };
    }
};

pub const Instance = struct {
    amount: f32,
    types: []const Kind,
};

pub const Base = struct {
    instances: []const Instance,
    scaling: Scaling,
};

pub const Category = enum {
    physical,
    elemental,
    energy,
    biogogical,
    magical,
};

//  A cumulative model with material interactions:

pub const Packet = struct {
    amount: f32,
    kind: Kind,
    penetration: f32, // cm of material it can punch through

    // After passing through a layer
    pub fn afterLayer(self: Packet, layer: *const armour.LayerProtection) Packet {
        // Totality check - did it find a gap?
        // Material resistance/vulnerability
        // Reduce amount and penetration
        // Reduce layer integrity
        _ = .{ self, layer };
    }
};

// pub fn resolveHit(
//     packet: damage.Packet,
//     stack: *armour.Stack,
//     body: *Body,
//     target_part: PartIndex,
// ) void {
//     var remaining = packet;
//
//     // Outer layers first
//     for (stack.getProtection(target_part)) |layer| {
//         remaining = remaining.afterLayer(layer);
//         if (remaining.amount <= 0) return; // absorbed
//     }
//
//     // Damage reaches body
//     applyWound(body, target_part, remaining);
//
//     // Deep penetration? Check enclosed parts
//     if (remaining.penetration > body.parts.items[target_part].depth_threshold) {
//         for (getEnclosedParts(body, target_part)) |internal| {
//             // Chance to hit organ based on penetration depth
//         }
//     }
// }

test "Kind" {}
