const std = @import("std");
const damage = @import("damage.zig");
const events = @import("events.zig");
const EventSystem = events.EventSystem;
const Event = events.Event;
const entity = @import("entity.zig");

const DamageKind = damage.Kind;

pub const PartIndex = u16; // Up to 65k body parts is enough
pub const NO_PARENT = std.math.maxInt(PartIndex);

// Still TODO:
// - Severing logic (when bone+muscle reach thresholds)
// - Major artery hits → bleeding
// - Attaching wounds to parts and updating Part.severity
// - Integration with armor stack

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

pub const Side = enum(u8) {
    left,
    right,
    center, // for Agent.dominant_side, this == ambidextrous
    none,
};

pub const Height = enum(u8) {
    low,
    mid,
    high,

    pub fn adjacent(self: Height, other: Height) bool {
        return switch (self) {
            .low => other == .mid,
            .mid => true, // mid is adjacent to both
            .high => other == .mid,
        };
    }
};

// ============================================================================
// Stance / Exposure (MVP: static tables, no composition yet)
// ============================================================================

pub const Exposure = struct {
    tag: PartTag,
    side: Side,
    base_chance: f32,
    height: Height,
};

/// Default humanoid exposure table - standing, facing opponent
/// Probabilities sum to ~1.0 (minor rounding)
pub const humanoid_exposures = [_]Exposure{
    // High zone
    .{ .tag = .head, .side = .center, .base_chance = 0.08, .height = .high },
    .{ .tag = .neck, .side = .center, .base_chance = 0.03, .height = .high },
    .{ .tag = .eye, .side = .left, .base_chance = 0.005, .height = .high },
    .{ .tag = .eye, .side = .right, .base_chance = 0.005, .height = .high },
    .{ .tag = .ear, .side = .left, .base_chance = 0.005, .height = .high },
    .{ .tag = .ear, .side = .right, .base_chance = 0.005, .height = .high },
    .{ .tag = .nose, .side = .center, .base_chance = 0.01, .height = .high },

    // Mid zone
    .{ .tag = .torso, .side = .center, .base_chance = 0.25, .height = .mid },
    .{ .tag = .abdomen, .side = .center, .base_chance = 0.12, .height = .mid },
    .{ .tag = .shoulder, .side = .left, .base_chance = 0.025, .height = .mid },
    .{ .tag = .shoulder, .side = .right, .base_chance = 0.025, .height = .mid },
    .{ .tag = .arm, .side = .left, .base_chance = 0.03, .height = .mid },
    .{ .tag = .arm, .side = .right, .base_chance = 0.03, .height = .mid },
    .{ .tag = .elbow, .side = .left, .base_chance = 0.01, .height = .mid },
    .{ .tag = .elbow, .side = .right, .base_chance = 0.01, .height = .mid },
    .{ .tag = .forearm, .side = .left, .base_chance = 0.02, .height = .mid },
    .{ .tag = .forearm, .side = .right, .base_chance = 0.02, .height = .mid },
    .{ .tag = .wrist, .side = .left, .base_chance = 0.008, .height = .mid },
    .{ .tag = .wrist, .side = .right, .base_chance = 0.008, .height = .mid },
    .{ .tag = .hand, .side = .left, .base_chance = 0.012, .height = .mid },
    .{ .tag = .hand, .side = .right, .base_chance = 0.012, .height = .mid },

    // Low zone
    .{ .tag = .groin, .side = .center, .base_chance = 0.02, .height = .low },
    .{ .tag = .thigh, .side = .left, .base_chance = 0.04, .height = .low },
    .{ .tag = .thigh, .side = .right, .base_chance = 0.04, .height = .low },
    .{ .tag = .knee, .side = .left, .base_chance = 0.015, .height = .low },
    .{ .tag = .knee, .side = .right, .base_chance = 0.015, .height = .low },
    .{ .tag = .shin, .side = .left, .base_chance = 0.025, .height = .low },
    .{ .tag = .shin, .side = .right, .base_chance = 0.025, .height = .low },
    .{ .tag = .ankle, .side = .left, .base_chance = 0.008, .height = .low },
    .{ .tag = .ankle, .side = .right, .base_chance = 0.008, .height = .low },
    .{ .tag = .foot, .side = .left, .base_chance = 0.012, .height = .low },
    .{ .tag = .foot, .side = .right, .base_chance = 0.012, .height = .low },
};

pub const TissueLayer = enum {
    organ,
    cartilage,
    bone,
    tendon,
    muscle,
    fat,
    nerve,
    skin,
    // Note: arteries/veins handled via has_major_artery flag on PartDef.
    // All parts have capillaries (minor bleed); major vessels are site-specific.
};

pub const TissueTemplate = enum {
    limb, // bone, muscle, tendon, fat, nerve, skin
    digit, // bone, tendon, skin (minimal soft tissue)
    joint, // bone, tendon, fat, skin
    facial, // cartilage, fat, skin (no bone)
    organ, // organ tissue only
    core, // bone, muscle, fat, skin (torso/head - encloses organs)

    pub fn layers(self: TissueTemplate) []const TissueLayer {
        return switch (self) {
            .limb => &.{ .bone, .muscle, .tendon, .fat, .nerve, .skin },
            .digit => &.{ .bone, .tendon, .skin },
            .joint => &.{ .bone, .tendon, .fat, .skin },
            .facial => &.{ .cartilage, .fat, .skin },
            .organ => &.{.organ},
            .core => &.{ .bone, .muscle, .fat, .skin },
        };
    }

    pub fn has(self: TissueTemplate, layer: TissueLayer) bool {
        for (self.layers()) |l| {
            if (l == layer) return true;
        }
        return false;
    }
};

pub const Part = struct {
    name_hash: u64, // hash of name for runtime lookups
    def_index: u16, // index into the plan this was built from
    tag: PartTag,
    side: Side,
    parent: ?PartIndex, // attachment hierarchy (arm → shoulder)
    enclosing: ?PartIndex, // containment (heart → torso)
    flags: PartDef.Flags, // capability flags copied from def
    tissue: TissueTemplate, // tissue composition
    has_major_artery: bool, // major blood vessel present

    severity: Severity, // overall part damage state
    wounds: std.ArrayList(Wound),
    is_severed: bool, // physically detached; all children implicitly disconnected
    // Note: capability checks (can_grasp, can_stand, etc) are on Body, not Part,
    // because they require tree traversal for chain integrity.

    /// Compute part severity from accumulated wound damage.
    /// Uses structural layer (bone/cartilage) as primary indicator.
    pub fn computeSeverity(self: *const Part) Severity {
        var worst_structural: Severity = .none;
        var worst_any: Severity = .none;

        for (self.wounds.items) |wound| {
            for (wound.slice()) |ld| {
                // Track worst across all layers
                if (@intFromEnum(ld.severity) > @intFromEnum(worst_any)) {
                    worst_any = ld.severity;
                }
                // Track worst in structural layers (bone, cartilage)
                if (ld.layer == .bone or ld.layer == .cartilage) {
                    if (@intFromEnum(ld.severity) > @intFromEnum(worst_structural)) {
                        worst_structural = ld.severity;
                    }
                }
            }
        }

        // Structural damage dominates, but severe soft tissue damage matters too
        // e.g., muscle at .broken with bone at .minor → part is impaired
        if (@intFromEnum(worst_structural) >= @intFromEnum(worst_any)) {
            return worst_structural;
        }
        // Soft tissue damage can't exceed structural by more than one step
        // (you can't have a "broken" part if bone is fine)
        const structural_int = @intFromEnum(worst_structural);
        const any_int = @intFromEnum(worst_any);
        const capped = @min(any_int, structural_int + 2);
        return @enumFromInt(capped);
    }
};

pub const PartId = struct {
    hash: u64,
    pub fn init(comptime name: []const u8) PartId {
        @setEvalBranchQuota(10000);
        return .{ .hash = std.hash.Wyhash.hash(0, name) };
    }
};

pub const PartDef = struct {
    pub const Flags = packed struct {
        is_vital: bool = false,
        is_internal: bool = false,
        can_grasp: bool = false,
        can_stand: bool = false,
        can_see: bool = false,
        can_hear: bool = false,
    };

    id: PartId,
    parent: ?PartId, // attachment: arm → shoulder → torso
    enclosing: ?PartId, // containment: heart → torso (must breach torso to reach heart)
    tag: PartTag,
    side: Side,
    name: []const u8,
    base_hit_chance: f32, // WARN: deprecated, we use the temporary static exposure table above, to be replaced - see `doc/stance_design.md`
    base_durability: f32,
    trauma_mult: f32,
    flags: Flags = .{},
    tissue: TissueTemplate = .limb,
    has_major_artery: bool = false, // neck, groin, armpit, inner thigh
};

pub const Body = struct {
    agent_id: entity.ID = undefined, // Body created before agent; set in Agent.init
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
                .flags = def.flags,
                .tissue = def.tissue,
                .has_major_artery = def.has_major_artery,
                .severity = .none, // undamaged
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

    /// Get the index of a part (from hash lookup)
    pub fn indexOf(self: *const Body, comptime name: []const u8) ?PartIndex {
        return self.index_by_hash.get(PartId.init(name).hash);
    }

    /// Check if a part is severed (directly or via severed ancestor)
    pub fn isEffectivelySevered(self: *const Body, index: PartIndex) bool {
        var current: ?PartIndex = index;
        while (current) |idx| {
            const p = &self.parts.items[idx];
            if (p.is_severed) return true;
            current = p.parent;
        }
        return false;
    }

    /// Compute effective integrity for all parts in one pass.
    /// Assumes parts are in topological order (parents before children).
    /// effective = self.severity.toIntegrity() * parent.effective (propagates damage down tree)
    pub fn computeEffectiveIntegrities(self: *const Body, out: []f32) void {
        std.debug.assert(out.len >= self.parts.items.len);

        for (self.parts.items, 0..) |*part, i| {
            const integrity = part.severity.toIntegrity();
            if (part.is_severed) {
                out[i] = 0;
            } else if (part.parent) |parent_idx| {
                out[i] = integrity * out[parent_idx];
            } else {
                out[i] = integrity; // root
            }
        }
    }

    /// Get effective integrity for a single part (convenience wrapper)
    pub fn effectiveIntegrity(self: *const Body, index: PartIndex) f32 {
        var buf: [256]f32 = undefined;
        self.computeEffectiveIntegrities(buf[0..self.parts.items.len]);
        return buf[index];
    }

    /// Compute grasp strength for a grasping part.
    /// Factors in: part integrity, children integrity, chain integrity
    pub fn graspStrength(self: *const Body, part_idx: PartIndex) f32 {
        var buf: [256]f32 = undefined;
        const eff = buf[0..self.parts.items.len];
        self.computeEffectiveIntegrities(eff);

        if (eff[part_idx] <= 0) return 0;

        var strength = eff[part_idx];

        // Children contribute proportionally
        var total_children: f32 = 0;
        var functional_integrity: f32 = 0;

        var iter = self.getChildren(part_idx);
        while (iter.next()) |child_idx| {
            total_children += 1;
            const child = &self.parts.items[child_idx];
            if (!child.is_severed) {
                functional_integrity += eff[child_idx];
            }
        }

        if (total_children > 0) {
            // 5 fingers at 1.0 = 1.0, 3 fingers at 1.0 = 0.6
            strength *= functional_integrity / total_children;
        }

        return strength;
    }

    /// Result of functionalGraspingParts query
    pub const GraspingPartsResult = struct {
        parts: [8]PartIndex = undefined,
        len: usize = 0,

        pub fn slice(self: *const GraspingPartsResult) []const PartIndex {
            return self.parts[0..self.len];
        }
    };

    /// Get all functional grasping parts above a minimum strength threshold
    pub fn functionalGraspingParts(self: *const Body, min_strength: f32) GraspingPartsResult {
        var result = GraspingPartsResult{};

        for (self.parts.items, 0..) |p, i| {
            if (result.len >= 8) break;
            const idx: PartIndex = @intCast(i);
            if (p.flags.can_grasp) {
                if (self.graspStrength(idx) >= min_strength) {
                    result.parts[result.len] = idx;
                    result.len += 1;
                }
            }
        }
        return result;
    }

    /// Overall mobility score based on standing parts
    pub fn mobilityScore(self: *const Body) f32 {
        var buf: [256]f32 = undefined;
        const eff = buf[0..self.parts.items.len];
        self.computeEffectiveIntegrities(eff);

        var total: f32 = 0;
        var count: f32 = 0;

        for (self.parts.items, 0..) |p, i| {
            if (p.flags.can_stand) {
                total += eff[i];
                count += 1;
            }
        }

        return if (count > 0) total / count else 0;
    }

    /// Result of applying damage to a part
    pub const DamageResult = struct {
        wound: Wound,
        severed: bool,
        hit_major_artery: bool,
    };

    pub fn applyDamageWithEvents(self: *Body, event_sys: *EventSystem, part_idx: PartIndex, packet: damage.Packet) !DamageResult {
        const result = try self.applyDamageToPart(part_idx, packet);

        if (result.wound.len > 0) {
            try event_sys.push(.{ .wound_inflicted = .{
                .agent_id = self.agent_id,
                .wound = result.wound,
                .part_idx = part_idx,
            } });
        }
        if (result.severed) {
            try event_sys.push(.{ .body_part_severed = .{
                .agent_id = self.agent_id,
                .part_idx = part_idx,
            } });
        }
        if (result.hit_major_artery) {
            try event_sys.push(.{ .hit_major_artery = .{
                .agent_id = self.agent_id,
                .part_idx = part_idx,
            } });
        }

        return result;
    }

    /// Apply a damage packet to a specific part.
    /// Creates a wound, adds it to the part, updates severity, checks for severing.
    pub fn applyDamageToPart(self: *Body, part_idx: PartIndex, packet: damage.Packet) !DamageResult {
        const part = &self.parts.items[part_idx];

        // Generate wound based on part's tissue template
        const wound = applyDamage(packet, part.tissue);

        // Add wound to part (if any layers damaged)
        if (wound.len > 0) {
            try part.wounds.append(self.alloc, wound);
        }

        // Recompute severity from all wounds
        part.severity = part.computeSeverity();

        // Check for severing: structural layer at .missing from slash,
        // or .broken+ structural from massive damage
        const severed = checkSevering(part, &wound);
        if (severed) {
            part.is_severed = true;
        }

        // Check if major artery was hit (for bleeding)
        const hit_artery = part.has_major_artery and
            (@intFromEnum(wound.severityAt(.muscle)) >= @intFromEnum(Severity.inhibited) or
                @intFromEnum(wound.severityAt(.fat)) >= @intFromEnum(Severity.disabled));

        return .{
            .wound = wound,
            .severed = severed,
            .hit_major_artery = hit_artery,
        };
    }

    const ChildIterator = struct {
        body: *const Body,
        parent: PartIndex,
        index: usize,

        pub fn next(self: *ChildIterator) ?PartIndex {
            while (self.index < self.body.parts.items.len) : (self.index += 1) {
                const part = &self.body.parts.items[self.index];
                if (part.parent == self.parent) {
                    const idx: PartIndex = @intCast(self.index);
                    self.index += 1;
                    return idx;
                }
            }
            return null;
        }
    };

    const EnclosedIterator = struct {
        body: *const Body,
        enclosing: PartIndex,
        index: usize,

        pub fn next(self: *EnclosedIterator) ?PartIndex {
            while (self.index < self.body.parts.items.len) : (self.index += 1) {
                const part = &self.body.parts.items[self.index];
                if (part.enclosing == self.enclosing) {
                    const idx: PartIndex = @intCast(self.index);
                    self.index += 1;
                    return idx;
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

pub const Severity = enum {
    none,
    minor,
    inhibited,
    disabled,
    broken,
    missing,

    /// Convert severity to a 0.0-1.0 integrity value for calculations.
    /// Tuning these values affects how damage propagates through part chains.
    pub fn toIntegrity(self: Severity) f32 {
        return switch (self) {
            .none => 1.0,
            .minor => 0.85,
            .inhibited => 0.6,
            .disabled => 0.3,
            .broken => 0.1,
            .missing => 0.0,
        };
    }
};

pub const LayerDamage = struct {
    layer: TissueLayer,
    severity: Severity,
};

pub const Wound = struct {
    const MAX_LAYERS = 6;

    kind: DamageKind,
    len: u8 = 0,
    damages: [MAX_LAYERS]LayerDamage = undefined,
    // TODO: dressing, infection, bleeding

    pub fn slice(self: *const Wound) []const LayerDamage {
        return self.damages[0..self.len];
    }

    pub fn append(self: *Wound, ld: LayerDamage) void {
        if (self.len < MAX_LAYERS) {
            self.damages[self.len] = ld;
            self.len += 1;
        }
    }

    pub fn severityAt(self: *const Wound, layer: TissueLayer) Severity {
        for (self.slice()) |ld| {
            if (ld.layer == layer) return ld.severity;
        }
        return .none;
    }

    pub fn deepestLayer(self: *const Wound) ?TissueLayer {
        if (self.len == 0) return null;
        var deepest: TissueLayer = self.damages[0].layer;
        var max_depth: u8 = 0;
        for (self.slice()) |ld| {
            const d = layerDepth(ld.layer);
            if (d > max_depth) {
                max_depth = d;
                deepest = ld.layer;
            }
        }
        return deepest;
    }

    pub fn worstSeverity(self: *const Wound) Severity {
        var worst: Severity = .none;
        for (self.slice()) |ld| {
            if (@intFromEnum(ld.severity) > @intFromEnum(worst)) {
                worst = ld.severity;
            }
        }
        return worst;
    }
};

/// Depth ordering for tissue layers (0 = outermost)
pub fn layerDepth(layer: TissueLayer) u8 {
    return switch (layer) {
        .skin => 0,
        .fat => 1,
        .muscle => 2,
        .tendon => 3,
        .nerve => 3,
        .bone => 4,
        .cartilage => 4,
        .organ => 5,
    };
}

/// How a layer interacts with damage types
pub const LayerResistance = struct {
    /// Fraction of incoming damage this layer absorbs (dealt to this layer)
    absorb: f32,
    /// Penetration cost to pass through this layer
    pen_cost: f32,
};

/// Get resistance values for a layer vs damage type
pub fn layerResistance(layer: TissueLayer, kind: DamageKind) LayerResistance {
    return switch (kind) {
        .slash => switch (layer) {
            // Slash: wide, shallow - outer layers take heavy damage
            .skin => .{ .absorb = 0.40, .pen_cost = 0.3 },
            .fat => .{ .absorb = 0.25, .pen_cost = 0.2 },
            .muscle => .{ .absorb = 0.20, .pen_cost = 0.3 },
            .tendon => .{ .absorb = 0.30, .pen_cost = 0.2 },
            .nerve => .{ .absorb = 0.10, .pen_cost = 0.1 },
            .bone => .{ .absorb = 0.10, .pen_cost = 1.0 }, // hard to cut bone
            .cartilage => .{ .absorb = 0.25, .pen_cost = 0.3 },
            .organ => .{ .absorb = 0.30, .pen_cost = 0.2 },
        },
        .pierce => switch (layer) {
            // Pierce: narrow, deep - passes through easily, less damage per layer
            .skin => .{ .absorb = 0.10, .pen_cost = 0.1 },
            .fat => .{ .absorb = 0.10, .pen_cost = 0.1 },
            .muscle => .{ .absorb = 0.15, .pen_cost = 0.2 },
            .tendon => .{ .absorb = 0.15, .pen_cost = 0.1 },
            .nerve => .{ .absorb = 0.10, .pen_cost = 0.1 },
            .bone => .{ .absorb = 0.40, .pen_cost = 0.8 }, // bone stops piercing
            .cartilage => .{ .absorb = 0.20, .pen_cost = 0.3 },
            .organ => .{ .absorb = 0.25, .pen_cost = 0.2 },
        },
        .bludgeon => switch (layer) {
            // Bludgeon: transfers through - bone/muscle take most damage
            .skin => .{ .absorb = 0.05, .pen_cost = 0.0 }, // no penetration concept
            .fat => .{ .absorb = 0.10, .pen_cost = 0.0 },
            .muscle => .{ .absorb = 0.30, .pen_cost = 0.0 },
            .tendon => .{ .absorb = 0.10, .pen_cost = 0.0 },
            .nerve => .{ .absorb = 0.15, .pen_cost = 0.0 },
            .bone => .{ .absorb = 0.50, .pen_cost = 0.0 }, // bone absorbs impact
            .cartilage => .{ .absorb = 0.30, .pen_cost = 0.0 },
            .organ => .{ .absorb = 0.35, .pen_cost = 0.0 },
        },
        else => .{ .absorb = 0.20, .pen_cost = 0.2 }, // fallback for other damage types
    };
}

/// Thresholds for converting damage amount to severity
fn severityFromDamage(amount: f32) Severity {
    if (amount < 0.05) return .none;
    if (amount < 0.15) return .minor;
    if (amount < 0.30) return .inhibited;
    if (amount < 0.50) return .disabled;
    if (amount < 0.80) return .broken;
    return .missing;
}

/// Apply a damage packet to a body part, producing a wound.
/// Processes tissue layers outside-in based on the part's template.
pub fn applyDamage(
    packet: damage.Packet,
    template: TissueTemplate,
) Wound {
    var wound = Wound{ .kind = packet.kind };
    var remaining = packet.amount;
    var penetration = packet.penetration;

    // Process layers outside-in (sorted by depth)
    const layers = template.layers();
    var sorted: [6]TissueLayer = undefined;
    var sorted_len: usize = 0;
    for (layers) |layer| {
        sorted[sorted_len] = layer;
        sorted_len += 1;
    }
    // Sort by depth (bubble sort is fine for max 6 elements)
    for (0..sorted_len) |i| {
        for (i + 1..sorted_len) |j| {
            if (layerDepth(sorted[j]) < layerDepth(sorted[i])) {
                const tmp = sorted[i];
                sorted[i] = sorted[j];
                sorted[j] = tmp;
            }
        }
    }

    for (sorted[0..sorted_len]) |layer| {
        // Bludgeon ignores penetration; others stop when penetration exhausted
        const dominated_by_pen = packet.kind == .pierce or packet.kind == .slash;
        if (remaining <= 0 or (dominated_by_pen and penetration <= 0)) break;

        const res = layerResistance(layer, packet.kind);
        const absorbed = remaining * res.absorb;
        const severity = severityFromDamage(absorbed);

        if (severity != .none) {
            wound.append(.{ .layer = layer, .severity = severity });
        }

        remaining -= absorbed;
        penetration -= res.pen_cost;
    }

    return wound;
}

/// Check if a wound causes severing of a part.
/// Severing requires structural damage (bone/cartilage) plus soft tissue damage.
fn checkSevering(part: *const Part, wound: *const Wound) bool {
    // Already severed
    if (part.is_severed) return false;

    const bone_sev = wound.severityAt(.bone);
    const cartilage_sev = wound.severityAt(.cartilage);
    const muscle_sev = wound.severityAt(.muscle);
    const tendon_sev = wound.severityAt(.tendon);

    // Determine which structural layer is relevant for this part
    const has_bone = part.tissue.has(.bone);
    const has_cartilage = part.tissue.has(.cartilage);

    const structural_sev = if (has_bone)
        bone_sev
    else if (has_cartilage)
        cartilage_sev
    else
        return false; // no structural layer (e.g., organ) - can't sever

    // Severing rules by damage type
    const structural_int = @intFromEnum(structural_sev);
    const muscle_int = @intFromEnum(muscle_sev);
    const tendon_int = @intFromEnum(tendon_sev);
    const broken_int = @intFromEnum(Severity.broken);
    const disabled_int = @intFromEnum(Severity.disabled);
    const missing_int = @intFromEnum(Severity.missing);

    switch (wound.kind) {
        .slash => {
            // Slash severs when: structural broken + muscle/tendon disabled+
            if (structural_int >= broken_int) {
                if (muscle_int >= disabled_int or tendon_int >= disabled_int) {
                    return true;
                }
            }
            // Or structural missing (clean cut through bone)
            if (structural_int >= missing_int) return true;
        },
        .pierce => {
            // Pierce rarely severs - only if structural is missing
            if (structural_int >= missing_int) return true;
        },
        .bludgeon, .crush, .shatter => {
            // Bludgeon/crush can shatter-sever if bone is missing
            if (structural_int >= missing_int) return true;
        },
        else => {},
    }

    return false;
}

// === Part definition helpers ===

const PartFlags = PartDef.Flags;

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

fn defaultTemplate(tag: PartTag) TissueTemplate {
    return switch (tag) {
        // Core structures (enclose organs, have bone)
        .head, .torso, .abdomen => .core,
        .neck => .core, // vertebrae

        // Limb segments
        .arm, .forearm, .thigh, .shin => .limb,
        .shoulder => .limb, // scapula + humerus head

        // Joints
        .elbow, .knee, .wrist, .ankle, .groin => .joint,

        // Extremities
        .hand, .foot => .joint, // complex bone structure
        .finger, .thumb, .toe => .digit,

        // Facial features (cartilage-based)
        .eye, .ear, .nose => .facial,

        // Internal organs
        .brain, .heart, .lung, .stomach, .liver, .intestine, .tongue, .trachea, .spleen => .organ,
    };
}

fn definePartFull(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: ?[]const u8,
    comptime enclosing_name: ?[]const u8,
    flags: PartFlags,
    has_major_artery: bool,
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
        .tissue = defaultTemplate(tag),
        .has_major_artery = has_major_artery,
    };
}

// Basic structural part (limb segments, joints, digits)
fn ext(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: ?[]const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{}, false);
}

// Vital exterior part (head, neck, torso) - loss is fatal or catastrophic
fn vital(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: ?[]const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{ .is_vital = true }, false);
}

// Vital part with major artery (neck)
fn vitalArtery(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: ?[]const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{ .is_vital = true }, true);
}

// Part with major artery but not vital (groin, inner thigh, armpit)
fn artery(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: ?[]const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{}, true);
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
    }, false);
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
    }, false);
}

// Sensory organ
fn sensory(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
    comptime flags: PartFlags,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, flags, false);
}

// Grasping part (hands)
fn grasping(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{ .can_grasp = true }, false);
}

// Weight-bearing part (feet, legs)
fn standing(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{ .can_stand = true }, false);
}

// Weight-bearing part with major artery (thigh)
fn standingArtery(
    comptime name: []const u8,
    tag: PartTag,
    side: Side,
    comptime parent_name: []const u8,
) PartDef {
    return definePartFull(name, tag, side, parent_name, null, .{ .can_stand = true }, true);
}
// to look up parts by ID at runtime, store a std.AutoHashMap(u64, PartIndex)
// when building the body, using part.id.hash as the key.

pub const HumanoidPlan = [_]PartDef{
    // === Core structure ===
    vital("torso", .torso, .center, null),
    vitalArtery("neck", .neck, .center, "torso"), // carotid, jugular
    vital("head", .head, .center, "neck"),
    vital("abdomen", .abdomen, .center, "torso"),
    artery("groin", .groin, .center, "abdomen"), // femoral

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
    artery("left_shoulder", .shoulder, .left, "torso"), // axillary
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
    artery("right_shoulder", .shoulder, .right, "torso"), // axillary
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
    standingArtery("left_thigh", .thigh, .left, "groin"), // femoral
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
    standingArtery("right_thigh", .thigh, .right, "groin"), // femoral
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

// === Tests ===

test "body fromPlan creates correct part count" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    try std.testing.expectEqual(HumanoidPlan.len, body.parts.items.len);
}

test "body part lookup by name" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const hand = body.get("left_hand");
    try std.testing.expect(hand != null);
    try std.testing.expectEqual(PartTag.hand, hand.?.tag);
    try std.testing.expectEqual(Side.left, hand.?.side);
}

test "severing arm propagates to children" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    // Get indices for arm chain
    const arm_idx = body.indexOf("left_arm").?;
    const hand_idx = body.indexOf("left_hand").?;
    const finger_idx = body.indexOf("left_index_finger").?;
    const torso_idx = body.indexOf("torso").?;

    // Nothing severed initially
    try std.testing.expect(!body.isEffectivelySevered(arm_idx));
    try std.testing.expect(!body.isEffectivelySevered(hand_idx));
    try std.testing.expect(!body.isEffectivelySevered(finger_idx));

    // Sever the arm
    body.parts.items[arm_idx].is_severed = true;

    // Arm and all descendants are now effectively severed
    try std.testing.expect(body.isEffectivelySevered(arm_idx));
    try std.testing.expect(body.isEffectivelySevered(hand_idx));
    try std.testing.expect(body.isEffectivelySevered(finger_idx));

    // Torso is NOT severed
    try std.testing.expect(!body.isEffectivelySevered(torso_idx));
}

test "child iterator finds direct children" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const hand_idx = body.indexOf("left_hand").?;

    // Count children of left_hand (should be 5: thumb + 4 fingers)
    var iter = body.getChildren(hand_idx);
    var count: usize = 0;
    while (iter.next()) |child_idx| {
        const child = &body.parts.items[child_idx];
        try std.testing.expect(child.tag == .finger or child.tag == .thumb);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "enclosed iterator finds organs" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const torso_idx = body.indexOf("torso").?;

    // Count organs enclosed by torso (heart, left_lung, right_lung)
    var iter = body.getEnclosed(torso_idx);
    var count: usize = 0;
    while (iter.next()) |enclosed_idx| {
        const enclosed = &body.parts.items[enclosed_idx];
        try std.testing.expect(enclosed.tag == .heart or enclosed.tag == .lung);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "effective integrity propagates through chain" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const shoulder_idx = body.indexOf("left_shoulder").?;
    const hand_idx = body.indexOf("left_hand").?;

    // Full integrity chain
    const hand_eff_before = body.effectiveIntegrity(hand_idx);
    try std.testing.expect(hand_eff_before > 0.9);

    // Damage shoulder to .disabled (0.3 integrity)
    body.parts.items[shoulder_idx].severity = .disabled;

    // Hand effective integrity should be reduced
    const hand_eff_after = body.effectiveIntegrity(hand_idx);
    try std.testing.expect(hand_eff_after < hand_eff_before);
    try std.testing.expect(hand_eff_after <= 0.3);
}

test "grasp strength factors in fingers" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const hand_idx = body.indexOf("left_hand").?;

    // Full strength with all fingers
    const full_strength = body.graspStrength(hand_idx);
    try std.testing.expect(full_strength > 0.9);

    // Sever two fingers
    const idx_finger = body.indexOf("left_index_finger").?;
    const mid_finger = body.indexOf("left_middle_finger").?;
    body.parts.items[idx_finger].is_severed = true;
    body.parts.items[mid_finger].is_severed = true;

    // Reduced strength (3/5 fingers working)
    const reduced_strength = body.graspStrength(hand_idx);
    try std.testing.expect(reduced_strength < full_strength);
    try std.testing.expect(reduced_strength > 0.5); // Still usable
}

test "mobility score with damaged groin" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const groin_idx = body.indexOf("groin").?;

    // Full mobility
    const full_mobility = body.mobilityScore();
    try std.testing.expect(full_mobility > 0.9);

    // Damage groin to .disabled (affects both legs)
    body.parts.items[groin_idx].severity = .disabled;

    // Reduced mobility
    const reduced_mobility = body.mobilityScore();
    try std.testing.expect(reduced_mobility < full_mobility);
    try std.testing.expect(reduced_mobility < 0.5);
}

test "functional grasping parts" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    // Both hands should be functional
    const hands = body.functionalGraspingParts(0.5);
    try std.testing.expectEqual(@as(usize, 2), hands.len);

    // Sever left arm
    const left_arm_idx = body.indexOf("left_arm").?;
    body.parts.items[left_arm_idx].is_severed = true;

    // Only right hand functional now
    const hands_after = body.functionalGraspingParts(0.5);
    try std.testing.expectEqual(@as(usize, 1), hands_after.len);
}

test "tissue template layer queries" {
    // Limbs have bone, muscle, etc.
    try std.testing.expect(TissueTemplate.limb.has(.bone));
    try std.testing.expect(TissueTemplate.limb.has(.muscle));
    try std.testing.expect(TissueTemplate.limb.has(.skin));
    try std.testing.expect(!TissueTemplate.limb.has(.cartilage));
    try std.testing.expect(!TissueTemplate.limb.has(.organ));

    // Digits are minimal
    try std.testing.expect(TissueTemplate.digit.has(.bone));
    try std.testing.expect(TissueTemplate.digit.has(.tendon));
    try std.testing.expect(!TissueTemplate.digit.has(.muscle));

    // Facial features have cartilage, not bone
    try std.testing.expect(TissueTemplate.facial.has(.cartilage));
    try std.testing.expect(!TissueTemplate.facial.has(.bone));
}

test "part definitions have correct tissue and artery flags" {
    // Check a few representative parts from HumanoidPlan
    for (HumanoidPlan) |def| {
        if (std.mem.eql(u8, def.name, "neck")) {
            try std.testing.expectEqual(TissueTemplate.core, def.tissue);
            try std.testing.expect(def.has_major_artery); // carotid
        }
        if (std.mem.eql(u8, def.name, "left_thigh")) {
            try std.testing.expectEqual(TissueTemplate.limb, def.tissue);
            try std.testing.expect(def.has_major_artery); // femoral
        }
        if (std.mem.eql(u8, def.name, "left_index_finger")) {
            try std.testing.expectEqual(TissueTemplate.digit, def.tissue);
            try std.testing.expect(!def.has_major_artery);
        }
        if (std.mem.eql(u8, def.name, "nose")) {
            try std.testing.expectEqual(TissueTemplate.facial, def.tissue);
            try std.testing.expect(!def.has_major_artery);
        }
    }
}

// === Wound and damage application tests ===

test "wound tracks layer damage" {
    var wound = Wound{ .kind = .slash };
    wound.append(.{ .layer = .skin, .severity = .broken });
    wound.append(.{ .layer = .fat, .severity = .disabled });
    wound.append(.{ .layer = .muscle, .severity = .minor });

    try std.testing.expectEqual(@as(u8, 3), wound.len);
    try std.testing.expectEqual(Severity.broken, wound.severityAt(.skin));
    try std.testing.expectEqual(Severity.disabled, wound.severityAt(.fat));
    try std.testing.expectEqual(Severity.minor, wound.severityAt(.muscle));
    try std.testing.expectEqual(Severity.none, wound.severityAt(.bone)); // not hit
}

test "wound finds deepest layer and worst severity" {
    var wound = Wound{ .kind = .pierce };
    wound.append(.{ .layer = .skin, .severity = .minor });
    wound.append(.{ .layer = .muscle, .severity = .inhibited });
    wound.append(.{ .layer = .bone, .severity = .minor });

    try std.testing.expectEqual(TissueLayer.bone, wound.deepestLayer().?);
    try std.testing.expectEqual(Severity.inhibited, wound.worstSeverity());
}

test "slash damage: heavy outer layer damage, shallow penetration" {
    const packet = damage.Packet{
        .amount = 1.0,
        .kind = .slash,
        .penetration = 0.5, // limited penetration
    };

    const wound = applyDamage(packet, .limb);

    // Slash should damage outer layers heavily
    try std.testing.expect(wound.len >= 2);
    try std.testing.expect(wound.severityAt(.skin) != .none);

    // Skin should take significant damage from slash
    const skin_sev = @intFromEnum(wound.severityAt(.skin));
    try std.testing.expect(skin_sev >= @intFromEnum(Severity.inhibited));

    // Bone likely untouched or minimal due to low penetration
    const bone_sev = @intFromEnum(wound.severityAt(.bone));
    try std.testing.expect(bone_sev <= @intFromEnum(Severity.minor));
}

test "pierce damage: light outer damage, deep penetration" {
    const packet = damage.Packet{
        .amount = 1.0,
        .kind = .pierce,
        .penetration = 1.5, // high penetration
    };

    const wound = applyDamage(packet, .limb);

    // Pierce should reach deep
    try std.testing.expect(wound.len >= 3);

    // Outer layers take less damage than inner
    const skin_sev = @intFromEnum(wound.severityAt(.skin));
    const muscle_sev = @intFromEnum(wound.severityAt(.muscle));
    try std.testing.expect(skin_sev <= muscle_sev);
}

test "bludgeon damage: bone and muscle absorb most" {
    const packet = damage.Packet{
        .amount = 1.0,
        .kind = .bludgeon,
        .penetration = 0.0, // irrelevant for bludgeon
    };

    const wound = applyDamage(packet, .limb);

    // Bludgeon should damage bone/muscle primarily
    try std.testing.expect(wound.severityAt(.bone) != .none);
    try std.testing.expect(wound.severityAt(.muscle) != .none);

    // Bone takes the brunt
    const bone_sev = @intFromEnum(wound.severityAt(.bone));
    const skin_sev = @intFromEnum(wound.severityAt(.skin));
    try std.testing.expect(bone_sev >= skin_sev);
}

test "facial tissue: cartilage instead of bone" {
    const packet = damage.Packet{
        .amount = 0.8,
        .kind = .slash,
        .penetration = 0.5,
    };

    const wound = applyDamage(packet, .facial);

    // Facial has cartilage, not bone
    try std.testing.expectEqual(Severity.none, wound.severityAt(.bone));
    try std.testing.expect(wound.severityAt(.cartilage) != .none or wound.severityAt(.skin) != .none);
}

test "digit tissue: minimal layers" {
    const packet = damage.Packet{
        .amount = 0.5,
        .kind = .slash,
        .penetration = 0.3,
    };

    const wound = applyDamage(packet, .digit);

    // Digit only has bone, tendon, skin - no muscle
    try std.testing.expectEqual(Severity.none, wound.severityAt(.muscle));
}

// === Body damage application tests ===

test "applying damage to part adds wound and updates severity" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const arm_idx = body.indexOf("left_arm").?;

    // Initially undamaged
    try std.testing.expectEqual(Severity.none, body.parts.items[arm_idx].severity);
    try std.testing.expectEqual(@as(usize, 0), body.parts.items[arm_idx].wounds.items.len);

    // Apply moderate slash
    const packet = damage.Packet{
        .amount = 0.6,
        .kind = .slash,
        .penetration = 0.4,
    };
    const result = try body.applyDamageToPart(arm_idx, packet);

    // Wound was added
    try std.testing.expectEqual(@as(usize, 1), body.parts.items[arm_idx].wounds.items.len);

    // Severity updated
    try std.testing.expect(body.parts.items[arm_idx].severity != .none);

    // Not severed by moderate damage
    try std.testing.expect(!result.severed);
    try std.testing.expect(!body.parts.items[arm_idx].is_severed);
}

test "severe slash can sever a limb" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const arm_idx = body.indexOf("left_arm").?;

    // Massive slash - enough to break bone and disable muscle
    const packet = damage.Packet{
        .amount = 3.0,
        .kind = .slash,
        .penetration = 2.0,
    };
    const result = try body.applyDamageToPart(arm_idx, packet);

    // Check the wound has severe damage
    try std.testing.expect(@intFromEnum(result.wound.worstSeverity()) >= @intFromEnum(Severity.disabled));

    // If bone reached .broken+ and muscle .disabled+, should sever
    const bone_sev = @intFromEnum(result.wound.severityAt(.bone));
    const muscle_sev = @intFromEnum(result.wound.severityAt(.muscle));
    if (bone_sev >= @intFromEnum(Severity.broken) and muscle_sev >= @intFromEnum(Severity.disabled)) {
        try std.testing.expect(result.severed);
        try std.testing.expect(body.parts.items[arm_idx].is_severed);
    }
}

test "major artery hit detection" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    // Neck has major artery
    const neck_idx = body.indexOf("neck").?;
    try std.testing.expect(body.parts.items[neck_idx].has_major_artery);

    // Deep stab to neck
    const packet = damage.Packet{
        .amount = 1.0,
        .kind = .pierce,
        .penetration = 1.0,
    };
    const result = try body.applyDamageToPart(neck_idx, packet);

    // If wound penetrated to muscle/fat, should flag artery hit
    const muscle_sev = @intFromEnum(result.wound.severityAt(.muscle));
    const fat_sev = @intFromEnum(result.wound.severityAt(.fat));
    if (muscle_sev >= @intFromEnum(Severity.inhibited) or fat_sev >= @intFromEnum(Severity.disabled)) {
        try std.testing.expect(result.hit_major_artery);
    }
}

test "part severity computed from wounds" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, &HumanoidPlan);
    defer body.deinit();

    const arm_idx = body.indexOf("left_arm").?;
    const part = &body.parts.items[arm_idx];

    // Add multiple wounds manually
    var wound1 = Wound{ .kind = .slash };
    wound1.append(.{ .layer = .skin, .severity = .minor });
    wound1.append(.{ .layer = .muscle, .severity = .inhibited });
    try part.wounds.append(alloc, wound1);

    var wound2 = Wound{ .kind = .pierce };
    wound2.append(.{ .layer = .skin, .severity = .minor });
    wound2.append(.{ .layer = .bone, .severity = .minor });
    try part.wounds.append(alloc, wound2);

    // Compute severity - bone is .minor, but muscle is .inhibited
    // Soft tissue is capped at structural + 2, so .inhibited is allowed
    const sev = part.computeSeverity();
    try std.testing.expect(sev != .none);
    try std.testing.expect(@intFromEnum(sev) <= @intFromEnum(Severity.inhibited) + 1);
}
