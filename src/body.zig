const std = @import("std");
const DamageKind = @import("damage.zig").Kind;

pub const PartIndex = u16; // Up to 65k body parts is enough
pub const NO_PARENT = std.math.maxInt(PartIndex);

pub const Tag = enum {
    // Human exterior bits
    head,
    eye,
    nose,
    ear,
    neck,
    torso,
    abdomen,
    shoulder,
    groin,
    arm,
    elbow,
    forearm,
    wrist,
    hand,
    finger,
    thumb,
    thigh,
    knee,
    shin,
    ankle,
    foot,
    toe,
    // human organs
    brain,
    heart,
    lung,
    stomach,
    liver,
    intestine,
    tongue,
    trachea,
    spleen,
    // // Human bones
    // Skull,
    // Tooth,
    // Jaw,
    // Vertebrate,
    // Ribcage,
    // Pelvis,
    // Femur,
    // Tibia,
    //
    // Other creature bits ...
};

pub const Side = enum(u8) { left, right, center, none };

pub const TissueLayer = enum { bone, artery, muscle, fat, nerve, skin };

pub const Part = struct {
    name_hash: u32, // e.g. hash("left_index_finger") for lookups
    def_id: u16,
    tag: Tag,
    parent: ?PartIndex, // Index of the body part this is attached to

    integrity: f32, // destroyed at 0.0
    wounds: std.ArrayList(Wound),
    is_severed: bool, // If true, all children are implicitly disconnected

    // FIXME: performantly look up PartDef flags before checking condition
    // must we also check parent isn't severed?
    fn can_grasp(self: *Part) bool {
        self.integrity > 0.6;
    }

    fn can_support_weight(self: *Part) bool {
        self.integrity > 0.3;
    }

    fn can_walk(self: *Part) bool {
        self.integrity > 0.4;
    }

    fn can_run(self: *Part) bool {
        self.integrity > 0.8;
    }

    fn can_write(self: *Part) bool {
        self.integrity > 0.8;
    }

    // durability: f32, // an abstraction of density, circumference & hardness. Influenced by species + individual traits.
    // armour: precompute protective layers
};

pub const PartId = struct {
    hash: u64,
    pub fn init(comptime name: []const u8) PartId {
        return .{ .hash = std.hash.Wyhash.hash(0, name) };
    }
};

pub const PartDef = struct {
    id: PartId,
    parent: ?PartId,
    tag: Tag,
    side: Side,
    name: []const u8,
    base_hit_chance: f32,
    base_durability: f32,
    trauma_mult: f32,
    flags: packed struct {
        is_vital: bool = false,
        is_internal: bool = false,
        can_grasp: bool = false,
        can_stand: bool = false,
        can_see: bool = false,
        can_hear: bool = false,
    } = .{},
};

pub const Body = struct {
    parts: std.ArrayList(Part),

    // Helper to find things
    pub fn get_children(self: Body, parent: PartIndex) std.Iterator {
        _ = .{ self, parent };
        // TODO: implement
    }
};

pub const Wound = struct {
    tissue: TissueLayer,
    severity: f32, // 0.0 to 1.0 (Severed / Crushed)
    type: DamageKind,
    // dressing
    // infection
};

// An array of nodes defining the topology
fn definePart(
    comptime name: []const u8,
    tag: Tag,
    side: Side,
    comptime parent_name: ?[]const u8,
) PartDef {
    return .{
        .id = PartId.init(name),
        .parent = if (parent_name) |p| PartId.init(p) else null,
        .tag = tag,
        .side = side,
        .name = name,
        .base_hit_chance = 1.0,
        .base_durability = 1.0,
        .trauma_mult = 1.0,
    };
}

pub const HumanoidPlan = [_]PartDef{
    // Core
    definePart("torso", .torso, .center, null),
    definePart("neck", .neck, .center, "torso"),
    definePart("head", .head, .center, "neck"),
    definePart("abdomen", .abdomen, .center, "torso"),
    definePart("groin", .groin, .center, "abdomen"),

    // Head details
    definePart("left_eye", .eye, .left, "head"),
    definePart("right_eye", .eye, .right, "head"),
    definePart("nose", .nose, .center, "head"),
    definePart("left_ear", .ear, .left, "head"),
    definePart("right_ear", .ear, .right, "head"),

    // Left arm chain
    definePart("left_shoulder", .shoulder, .left, "torso"),
    definePart("left_arm", .arm, .left, "left_shoulder"),
    definePart("left_elbow", .elbow, .left, "left_arm"),
    definePart("left_forearm", .forearm, .left, "left_elbow"),
    definePart("left_wrist", .wrist, .left, "left_forearm"),
    definePart("left_hand", .hand, .left, "left_wrist"),
    definePart("left_thumb", .thumb, .left, "left_hand"),
    definePart("left_index_finger", .finger, .left, "left_hand"),
    definePart("left_middle_finger", .finger, .left, "left_hand"),
    definePart("left_ring_finger", .finger, .left, "left_hand"),
    definePart("left_pinky_finger", .finger, .left, "left_hand"),

    // Right arm chain
    definePart("right_shoulder", .shoulder, .right, "torso"),
    definePart("right_arm", .arm, .right, "right_shoulder"),
    definePart("right_elbow", .elbow, .right, "right_arm"),
    definePart("right_forearm", .forearm, .right, "right_elbow"),
    definePart("right_wrist", .wrist, .right, "right_forearm"),
    definePart("right_hand", .hand, .right, "right_wrist"),
    definePart("right_thumb", .thumb, .right, "right_hand"),
    definePart("right_index_finger", .finger, .right, "right_hand"),
    definePart("right_middle_finger", .finger, .right, "right_hand"),
    definePart("right_ring_finger", .finger, .right, "right_hand"),
    definePart("right_pinky_finger", .finger, .right, "right_hand"),

    // Left leg chain
    definePart("left_thigh", .thigh, .left, "groin"),
    definePart("left_knee", .knee, .left, "left_thigh"),
    definePart("left_shin", .shin, .left, "left_knee"),
    definePart("left_ankle", .ankle, .left, "left_shin"),
    definePart("left_foot", .foot, .left, "left_ankle"),
    definePart("left_big_toe", .toe, .left, "left_foot"),
    definePart("left_second_toe", .toe, .left, "left_foot"),
    definePart("left_third_toe", .toe, .left, "left_foot"),
    definePart("left_fourth_toe", .toe, .left, "left_foot"),
    definePart("left_pinky_toe", .toe, .left, "left_foot"),

    // Right leg chain
    definePart("right_thigh", .thigh, .right, "groin"),
    definePart("right_knee", .knee, .right, "right_thigh"),
    definePart("right_shin", .shin, .right, "right_knee"),
    definePart("right_ankle", .ankle, .right, "right_shin"),
    definePart("right_foot", .foot, .right, "right_ankle"),
    definePart("right_big_toe", .toe, .right, "right_foot"),
    definePart("right_second_toe", .toe, .right, "right_foot"),
    definePart("right_third_toe", .toe, .right, "right_foot"),
    definePart("right_fourth_toe", .toe, .right, "right_foot"),
    definePart("right_pinky_toe", .toe, .right, "right_foot"),
};
