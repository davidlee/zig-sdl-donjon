/// Weapon templates and instances shared across combat systems.
///
/// Defines categories, offensive profiles, ammunition, and instance structs.
/// Does not perform rendering or inventory logic.
const lib = @import("infra");
const combat = @import("combat.zig");
const damage = @import("damage.zig");
const entity = lib.entity;

pub const ProjectileType = enum {
    arrow,
    bolt,
    dart,
    bullet,
    stone,
};

pub const Category = enum {
    dagger,
    sword,
    club,
    axe,
    mace,
    polearm,
    bow,
    crossbow,
    throwing,
    shield,
    improvised,
    unarmed, // natural weapons: fists, bite, claws, etc.
};

pub const Ammunition = struct {
    name: []const u8,
    kind: ProjectileType,
    modifiers: Offensive,
};

pub const Thrown = struct {
    throw: Offensive,
    range: combat.Reach,
};

pub const Ranged = union(enum) {
    projectile: Projectile,
    thrown: Thrown,
};

pub const Projectile = struct {
    // kind: RangedWeaponType,
    ammunition: ProjectileType,

    range: combat.Reach,

    //multipliers
    accuracy: f32,
    speed: f32, // ignored for ammunition

    reload: f32, // sec
};

pub const Offensive = struct {
    name: []const u8,
    reach: combat.Reach,
    damage_types: []const damage.Kind,
    // TODO hit location weights
    // TODO consider balance, pressure, control, position

    // modifiers
    accuracy: f32,
    speed: f32,
    damage: f32,
    penetration: f32,

    // cm
    penetration_max: f32, // cm

    // modifiers against opponent
    defender_modifiers: Defensive,

    // against impact damage
    fragility: f32,
};

pub const Defensive = struct {
    name: []const u8 = "", // unused when embedded in Offensive
    reach: combat.Reach,
    // TODO vs specific damage types
    // TODO defender hit location weights

    parry: f32,
    deflect: f32,
    block: f32,

    fragility: f32,
};

pub const Grip = packed struct {
    // primary
    one_handed: bool = false,
    two_handed: bool = false,

    // extended
    versatile: bool = false, // polearms
    bastard: bool = false, // claymore, hand-and-a-half
    half_sword: bool = false,
    murder_stroke: bool = false,
};

// packed struct or a []tag/enum ?
pub const Features = packed struct {
    hooked: bool = false,
    spiked: bool = false,
    crossguard: bool = false,
    pommel: bool = false,
};

pub const Template = struct {
    name: []const u8,

    categories: []const Category,
    features: Features = .{},
    grip: Grip = .{},

    length: f32, // in cm
    weight: f32, // multiplies stamina cost AND damage; with handedness & power
    balance: f32, // 0.0 - 1.0 - handle to tip

    swing: ?Offensive,
    thrust: ?Offensive,
    defence: Defensive,
    ranged: ?Ranged = null,

    integrity: f32 = 100.0, // total damage until broken
};

pub const Instance = struct {
    id: entity.ID,
    template: *const Template,

    // custom stuff here ..
};
