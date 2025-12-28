const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const damage = @import("damage.zig");

const Template = weapon.Template;
const Offensive = weapon.Offensive;
const Defensive = weapon.Defensive;
const Category = weapon.Category;
const Grip = weapon.Grip;
const Features = weapon.Features;
const Reach = combat.Reach;

// ============================================================================
// Weapon Repository
// ============================================================================

pub const WeaponEntries = [_]*const Template{
    &horsemans_mace,
    &footmans_axe,
    &greataxe,
    &knights_sword,
    &falchion,
    &dirk,
    &spear,
    &buckler,
};

pub fn byName(comptime name: []const u8) *const Template {
    inline for (WeaponEntries) |entry| {
        if (comptime std.mem.eql(u8, entry.name, name)) {
            return entry;
        }
    }
    @compileError("unknown weapon: " ++ name);
}

const std = @import("std");

// ============================================================================
// Horseman's Mace
// ============================================================================
// Cavalry mace - one-handed, balanced for mounted use, armor-crushing.
// No thrust profile - maces are impact weapons.

const horsemans_mace_swing = Offensive{
    .name = "horseman's mace swing",
    .reach = .mace,
    .damage_types = &.{ .bludgeon, .crush },
    .accuracy = 0.9,
    .speed = 1.0,
    .damage = 1.3, // heavy impact
    .penetration = 0.2, // blunt, but can dent armor
    .penetration_max = 1.0,
    .fragility = 0.2, // sturdy metal head
    .defender_modifiers = .{
        .reach = .mace,
        .parry = 0.7, // hard to parry a heavy mace
        .deflect = 0.5, // hard to deflect
        .block = 0.9, // shields work
        .fragility = 2.5, // punishing to block
    },
};

const horsemans_mace_defence = Defensive{
    .name = "horseman's mace defence",
    .reach = .mace,
    .parry = 0.4, // poor parrying weapon
    .deflect = 0.3,
    .block = 0.2, // can't really block with it
    .fragility = 0.3, // solid metal
};

pub const horsemans_mace = Template{
    .name = "horseman's mace",
    .categories = &.{.mace},
    .features = .{
        .hooked = false,
        .spiked = false, // flanged, but not spiked
        .crossguard = false,
        .pommel = true,
    },
    .grip = .{
        .one_handed = true,
        .two_handed = false,
        .versatile = false,
        .bastard = false,
        .half_sword = false,
        .murder_stroke = false,
    },
    .length = 60.0, // cm
    .weight = 1.2, // kg
    .balance = 0.7, // head-heavy
    .swing = horsemans_mace_swing,
    .thrust = null, // no thrust
    .defence = horsemans_mace_defence,
    .ranged = null,
    .integrity = 150.0, // very sturdy
};

// ============================================================================
// Footman's Axe
// ============================================================================
// Infantry axe - versatile grip, powerful chop, can hook shields.

const footmans_axe_swing = Offensive{
    .name = "footman's axe swing",
    .reach = .sabre,
    .damage_types = &.{.slash},
    .accuracy = 0.85,
    .speed = 0.9, // slower than swords
    .damage = 1.4, // devastating chop
    .penetration = 0.8, // axe edge bites deep
    .penetration_max = 8.0,
    .fragility = 1.0, // typical
    .defender_modifiers = .{
        .reach = .sabre,
        .parry = 0.8,
        .deflect = 0.6,
        .block = 0.7, // can hook around shields
        .fragility = 2.5, // hard on shields
    },
};

const footmans_axe_defence = Defensive{
    .name = "footman's axe defence",
    .reach = .sabre,
    .parry = 0.5, // haft can parry
    .deflect = 0.4,
    .block = 0.3,
    .fragility = 1.1, // wooden haft, slightly vulnerable
};

pub const footmans_axe = Template{
    .name = "footman's axe",
    .categories = &.{.axe},
    .features = .{
        .hooked = true, // beard can hook
        .spiked = false,
        .crossguard = false,
        .pommel = false,
    },
    .grip = .{
        .one_handed = true,
        .two_handed = true,
        .versatile = true, // can grip up the haft
        .bastard = false,
        .half_sword = false,
        .murder_stroke = false,
    },
    .length = 75.0,
    .weight = 1.8,
    .balance = 0.75, // head-heavy
    .swing = footmans_axe_swing,
    .thrust = null, // no effective thrust
    .defence = footmans_axe_defence,
    .ranged = null,
    .integrity = 80.0, // wooden haft
};

// ============================================================================
// Greataxe
// ============================================================================
// Two-handed axe - maximum power, slow, devastating.

const greataxe_swing = Offensive{
    .name = "greataxe swing",
    .reach = .longsword,
    .damage_types = &.{.slash},
    .accuracy = 0.75, // unwieldy
    .speed = 0.7, // slow wind-up
    .damage = 1.8, // massive damage
    .penetration = 1.2,
    .penetration_max = 12.0,
    .fragility = 1.0, // typical
    .defender_modifiers = .{
        .reach = .longsword,
        .parry = 0.6, // hard to stop
        .deflect = 0.4,
        .block = 0.6,
        .fragility = 3.5, // shield-breaker
    },
};

const greataxe_defence = Defensive{
    .name = "greataxe defence",
    .reach = .longsword,
    .parry = 0.4, // can use haft
    .deflect = 0.3,
    .block = 0.2,
    .fragility = 1.1, // wooden haft
};

pub const greataxe = Template{
    .name = "greataxe",
    .categories = &.{.axe},
    .features = .{
        .hooked = true,
        .spiked = false,
        .crossguard = false,
        .pommel = false,
    },
    .grip = .{
        .one_handed = false,
        .two_handed = true,
        .versatile = true, // sliding grip
        .bastard = false,
        .half_sword = false,
        .murder_stroke = false,
    },
    .length = 140.0,
    .weight = 3.5,
    .balance = 0.8, // very head-heavy
    .swing = greataxe_swing,
    .thrust = null,
    .defence = greataxe_defence,
    .ranged = null,
    .integrity = 90.0,
};

// ============================================================================
// Knight's Sword
// ============================================================================
// Arming sword - one-handed, balanced, good at everything.

const knights_sword_swing = Offensive{
    .name = "knight's sword swing",
    .reach = .sabre,
    .damage_types = &.{.slash},
    .accuracy = 1.0, // well-balanced
    .speed = 1.0,
    .damage = 1.0,
    .penetration = 0.5,
    .penetration_max = 4.0,
    .fragility = 1.0, // baseline
    .defender_modifiers = .{
        .reach = .sabre,
        .parry = 1.0, // standard baseline
        .deflect = 0.8,
        .block = 0.6,
        .fragility = 1.0, // baseline
    },
};

const knights_sword_thrust = Offensive{
    .name = "knight's sword thrust",
    .reach = .sabre,
    .damage_types = &.{.pierce},
    .accuracy = 0.95,
    .speed = 1.1, // thrusts are quick
    .damage = 0.8,
    .penetration = 1.0, // point penetrates well
    .penetration_max = 6.0,
    .fragility = 1.2, // point can bend on armor
    .defender_modifiers = .{
        .reach = .sabre,
        .parry = 1.0,
        .deflect = 0.9,
        .block = 0.5, // thrusts slip past
        .fragility = 0.5, // thrusts are lighter impact
    },
};

const knights_sword_defence = Defensive{
    .name = "knight's sword defence",
    .reach = .sabre,
    .parry = 1.0, // excellent
    .deflect = 0.9,
    .block = 0.4, // blade too narrow
    .fragility = 1.0, // baseline
};

pub const knights_sword = Template{
    .name = "knight's sword",
    .categories = &.{.sword},
    .features = .{
        .hooked = false,
        .spiked = false,
        .crossguard = true,
        .pommel = true,
    },
    .grip = .{
        .one_handed = true,
        .two_handed = false,
        .versatile = false,
        .bastard = false,
        .half_sword = false,
        .murder_stroke = false,
    },
    .length = 90.0,
    .weight = 1.1,
    .balance = 0.3, // well-balanced
    .swing = knights_sword_swing,
    .thrust = knights_sword_thrust,
    .defence = knights_sword_defence,
    .ranged = null,
    .integrity = 100.0,
};

// ============================================================================
// Falchion
// ============================================================================
// Single-edged sword - slash-focused, cleaver-like, less refined.

const falchion_swing = Offensive{
    .name = "falchion swing",
    .reach = .sabre,
    .damage_types = &.{.slash},
    .accuracy = 0.9,
    .speed = 0.95,
    .damage = 1.2, // heavy cleaving blade
    .penetration = 0.6,
    .penetration_max = 5.0,
    .fragility = 0.8, // thick blade, sturdy
    .defender_modifiers = .{
        .reach = .sabre,
        .parry = 0.9,
        .deflect = 0.7,
        .block = 0.7,
        .fragility = 1.5, // heavy cleave
    },
};

const falchion_thrust = Offensive{
    .name = "falchion thrust",
    .reach = .sabre,
    .damage_types = &.{.pierce},
    .accuracy = 0.7, // not designed for thrusting
    .speed = 0.9,
    .damage = 0.5, // weak point
    .penetration = 0.4,
    .penetration_max = 3.0,
    .fragility = 1.0, // typical
    .defender_modifiers = .{
        .reach = .sabre,
        .parry = 1.0,
        .deflect = 1.0,
        .block = 0.8,
        .fragility = 0.5, // light thrust
    },
};

const falchion_defence = Defensive{
    .name = "falchion defence",
    .reach = .sabre,
    .parry = 0.8, // single edge limits options
    .deflect = 0.7,
    .block = 0.5, // wider blade helps
    .fragility = 0.8, // thick blade
};

pub const falchion = Template{
    .name = "falchion",
    .categories = &.{.sword},
    .features = .{
        .hooked = false,
        .spiked = false,
        .crossguard = true,
        .pommel = true,
    },
    .grip = .{
        .one_handed = true,
        .two_handed = false,
        .versatile = false,
        .bastard = false,
        .half_sword = false,
        .murder_stroke = false,
    },
    .length = 80.0,
    .weight = 1.3,
    .balance = 0.5, // slightly blade-heavy
    .swing = falchion_swing,
    .thrust = falchion_thrust,
    .defence = falchion_defence,
    .ranged = null,
    .integrity = 110.0,
};

// ============================================================================
// Dirk
// ============================================================================
// Long dagger - fast, thrust-focused, close range.

const dirk_swing = Offensive{
    .name = "dirk slash",
    .reach = .dagger,
    .damage_types = &.{.slash},
    .accuracy = 0.95,
    .speed = 1.3, // very fast
    .damage = 0.5, // short blade
    .penetration = 0.3,
    .penetration_max = 2.0,
    .fragility = 1.0, // typical
    .defender_modifiers = .{
        .reach = .dagger,
        .parry = 1.2, // easy to parry short blade
        .deflect = 1.1,
        .block = 1.0,
        .fragility = 0.3, // very light impact
    },
};

const dirk_thrust = Offensive{
    .name = "dirk thrust",
    .reach = .dagger,
    .damage_types = &.{.pierce},
    .accuracy = 1.0, // precise
    .speed = 1.4, // lightning fast
    .damage = 0.7,
    .penetration = 1.2, // needle point
    .penetration_max = 8.0, // can reach vitals
    .fragility = 1.0, // typical
    .defender_modifiers = .{
        .reach = .dagger,
        .parry = 1.1,
        .deflect = 1.0,
        .block = 0.8, // hard to block quick thrust
        .fragility = 0.3, // light impact
    },
};

const dirk_defence = Defensive{
    .name = "dirk defence",
    .reach = .dagger,
    .parry = 0.6, // short blade, but quick
    .deflect = 0.5,
    .block = 0.1, // too small
    .fragility = 1.0, // typical steel
};

pub const dirk = Template{
    .name = "dirk",
    .categories = &.{.dagger},
    .features = .{
        .hooked = false,
        .spiked = false,
        .crossguard = true, // small guard
        .pommel = true,
    },
    .grip = .{
        .one_handed = true,
        .two_handed = false,
        .versatile = false,
        .bastard = false,
        .half_sword = false,
        .murder_stroke = false,
    },
    .length = 35.0,
    .weight = 0.4,
    .balance = 0.25, // handle-weighted for quick work
    .swing = dirk_swing,
    .thrust = dirk_thrust,
    .defence = dirk_defence,
    .ranged = null,
    .integrity = 60.0,
};

// ============================================================================
// Spear
// ============================================================================
// Infantry spear - reach advantage, thrust-only, versatile grip.

const spear_thrust = Offensive{
    .name = "spear thrust",
    .reach = .spear,
    .damage_types = &.{.pierce},
    .accuracy = 0.9,
    .speed = 1.0,
    .damage = 1.0,
    .penetration = 1.5, // spearhead penetrates well
    .penetration_max = 10.0,
    .fragility = 1.0, // typical (shaft is resilient)
    .defender_modifiers = .{
        .reach = .spear,
        .parry = 0.9, // can parry at distance
        .deflect = 0.7,
        .block = 0.6,
        .fragility = 0.8, // thrust, not heavy impact
    },
};

const spear_defence = Defensive{
    .name = "spear defence",
    .reach = .spear,
    .parry = 0.7, // can use shaft
    .deflect = 0.5,
    .block = 0.3, // no blocking surface
    .fragility = 1.1, // wooden shaft, slightly vulnerable
};

pub const spear = Template{
    .name = "spear",
    .categories = &.{.polearm},
    .features = .{
        .hooked = false,
        .spiked = false,
        .crossguard = false,
        .pommel = false,
    },
    .grip = .{
        .one_handed = false,
        .two_handed = true,
        .versatile = true, // sliding grip for range control
        .bastard = false,
        .half_sword = false,
        .murder_stroke = false,
    },
    .length = 200.0,
    .weight = 2.0,
    .balance = 0.6, // slightly forward
    .swing = null, // no effective swing
    .thrust = spear_thrust,
    .defence = spear_defence,
    .ranged = null,
    .integrity = 70.0, // wooden shaft
};

// ============================================================================
// Buckler
// ============================================================================
// Small shield - primarily defensive, can punch with boss.

const buckler_punch = Offensive{
    .name = "buckler punch",
    .reach = .clinch,
    .damage_types = &.{.bludgeon},
    .accuracy = 0.85,
    .speed = 1.2, // quick jab
    .damage = 0.4, // stun more than damage
    .penetration = 0.0,
    .penetration_max = 0.0,
    .fragility = 0.2, // metal boss, very sturdy
    .defender_modifiers = .{
        .reach = .clinch,
        .parry = 1.0,
        .deflect = 0.9,
        .block = 0.8,
        .fragility = 0.5, // light punch
    },
};

const buckler_defence = Defensive{
    .name = "buckler defence",
    .reach = .dagger, // active parrying range
    .parry = 0.9, // punch-parry style
    .deflect = 1.2, // excellent deflection
    .block = 1.0, // can block but small
    .fragility = 0.3, // metal boss, very sturdy
};

pub const buckler = Template{
    .name = "buckler",
    .categories = &.{.shield},
    .features = .{
        .hooked = false,
        .spiked = false, // could add boss spike
        .crossguard = false,
        .pommel = false,
    },
    .grip = .{
        .one_handed = true,
        .two_handed = false,
        .versatile = false,
        .bastard = false,
        .half_sword = false,
        .murder_stroke = false,
    },
    .length = 35.0, // diameter
    .weight = 1.5,
    .balance = 0.5, // centered
    .swing = buckler_punch,
    .thrust = null,
    .defence = buckler_defence,
    .ranged = null,
    .integrity = 120.0, // metal boss, wooden body
};

// ============================================================================
// Tests
// ============================================================================

test "all weapons have valid offensive profiles" {
    for (WeaponEntries) |w| {
        // At least one attack method
        try std.testing.expect(w.swing != null or w.thrust != null);

        if (w.swing) |swing| {
            try std.testing.expect(swing.accuracy > 0 and swing.accuracy <= 1.5);
            try std.testing.expect(swing.speed > 0);
            try std.testing.expect(swing.damage > 0);
        }

        if (w.thrust) |thrust| {
            try std.testing.expect(thrust.accuracy > 0 and thrust.accuracy <= 1.5);
            try std.testing.expect(thrust.speed > 0);
            try std.testing.expect(thrust.damage > 0);
        }
    }
}

test "all weapons have valid defensive profiles" {
    for (WeaponEntries) |w| {
        try std.testing.expect(w.defence.parry >= 0 and w.defence.parry <= 1.5);
        try std.testing.expect(w.defence.deflect >= 0 and w.defence.deflect <= 1.5);
        try std.testing.expect(w.defence.block >= 0 and w.defence.block <= 1.5);
    }
}

test "byName returns correct weapons" {
    const sword = byName("knight's sword");
    try std.testing.expectEqualStrings("knight's sword", sword.name);

    const mace = byName("horseman's mace");
    try std.testing.expectEqualStrings("horseman's mace", mace.name);
}

test "weapon categories are correct" {
    try std.testing.expectEqual(Category.mace, horsemans_mace.categories[0]);
    try std.testing.expectEqual(Category.axe, footmans_axe.categories[0]);
    try std.testing.expectEqual(Category.axe, greataxe.categories[0]);
    try std.testing.expectEqual(Category.sword, knights_sword.categories[0]);
    try std.testing.expectEqual(Category.sword, falchion.categories[0]);
    try std.testing.expectEqual(Category.dagger, dirk.categories[0]);
    try std.testing.expectEqual(Category.polearm, spear.categories[0]);
    try std.testing.expectEqual(Category.shield, buckler.categories[0]);
}

test "grip constraints are sensible" {
    // Two-handed weapons shouldn't be one-handed
    try std.testing.expect(!greataxe.grip.one_handed);
    try std.testing.expect(greataxe.grip.two_handed);

    // Spear is two-handed with versatile grip
    try std.testing.expect(!spear.grip.one_handed);
    try std.testing.expect(spear.grip.two_handed);
    try std.testing.expect(spear.grip.versatile);

    // Buckler and dirk are one-handed only
    try std.testing.expect(buckler.grip.one_handed);
    try std.testing.expect(!buckler.grip.two_handed);
    try std.testing.expect(dirk.grip.one_handed);
    try std.testing.expect(!dirk.grip.two_handed);
}
