const combat = @import("combat.zig");
const damage = @import("damage.zig");
const entity = @import("entity.zig");

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

pub const Ranged = union {
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
    damage_types: []damage.Kind,
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
    vs: Defensive,

    // against impact damage
    fragility: f32,
};

pub const Defensive = struct {
    name: []const u8,
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
    one_handed: bool,
    two_handed: bool,

    // extended
    versatile: bool, // polearms
    bastard: bool, // claymore, hand-and-a-half
    half_sword: bool,
    murder_stroke: bool,
};

// packed struct or a []tag/enum ?
pub const Features = packed struct {
    hooked: bool,
    spiked: bool,
    crossguard: bool,
    pommel: bool,
};

pub const Template = struct {
    name: []const u8,

    categories: []Category,
    features: Features,
    grip: Grip,

    length: f32, // in cm
    weight: f32, // multiplies stamina cost AND damage; with handedness & power
    balance: f32, // 0.0 - 1.0 - handle to tip

    swing: ?Offensive,
    thrust: ?Offensive,
    defence: Defensive,
    ranged: ?Ranged,

    integrity: f32, // total damage until broken
};

pub const Instance = struct {
    id: entity.ID,
    template: *const Template,

    // custom stuff here ..
};
