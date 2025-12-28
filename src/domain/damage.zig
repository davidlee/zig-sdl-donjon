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
};

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
