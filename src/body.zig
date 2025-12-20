const std = @import("std");

pub const PartIndex = u16; // Up to 65k body parts is enough
pub const NO_PARENT = std.math.maxInt(PartIndex);

pub const BodyPartTag = enum {
    // Human exterior bits
    Head,
    Eye,
    Nose,
    Ear,
    Neck,
    Torso,
    Abdomen,
    Shoulder,
    Groin,
    Arm,
    Elbow,
    Forearm,
    Wrist,
    Hand,
    Finger,
    Thumb,
    Thigh,
    Knee,
    Shin,
    Ankle,
    Foot,
    Toe,
    // Human organs
    Brain,
    Heart,
    Lung,
    Stomach,
    Liver,
    Intestine,
    Oesophagus,
    Tongue,
    Tooth,
    // Human bones
    Skull,
    Jaw,
    Vertebrate,
    Ribcage,
    Pelvis,
    Femur,
    Tibia,
};

pub const Side = enum(u8) { Left, Right, Center, None };

pub const BodyPart = struct {
    name_hash: u32, // e.g. hash("left_index_finger") for lookups
    tag: BodyPartTag,
    parent: PartIndex, // Index of the body part this is attached to

    // Physical Stats
    surface_area: f32, // cm^2 - determines if armor fits
    thickness: f32, // How deep (cm) a cut needs to be to sever
    // is_vital bool, // If destroyed, creature dies?
};

pub const PartDef = struct {
    // 1. TOPOLOGY
    // Index in the blueprint array. 'null' means this is the Root (Torso).
    // We use ?u16 because u16 allows 65,535 parts (plenty).
    parent_idx: ?u16,

    // 2. SEMANTICS
    tag: BodyPartTag, // The generic type (.Finger, .Arm, .Eye)
    side: Side, // .Left, .Right, .Center, .None
    name: []const u8, // "Left Index Finger" (Useful for combat logs)

    // 3. PHYSICAL CONSTANTS (The Simulation Data)
    // Hit Probability: When "The Body" is hit, how likely is it to be THIS part?
    // e.g. Torso = 0.4, Eye = 0.005
    hit_weight: f32,

    // Structural Integrity: How hard is it to sever/break relative to total size?
    // Bone = high, Nose = low.
    solidity: f32,

    // 4. FLAGS (Bitfield)
    flags: packed struct {
        is_vital: bool = false, // Brain/Heart: Destroy = Instant Death
        is_internal: bool = false, // Must penetrate parent layer to hit this
        can_grasp: bool = false, // Hand/Tentacle
        is_stance: bool = false, // Leg/Foot: Break = Fall over
        is_breathing: bool = false, // Mouth/Nose/Trachea
    } = .{},
};

pub const Body = struct {
    parts: std.ArrayList(BodyPart),

    // Helper to find things
    pub fn get_children(self: Body, parent: PartIndex) std.Iterator {
        _ = .{ self, parent };
        // TODO: implement
    }
};

pub const Layer = enum(u8) {
    Skin = 0, // Tattoos, Piercings
    Underwear = 1, // Loincloth, singlet, socks
    CloseFit = 2, // Shirt, Rings (if under glove)
    Gambeson = 3, // Padding
    Mail = 4, // Chainmail
    Plate = 5, // Rigid Armor
    Outer = 6, // Tabard, Surcote, Overcoat
    Cloak = 7, // Weather protection
    Strapped = 8, // Backpacks, sheathed weapons
};

pub const Coverage = struct {
    // Which parts does this cover?
    // Using a bitmask or list of tags.
    // A Glove covers: [Hand, Finger1..5, Thumb]
    target_tags: []const BodyPartTag,

    // Which layers does it consume?
    layer: Layer,

    // Does it ALLOW things on top of it?
    // e.g., Plate allows Tabard, but not another Plate.
    allows_layers_above: bool,

    // "Rigidity" - Can you wear a ring under it?
    // If rigid (Gauntlet), Layer 2 (Ring) is allowed.
    // If tight (Latex Glove), Layer 2 is blocked.
    is_rigid: bool,

    // some items can coexist with one other of the same layer
    // you could wear two shirts, for example
    // is_nonexclusive: bool,
};

pub const ItemDef = struct {
    name: []const u8,
    // An item can have MULTIPLE wear configurations
    // Config 0: Goggles on Eyes. Config 1: Goggles on Neck.
    configurations: []const []const Coverage,
};

// const Dimensions = struct {
//     length: f32,
//     circumference: f32,
// };
//
// fn can_fit(body_part: Dimensions, item: Dimensions, item_type: ItemType) bool {
//     const tolerance = switch (item_type) {
//         .Cloak => 100.0, // Fits anyone
//         .PlateArmor => 2.0, // Needs exact fit
//         .Mail => 15.0, // Flexible
//         .Ring => 0.5,
//     };
//
//     return std.math.absFloat(body_part.circumference - item.circumference) < tolerance;
// }

pub const TissueLayer = enum { Bone, Artery, Muscle, Fat, Nerve, Skin };

pub const Wound = struct {
    tissue: TissueLayer,
    severity: f32, // 0.0 to 1.0 (Severed / Crushed)
    type: enum { Blunt, Cut, Pierce, Burn, Acid },
    // is_infected: bool,
};

// game state (not the static def):
pub const BodyState = struct {
    // Parallel array to the Body.parts list
    part_states: std.ArrayList(PartState),
};

pub const PartState = struct {
    wounds: std.ArrayList(Wound),
    is_severed: bool, // If true, all children are implicitly disconnected

    // Calculated flags for quick logic checks
    integrity: f32, // 1.0 = fine, 0.0 = useless
    function: f32, // 1.0 = fine, 0.0 = useless

    fn can_grasp(self: *PartState) bool {
        self.function > 0.6;
    }

    fn can_support_weight(self: *PartState) bool {
        self.function > 0.3;
    }

    fn can_walk(self: *PartState) bool {
        self.function > 0.4;
    }

    fn can_run(self: *PartState) bool {
        self.function > 0.8;
    }

    fn can_write(self: *PartState) bool {
        self.function > 0.8;
    }
};

// An array of nodes defining the topology
pub const HumanoidPlan = [_]PartDef{
    .{ .tag = .Torso, .parent = null },
    .{ .tag = .Head, .parent = 0 },
    .{ .tag = .LeftArmUpper, .parent = 0 },
    // ...
};
