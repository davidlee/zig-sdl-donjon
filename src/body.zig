const std = @import("std");
const DamageKind = @import("damage.zig").Kind;

pub const PartIndex = u16; // Up to 65k body parts is enough
pub const NO_PARENT = std.math.maxInt(PartIndex);

// const Tag = PartTag;
pub const PartTag = enum {
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
    name_hash: u64, // hash of name for runtime lookups
    def_index: u16, // index into the plan this was built from
    tag: PartTag,
    side: Side,
    parent: ?PartIndex, // attachment hierarchy (arm → shoulder)
    enclosing: ?PartIndex, // containment (heart → torso)

    integrity: f32, // destroyed at 0.0
    wounds: std.ArrayList(Wound),
    is_severed: bool, // If true, all children are implicitly disconnected

    // FIXME: performantly look up PartDef flags before checking condition
    // must we also check parent isn't severed?
    fn can_grasp(self: *Part) bool {
        return self.integrity > 0.6;
    }

    fn can_support_weight(self: *Part) bool {
        return self.integrity > 0.3;
    }

    fn can_walk(self: *Part) bool {
        return self.integrity > 0.4;
    }

    fn can_run(self: *Part) bool {
        return self.integrity > 0.8;
    }

    fn can_write(self: *Part) bool {
        return self.integrity > 0.8;
    }

    // durability: f32, // an abstraction of density, circumference & hardness. Influenced by species + individual traits.
    // armour: precompute protective layers
};

pub const PartId = struct {
    hash: u64,
    pub fn init(comptime name: []const u8) PartId {
        @setEvalBranchQuota(10000);
        return .{ .hash = std.hash.Wyhash.hash(0, name) };
    }
};

pub const PartDef = struct {
    id: PartId,
    parent: ?PartId, // attachment: arm → shoulder → torso
    enclosing: ?PartId, // containment: heart → torso (must breach torso to reach heart)
    tag: PartTag,
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
    alloc: std.mem.Allocator,
    parts: std.ArrayList(Part),
    index_by_hash: std.AutoHashMap(u64, PartIndex), // name hash → part index

    pub fn fromPlan(alloc: std.mem.Allocator, plan: []const PartDef) !Body {
        var self = Body{
            .alloc = alloc,
            .parts = try std.ArrayList(Part).initCapacity(alloc, plan.len),
            .index_by_hash = std.AutoHashMap(u64, PartIndex).init(alloc),
        };
        errdefer self.deinit();

        try self.index_by_hash.ensureTotalCapacity(@intCast(plan.len));

        // First pass: create parts and build hash→index map
        for (plan, 0..) |def, i| {
            const part = Part{
                .name_hash = def.id.hash,
                .def_index = @intCast(i),
                .tag = def.tag,
                .side = def.side,
                .parent = null, // resolved in second pass
                .enclosing = null, // resolved in second pass
                .integrity = def.base_durability,
                .wounds = try std.ArrayList(Wound).initCapacity(alloc, 0),
                .is_severed = false,
            };
            try self.parts.append(alloc, part);
            try self.index_by_hash.put(def.id.hash, @intCast(i));
        }

        // Second pass: resolve parent and enclosing references
        for (plan, 0..) |def, i| {
            if (def.parent) |parent_id| {
                self.parts.items[i].parent = self.index_by_hash.get(parent_id.hash);
            }
            if (def.enclosing) |enclosing_id| {
                self.parts.items[i].enclosing = self.index_by_hash.get(enclosing_id.hash);
            }
        }

        return self;
    }

    /// Look up a part by its name hash
    pub fn getByHash(self: *const Body, hash: u64) ?*Part {
        const index = self.index_by_hash.get(hash) orelse return null;
        return &self.parts.items[index];
    }

    /// Look up a part by name (comptime)
    pub fn get(self: *const Body, comptime name: []const u8) ?*Part {
        return self.getByHash(PartId.init(name).hash);
    }

    /// Iterate over children of a part
    pub fn getChildren(self: *const Body, parent: PartIndex) ChildIterator {
        return ChildIterator{ .body = self, .parent = parent, .index = 0 };
    }

    /// Iterate over parts enclosed by another part
    pub fn getEnclosed(self: *const Body, enclosing: PartIndex) EnclosedIterator {
        return EnclosedIterator{ .body = self, .enclosing = enclosing, .index = 0 };
    }

    const ChildIterator = struct {
        body: *const Body,
        parent: PartIndex,
        index: usize,

        pub fn next(self: *ChildIterator) ?*Part {
            while (self.index < self.body.parts.items.len) : (self.index += 1) {
                const part = &self.body.parts.items[self.index];
                if (part.parent == self.parent) {
                    self.index += 1;
                    return part;
                }
            }
            return null;
        }
    };

    const EnclosedIterator = struct {
        body: *const Body,
        enclosing: PartIndex,
        index: usize,

        pub fn next(self: *EnclosedIterator) ?*Part {
            while (self.index < self.body.parts.items.len) : (self.index += 1) {
                const part = &self.body.parts.items[self.index];
                if (part.enclosing == self.enclosing) {
                    self.index += 1;
                    return part;
                }
            }
            return null;
        }
    };

    pub fn init(alloc: std.mem.Allocator) !Body {
        return Body{
            .alloc = alloc,
            .parts = try std.ArrayList(Part).initCapacity(alloc, 100),
            .index_by_hash = std.AutoHashMap(u64, PartIndex).init(alloc),
        };
    }

    pub fn deinit(self: *Body) void {
        // Free each part's wounds ArrayList
        for (self.parts.items) |*part| {
            part.wounds.deinit(self.alloc);
        }
        self.parts.deinit(self.alloc);
        self.index_by_hash.deinit();
    }
};

pub const Wound = struct {
    tissue: TissueLayer,
    severity: f32, // 0.0 to 1.0 (Severed / Crushed)
    type: DamageKind,
    // dressing
    // infection
};

// === Part definition helpers ===

const PartFlags = @TypeOf(@as(PartDef, undefined).flags);

const PartStats = struct {
    hit_chance: f32,
    durability: f32,
    trauma_mult: f32,
};

fn defaultStats(tag: PartTag) PartStats {
    return switch (tag) {
        // Large targets, high durability
        .torso => .{ .hit_chance = 0.30, .durability = 2.0, .trauma_mult = 1.0 },
        .abdomen => .{ .hit_chance = 0.15, .durability = 1.5, .trauma_mult = 1.2 },
        .head => .{ .hit_chance = 0.10, .durability = 1.0, .trauma_mult = 2.0 },

        // Limbs - moderate
        .thigh => .{ .hit_chance = 0.08, .durability = 1.2, .trauma_mult = 1.0 },
        .arm, .forearm, .shin => .{ .hit_chance = 0.05, .durability = 0.8, .trauma_mult = 1.0 },
        .shoulder => .{ .hit_chance = 0.04, .durability = 1.0, .trauma_mult = 1.0 },

        // Small targets, fragile
        .hand, .foot => .{ .hit_chance = 0.03, .durability = 0.5, .trauma_mult = 1.5 },
        .finger, .thumb, .toe => .{ .hit_chance = 0.01, .durability = 0.2, .trauma_mult = 2.0 },
        .eye, .ear, .nose => .{ .hit_chance = 0.02, .durability = 0.3, .trauma_mult = 3.0 },

        // Joints - small but important
        .neck => .{ .hit_chance = 0.04, .durability = 0.6, .trauma_mult = 2.5 },
        .wrist, .ankle, .elbow, .knee => .{ .hit_chance = 0.02, .durability = 0.4, .trauma_mult = 1.5 },
        .groin => .{ .hit_chance = 0.03, .durability = 0.5, .trauma_mult = 2.5 },

        // Organs - can't be hit directly (enclosed), variable fragility
        .brain => .{ .hit_chance = 0.0, .durability = 0.3, .trauma_mult = 5.0 },
        .heart => .{ .hit_chance = 0.0, .durability = 0.4, .trauma_mult = 5.0 },
        .lung => .{ .hit_chance = 0.0, .durability = 0.5, .trauma_mult = 3.0 },
        .liver, .stomach, .spleen => .{ .hit_chance = 0.0, .durability = 0.4, .trauma_mult = 2.5 },
        .intestine => .{ .hit_chance = 0.0, .durability = 0.6, .trauma_mult = 2.0 },
        .trachea => .{ .hit_chance = 0.0, .durability = 0.2, .trauma_mult = 4.0 },
        .tongue => .{ .hit_chance = 0.0, .durability = 0.3, .trauma_mult = 2.0 },
    };
}

fn definePartFull(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: ?[]const u8,
    comptime enclosing_name: ?[]const u8,
    flags: PartFlags,
) PartDef {
    @setEvalBranchQuota(10000);
    const stats = defaultStats(tag);
    return .{
        .id = PartId.init(name),
        .parent = if (parent_name) |p| PartId.init(p) else null,
        .enclosing = if (enclosing_name) |e| PartId.init(e) else null,
        .tag = tag,
        .side = side,
        .name = name,
        .base_hit_chance = stats.hit_chance,
        .base_durability = stats.durability,
        .trauma_mult = stats.trauma_mult,
        .flags = flags,
    };
}

// Basic structural part (limb segments, joints, digits)
fn ext(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: ?[]const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{});
}

// Vital exterior part (head, neck, torso) - loss is fatal or catastrophic
fn vital(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: ?[]const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{ .is_vital = true });
}

// Internal organ - enclosed by another part, vital by default
fn organ(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
    comptime enclosing_name: []const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, enclosing_name, .{
        .is_vital = true,
        .is_internal = true,
    });
}

// Non-vital internal part (e.g. spleen - survivable loss)
fn organMinor(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
    comptime enclosing_name: []const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, enclosing_name, .{
        .is_internal = true,
    });
}

// Sensory organ
fn sensory(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
    comptime flags: PartFlags,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, flags);
}

// Grasping part (hands)
fn grasping(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{ .can_grasp = true });
}

// Weight-bearing part (feet, legs)
fn standing(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{ .can_stand = true });
}
// to look up parts by ID at runtime, store a std.AutoHashMap(u64, PartIndex)
// when building the body, using part.id.hash as the key.

pub const HumanoidPlan = [_]PartDef{
    // === Core structure ===
    vital("torso", .torso, .center, null),
    vital("neck", .neck, .center, "torso"),
    vital("head", .head, .center, "neck"),
    vital("abdomen", .abdomen, .center, "torso"),
    ext("groin", .groin, .center, "abdomen"),

    // === Head - sensory organs ===
    sensory("left_eye", .eye, .left, "head", .{ .can_see = true }),
    sensory("right_eye", .eye, .right, "head", .{ .can_see = true }),
    ext("nose", .nose, .center, "head"),
    sensory("left_ear", .ear, .left, "head", .{ .can_hear = true }),
    sensory("right_ear", .ear, .right, "head", .{ .can_hear = true }),

    // === Internal organs - head ===
    organ("brain", .brain, .center, "head", "head"),

    // === Internal organs - torso (enclosed by torso) ===
    organ("heart", .heart, .center, "torso", "torso"),
    organ("left_lung", .lung, .left, "torso", "torso"),
    organ("right_lung", .lung, .right, "torso", "torso"),
    organ("trachea", .trachea, .center, "neck", "neck"),

    // === Internal organs - abdomen (enclosed by abdomen) ===
    organ("liver", .liver, .center, "abdomen", "abdomen"),
    organ("stomach", .stomach, .center, "abdomen", "abdomen"),
    organMinor("spleen", .spleen, .left, "abdomen", "abdomen"),
    organMinor("intestines", .intestine, .center, "abdomen", "abdomen"),

    // === Left arm chain ===
    ext("left_shoulder", .shoulder, .left, "torso"),
    ext("left_arm", .arm, .left, "left_shoulder"),
    ext("left_elbow", .elbow, .left, "left_arm"),
    ext("left_forearm", .forearm, .left, "left_elbow"),
    ext("left_wrist", .wrist, .left, "left_forearm"),
    grasping("left_hand", .hand, .left, "left_wrist"),
    ext("left_thumb", .thumb, .left, "left_hand"),
    ext("left_index_finger", .finger, .left, "left_hand"),
    ext("left_middle_finger", .finger, .left, "left_hand"),
    ext("left_ring_finger", .finger, .left, "left_hand"),
    ext("left_pinky_finger", .finger, .left, "left_hand"),

    // === Right arm chain ===
    ext("right_shoulder", .shoulder, .right, "torso"),
    ext("right_arm", .arm, .right, "right_shoulder"),
    ext("right_elbow", .elbow, .right, "right_arm"),
    ext("right_forearm", .forearm, .right, "right_elbow"),
    ext("right_wrist", .wrist, .right, "right_forearm"),
    grasping("right_hand", .hand, .right, "right_wrist"),
    ext("right_thumb", .thumb, .right, "right_hand"),
    ext("right_index_finger", .finger, .right, "right_hand"),
    ext("right_middle_finger", .finger, .right, "right_hand"),
    ext("right_ring_finger", .finger, .right, "right_hand"),
    ext("right_pinky_finger", .finger, .right, "right_hand"),

    // === Left leg chain ===
    standing("left_thigh", .thigh, .left, "groin"),
    ext("left_knee", .knee, .left, "left_thigh"),
    standing("left_shin", .shin, .left, "left_knee"),
    ext("left_ankle", .ankle, .left, "left_shin"),
    standing("left_foot", .foot, .left, "left_ankle"),
    ext("left_big_toe", .toe, .left, "left_foot"),
    ext("left_second_toe", .toe, .left, "left_foot"),
    ext("left_third_toe", .toe, .left, "left_foot"),
    ext("left_fourth_toe", .toe, .left, "left_foot"),
    ext("left_pinky_toe", .toe, .left, "left_foot"),

    // === Right leg chain ===
    standing("right_thigh", .thigh, .right, "groin"),
    ext("right_knee", .knee, .right, "right_thigh"),
    standing("right_shin", .shin, .right, "right_knee"),
    ext("right_ankle", .ankle, .right, "right_shin"),
    standing("right_foot", .foot, .right, "right_ankle"),
    ext("right_big_toe", .toe, .right, "right_foot"),
    ext("right_second_toe", .toe, .right, "right_foot"),
    ext("right_third_toe", .toe, .right, "right_foot"),
    ext("right_fourth_toe", .toe, .right, "right_foot"),
    ext("right_pinky_toe", .toe, .right, "right_foot"),
};
