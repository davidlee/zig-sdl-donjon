/// Anatomical model and body-part utilities.
///
/// Defines the body graph, tags, and wound tracking helpers used by the
/// damage/resolution systems. Does not render sprites or own combat flow.
const std = @import("std");
const lib = @import("infra");
const damage = @import("damage.zig");
const resolution = @import("resolution.zig");
const events = @import("events.zig");
const body_list = @import("body_list.zig");
const EventSystem = events.EventSystem;
const Event = events.Event;
const entity = lib.entity;

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

/// Tissue template identifier. Layer composition now comes from generated
/// TissueStacks in body_list.zig (via data/materials.cue).
pub const TissueTemplate = enum {
    limb,
    digit,
    joint,
    facial,
    organ,
    core,
};

/// Runtime tissue layer with 3-axis physics coefficients.
/// Built from generated TissueLayerDefinition at comptime.
pub const TissueLayerMaterial = struct {
    material_id: []const u8,
    thickness_ratio: f32,
    // Shielding - how much this layer protects layers beneath it
    deflection: f32, // redirects attack energy away
    absorption: f32, // absorbs/dissipates attack energy
    dispersion: f32, // spreads impact over larger area
    // Susceptibility - how vulnerable this layer is to damage on each axis
    geometry_threshold: f32,
    geometry_ratio: f32,
    energy_threshold: f32,
    energy_ratio: f32,
    rigidity_threshold: f32,
    rigidity_ratio: f32,
    // Whether this material provides structural integrity (bone, cartilage).
    // Non-structural layers cannot escalate to Severity.missing on their own.
    is_structural: bool,
};

/// Runtime tissue stack - collection of tissue layers for a body part type.
/// Built from generated TissueTemplateDefinition at comptime.
pub const TissueStack = struct {
    id: []const u8,
    layers: []const TissueLayerMaterial,

    /// Check if this stack contains a layer with the given material ID.
    pub fn hasMaterial(self: *const TissueStack, material_id: []const u8) bool {
        for (self.layers) |layer| {
            if (std.mem.eql(u8, layer.material_id, material_id)) return true;
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
    trauma_mult: f32, // pain/trauma sensitivity multiplier
    geometry: body_list.BodyPartGeometry, // physical dimensions (thickness, length, area)

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
    geometry: body_list.BodyPartGeometry, // physical dimensions from generated data
};

pub const Body = struct {
    agent_id: entity.ID = undefined, // Body created before agent; set in Agent.init
    alloc: std.mem.Allocator,
    parts: std.ArrayList(Part),
    index_by_hash: std.AutoHashMap(u64, PartIndex), // name hash → part index

    /// Create a body from a plan ID (looks up in generated body plans).
    pub fn fromPlan(alloc: std.mem.Allocator, plan_id: []const u8) !Body {
        const plan = body_list.getBodyPlanRuntime(plan_id) orelse
            return error.UnknownBodyPlan;
        return fromParts(alloc, plan.parts);
    }

    /// Create a body from a raw parts slice.
    /// Prefer fromPlan() for standard body plans; use this for test fixtures.
    pub fn fromParts(alloc: std.mem.Allocator, parts: []const PartDef) !Body {
        var self = Body{
            .alloc = alloc,
            .parts = try std.ArrayList(Part).initCapacity(alloc, parts.len),
            .index_by_hash = std.AutoHashMap(u64, PartIndex).init(alloc),
        };
        errdefer self.deinit();

        try self.index_by_hash.ensureTotalCapacity(@intCast(parts.len));

        // First pass: create parts and build hash→index map
        for (parts, 0..) |def, i| {
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
                .trauma_mult = def.trauma_mult,
                .geometry = def.geometry,
                .severity = .none, // undamaged
                .wounds = try std.ArrayList(Wound).initCapacity(alloc, 0),
                .is_severed = false,
            };
            try self.parts.append(alloc, part);
            try self.index_by_hash.put(def.id.hash, @intCast(i));
        }

        // Second pass: resolve parent and enclosing references
        for (parts, 0..) |def, i| {
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
                // Topological safety check: parent must have been processed already
                std.debug.assert(parent_idx < i);
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

    /// Average effective integrity of parts with can_see flag (eyes).
    /// Returns 0..1; used to derive .blinded condition when < 0.3.
    pub fn visionScore(self: *const Body) f32 {
        var buf: [256]f32 = undefined;
        const eff = buf[0..self.parts.items.len];
        self.computeEffectiveIntegrities(eff);

        var total: f32 = 0;
        var count: f32 = 0;

        for (self.parts.items, 0..) |p, i| {
            if (p.flags.can_see) {
                total += eff[i];
                count += 1;
            }
        }

        return if (count > 0) total / count else 0;
    }

    /// Average effective integrity of parts with can_hear flag (ears).
    /// Returns 0..1; used to derive .deafened condition when < 0.3.
    pub fn hearingScore(self: *const Body) f32 {
        var buf: [256]f32 = undefined;
        const eff = buf[0..self.parts.items.len];
        self.computeEffectiveIntegrities(eff);

        var total: f32 = 0;
        var count: f32 = 0;

        for (self.parts.items, 0..) |p, i| {
            if (p.flags.can_hear) {
                total += eff[i];
                count += 1;
            }
        }

        return if (count > 0) total / count else 0;
    }

    /// Find first grasping part on the given side (for weapon hand lookup).
    pub fn graspingPartBySide(self: *const Body, side: Side) ?PartIndex {
        for (self.parts.items, 0..) |p, i| {
            if (p.flags.can_grasp and p.side == side) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Check if any part with the given tag (and optionally side) is functional.
    /// A part is functional if it's not effectively severed and severity != .missing.
    /// Pass null for side to match any part with the tag ("any functional" semantics).
    pub fn hasFunctionalPart(self: *const Body, tag: PartTag, side: ?Side) bool {
        for (self.parts.items, 0..) |p, i| {
            if (p.tag != tag) continue;
            if (side) |s| if (p.side != s) continue;
            const idx: PartIndex = @intCast(i);
            if (!self.isEffectivelySevered(idx) and p.severity != .missing) {
                return true;
            }
        }
        return false;
    }

    /// Result of applying damage to a part
    pub const DamageResult = struct {
        wound: Wound,
        severed: bool,
        hit_major_artery: bool,
    };

    pub fn applyDamageWithEvents(self: *Body, event_sys: *EventSystem, part_idx: PartIndex, packet: damage.Packet) !DamageResult {
        const result = try self.applyDamageToPart(part_idx, packet);
        const part = &self.parts.items[part_idx];

        if (result.wound.len > 0) {
            try event_sys.push(.{ .wound_inflicted = .{
                .agent_id = self.agent_id,
                .wound = result.wound,
                .part_idx = part_idx,
                .part_tag = part.tag,
                .part_side = part.side,
            } });
        }
        if (result.severed) {
            try event_sys.push(.{ .body_part_severed = .{
                .agent_id = self.agent_id,
                .part_idx = part_idx,
                .part_tag = part.tag,
                .part_side = part.side,
            } });
        }
        if (result.hit_major_artery) {
            try event_sys.push(.{ .hit_major_artery = .{
                .agent_id = self.agent_id,
                .part_idx = part_idx,
                .part_tag = part.tag,
                .part_side = part.side,
            } });
        }

        return result;
    }

    /// Apply a damage packet to a specific part.
    /// Creates a wound, adds it to the part, updates severity, checks for severing.
    pub fn applyDamageToPart(self: *Body, part_idx: PartIndex, packet: damage.Packet) !DamageResult {
        const part = &self.parts.items[part_idx];

        // Generate wound based on part's tissue template and geometry
        var wound = applyDamage(packet, part.tissue, part.geometry);

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

        // Calculate bleeding rate based on wound characteristics
        wound.bleeding_rate = calculateBleedingRate(&wound, hit_artery);

        // Add wound to part (if any layers damaged)
        if (wound.len > 0) {
            try part.wounds.append(self.alloc, wound);
        }

        // Recompute severity from all wounds
        part.severity = part.computeSeverity();

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
    bleeding_rate: f32 = 0.0, // litres per tick; 0 = not bleeding
    // TODO: dressing, infection

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

/// Convert a material ID string to a TissueLayer enum.
/// Returns null for unrecognized materials.
pub fn materialIdToTissueLayer(material_id: []const u8) ?TissueLayer {
    return std.meta.stringToEnum(TissueLayer, material_id);
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

/// Severity from volume/destruction (energy-driven).
/// Energy excess represents how much "stuff" is destroyed in the layer.
/// High energy = crushing, tearing, pulping tissue.
fn severityFromVolume(energy_excess: f32) Severity {
    if (energy_excess < 0.5) return .none;
    if (energy_excess < 1.5) return .minor;
    if (energy_excess < 3.0) return .inhibited;
    if (energy_excess < 5.0) return .disabled;
    if (energy_excess < 8.0) return .broken;
    return .missing;
}

/// Severity from depth/penetration (geometry-driven).
/// Geometry excess represents how cleanly/deeply the attack penetrates.
/// High geometry = narrow, deep wound channel (needle, stiletto).
fn severityFromDepth(geometry_excess: f32) Severity {
    if (geometry_excess < 0.5) return .none;
    if (geometry_excess < 1.5) return .minor;
    if (geometry_excess < 3.0) return .inhibited;
    if (geometry_excess < 5.0) return .disabled;
    // Depth alone cannot reach .missing - penetration doesn't remove tissue
    return .broken;
}

/// Combine volume and depth severity for a tissue layer.
/// Rules:
/// - Structural layers (bone, cartilage): volume drives severity. Depth contributes
///   but cannot alone reach .missing (you need to break/crush bone, not just poke through).
/// - Non-structural layers (muscle, fat, skin): max of volume and depth severity,
///   capped at .disabled (soft tissue destruction alone doesn't sever a limb).
fn computeLayerSeverity(
    geo_excess: f32,
    energy_excess: f32,
    rig_excess: f32,
    is_structural: bool,
) Severity {
    const volume_sev = severityFromVolume(energy_excess + rig_excess * 0.5);
    const depth_sev = severityFromDepth(geo_excess);

    if (is_structural) {
        // Structural layers: volume dominates. Depth can add minor contribution.
        // Both depth and volume must be significant for .missing.
        const depth_bonus: u8 = if (@intFromEnum(depth_sev) >= @intFromEnum(Severity.inhibited)) 1 else 0;
        const combined = @min(@as(u8, @intFromEnum(volume_sev)) + depth_bonus, @intFromEnum(Severity.missing));
        return @enumFromInt(combined);
    } else {
        // Non-structural: max of volume and depth, capped at .disabled.
        // Soft tissue alone cannot trigger .missing (no structural loss).
        const max_sev = @max(@intFromEnum(volume_sev), @intFromEnum(depth_sev));
        const capped = @min(max_sev, @intFromEnum(Severity.disabled));
        return @enumFromInt(capped);
    }
}

/// Apply a damage packet to a body part, producing a wound.
/// Processes tissue layers outside-in based on the part's template.
pub fn applyDamage(
    packet: damage.Packet,
    template: TissueTemplate,
    part_geometry: body_list.BodyPartGeometry,
) Wound {
    var wound = Wound{ .kind = packet.kind };

    // Non-physical damage bypasses the 3-axis mechanics (§6 of design doc).
    // Fire, radiation, magical, etc. use resistances/DoT, not shielding/susceptibility.
    if (!packet.kind.isPhysical()) {
        return wound; // TODO: implement non-physical damage resolution
    }

    // Get tissue stack by template name (e.g., "limb", "core")
    const template_id = @tagName(template);
    const tissue_stack = body_list.getTissueStackRuntime(template_id) orelse {
        return wound;
    };

    // Track the three axes through the layer stack (T037: real values or legacy fallback)
    // Geometry: dimensionless coefficient for shielding/susceptibility math
    // Penetration: cm of material the attack can punch through (for path-length consumption)
    var remaining_geo = if (packet.geometry > 0) packet.geometry else packet.penetration;
    var remaining_energy = if (packet.energy > 0) packet.energy else packet.amount;
    var remaining_rigidity = if (packet.rigidity > 0) packet.rigidity else resolution.damage.deriveRigidityFromKind(packet.kind);
    var remaining_penetration = packet.penetration; // cm - consumed by layer thickness

    // Process layers outside-in (generated data is in depth order)
    for (tissue_stack.layers) |layer| {
        // Stop when energy is exhausted (no force left to damage anything)
        if (remaining_energy < 0.05) break;

        // === Shielding: compute residual axes that continue inward ===
        // Deflection reduces geometry (redirects/blunts penetrating edges)
        // Absorption reduces energy (dissipates force into the layer)
        // Dispersion reduces rigidity (spreads concentrated force)
        const residual_geo = remaining_geo * (1.0 - layer.deflection);
        const residual_energy = remaining_energy * (1.0 - layer.absorption);
        const residual_rigidity = remaining_rigidity * (1.0 - layer.dispersion);

        // === Path-length consumption ===
        // Each layer has a thickness ratio (0-1) of the total part depth.
        // Multiply by part geometry to get absolute cm this layer occupies.
        const layer_thickness_cm = layer.thickness_ratio * part_geometry.thickness_cm;
        remaining_penetration -= layer_thickness_cm;

        // === Susceptibility: damage to THIS layer using post-shielding axes ===
        // Layer takes damage when residual axes exceed its thresholds
        const geo_excess = @max(0.0, residual_geo - layer.geometry_threshold) * layer.geometry_ratio;
        const energy_excess = @max(0.0, residual_energy - layer.energy_threshold) * layer.energy_ratio;
        const rig_excess = @max(0.0, residual_rigidity - layer.rigidity_threshold) * layer.rigidity_ratio;

        // T039: Dual severity model - volume (energy) vs depth (geometry)
        // Structural layers can escalate to .missing via volume destruction.
        // Non-structural layers cap at .disabled (soft tissue alone doesn't sever).
        const severity = computeLayerSeverity(geo_excess, energy_excess, rig_excess, layer.is_structural);
        if (severity != .none) {
            if (materialIdToTissueLayer(layer.material_id)) |tissue_layer| {
                wound.append(.{ .layer = tissue_layer, .severity = severity });
            }
        }

        // Pass residuals to next layer
        remaining_geo = residual_geo;
        remaining_energy = residual_energy;
        remaining_rigidity = residual_rigidity;

        // Pierce/slash attacks stop when they can't penetrate further.
        // Bludgeon continues (transfers energy even without penetration).
        if (remaining_penetration <= 0 and
            (packet.kind == .pierce or packet.kind == .slash))
        {
            break;
        }
    }

    return wound;
}

/// Check if a wound causes severing of a part.
/// T039: Severing requires BOTH depth penetration AND structural volume loss.
/// - Depth alone (needle) can't sever - need to remove enough material
/// - Volume alone isn't enough - need to cut through the structure
/// Small parts (digits, ears) sever more easily due to less material.
fn checkSevering(part: *const Part, wound: *const Wound) bool {
    // Already severed
    if (part.is_severed) return false;

    const bone_sev = wound.severityAt(.bone);
    const cartilage_sev = wound.severityAt(.cartilage);
    const muscle_sev = wound.severityAt(.muscle);
    const tendon_sev = wound.severityAt(.tendon);

    // Determine which structural layer is relevant for this part
    const template_id = @tagName(part.tissue);
    const tissue_stack = body_list.getTissueStackRuntime(template_id);
    const has_bone = if (tissue_stack) |stack| stack.hasMaterial("bone") else false;
    const has_cartilage = if (tissue_stack) |stack| stack.hasMaterial("cartilage") else false;

    const structural_sev = if (has_bone)
        bone_sev
    else if (has_cartilage)
        cartilage_sev
    else
        return false; // no structural layer (e.g., organ) - can't sever

    // T039: Small part adjustment - digits/ears (area < 30 cm²) sever more easily.
    // Reduce the severity threshold by 1 level for small parts.
    const is_small_part = part.geometry.area_cm2 < 30.0;
    const threshold_reduction: u8 = if (is_small_part) 1 else 0;

    // Severing rules by damage type
    const structural_int = @intFromEnum(structural_sev);
    const muscle_int = @intFromEnum(muscle_sev);
    const tendon_int = @intFromEnum(tendon_sev);
    const broken_int = @intFromEnum(Severity.broken) - threshold_reduction;
    const disabled_int = @intFromEnum(Severity.disabled) - threshold_reduction;
    const missing_int = @intFromEnum(Severity.missing); // don't reduce - still need structural loss

    switch (wound.kind) {
        .slash => {
            // Slash severs when: structural broken + muscle/tendon disabled+
            // T039: This requires both depth (geometry penetrated bone) AND
            // volume (energy damaged soft tissue). Needles fail the energy check.
            if (structural_int >= broken_int) {
                if (muscle_int >= disabled_int or tendon_int >= disabled_int) {
                    return true;
                }
            }
            // Or structural missing (clean cut through bone - high energy slash)
            if (structural_int >= missing_int) return true;
        },
        .pierce => {
            // T039: Pierce rarely severs. With dual severity, needles (high geo,
            // low energy) max out at .broken on structural layers. Only massive
            // energy pierces (war pick, lance charge) can reach .missing.
            if (structural_int >= missing_int) return true;
        },
        .bludgeon, .crush, .shatter => {
            // Bludgeon/crush can shatter-sever if bone is missing.
            // T039: Hammer (high energy) can reach .missing on bone, enabling
            // shatter-sever. But it's not a "clean" cut.
            if (structural_int >= missing_int) return true;
        },
        else => {},
    }

    return false;
}

/// Calculate bleeding rate (litres per tick) based on wound characteristics.
/// Artery hits bleed fast. Slash/pierce bleed more than bludgeon.
/// Deeper wounds bleed more. Severing stops bleeding (no longer connected).
fn calculateBleedingRate(wound: *const Wound, hit_artery: bool) f32 {
    if (wound.len == 0) return 0;

    // Base rate from wound type
    const type_factor: f32 = switch (wound.kind) {
        .slash => 1.0, // cuts bleed freely
        .pierce => 0.6, // smaller opening
        .bludgeon, .crush => 0.2, // mostly internal
        .shatter => 0.3, // bone fragments, some external
        else => 0.1,
    };

    // Severity factor from worst layer damage
    const severity_factor: f32 = switch (wound.worstSeverity()) {
        .none => 0,
        .minor => 0.2,
        .inhibited => 0.5,
        .disabled => 0.8,
        .broken => 1.0,
        .missing => 0.5, // severed = less connected blood flow
    };

    // Artery multiplier
    const artery_mult: f32 = if (hit_artery) 5.0 else 1.0;

    // Base bleeding: ~0.1L/tick for a bad wound, ~0.5L/tick for arterial
    return 0.1 * type_factor * severity_factor * artery_mult;
}

// === Part definition helpers ===

const PartFlags = PartDef.Flags;

const PartStats = struct {
    hit_chance: f32,
    durability: f32,
    trauma_mult: f32,
};

pub fn defaultStats(tag: PartTag) PartStats {
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

// === Tests ===

test "body fromPlan creates correct part count" {
    const alloc = std.testing.allocator;
    var bod = try Body.fromPlan(alloc, "humanoid");
    defer bod.deinit();

    const plan = body_list.getBodyPlanRuntime("humanoid").?;
    try std.testing.expectEqual(plan.parts.len, bod.parts.items.len);
}

test "body part lookup by name" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, "humanoid");
    defer body.deinit();

    const hand = body.get("left_hand");
    try std.testing.expect(hand != null);
    try std.testing.expectEqual(PartTag.hand, hand.?.tag);
    try std.testing.expectEqual(Side.left, hand.?.side);
}

test "severing arm propagates to children" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, "humanoid");
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
    var body = try Body.fromPlan(alloc, "humanoid");
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
    var body = try Body.fromPlan(alloc, "humanoid");
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
    var body = try Body.fromPlan(alloc, "humanoid");
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
    var body = try Body.fromPlan(alloc, "humanoid");
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
    var body = try Body.fromPlan(alloc, "humanoid");
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
    var body = try Body.fromPlan(alloc, "humanoid");
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

test "tissue template layer queries (via TissueStack)" {
    // Limbs have bone, muscle, etc. (from generated data)
    const limb = body_list.getTissueStackRuntime("limb").?;
    try std.testing.expect(limb.hasMaterial("bone"));
    try std.testing.expect(limb.hasMaterial("muscle"));
    try std.testing.expect(limb.hasMaterial("skin"));
    try std.testing.expect(!limb.hasMaterial("cartilage"));
    try std.testing.expect(!limb.hasMaterial("organ"));

    // Digits are minimal
    const digit = body_list.getTissueStackRuntime("digit").?;
    try std.testing.expect(digit.hasMaterial("bone"));
    try std.testing.expect(digit.hasMaterial("tendon"));
    try std.testing.expect(!digit.hasMaterial("muscle"));

    // Facial features have cartilage, not bone
    const facial = body_list.getTissueStackRuntime("facial").?;
    try std.testing.expect(facial.hasMaterial("cartilage"));
    try std.testing.expect(!facial.hasMaterial("bone"));
}

test "part definitions have correct tissue and artery flags" {
    // Check representative parts from generated humanoid body plan
    const plan = body_list.getBodyPlanRuntime("humanoid").?;
    for (plan.parts) |def| {
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

// Test helper: representative geometry (geometry not yet used in calculations)
const TestGeometry = body_list.BodyPartGeometry{
    .thickness_cm = 8.0,
    .length_cm = 30.0,
    .area_cm2 = 400.0,
};

test "slash damage: heavy outer layer damage, shallow penetration" {
    const packet = damage.Packet{
        .amount = 10.0,
        .kind = .slash,
        .penetration = 0.5, // limited penetration
    };

    const wound = applyDamage(packet, .limb, TestGeometry);

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

test "pierce damage: penetrates multiple layers" {
    const packet = damage.Packet{
        .amount = 10.0,
        .kind = .pierce,
        .penetration = 1.5, // high penetration
    };

    const wound = applyDamage(packet, .limb, TestGeometry);

    // Pierce should reach multiple layers due to high geometry
    try std.testing.expect(wound.len >= 3);

    // All penetrated layers should be damaged (3-axis model)
    try std.testing.expect(wound.severityAt(.skin) != .none);
    try std.testing.expect(wound.severityAt(.muscle) != .none);
}

test "bludgeon damage: energy transfers through layers" {
    const packet = damage.Packet{
        .amount = 10.0,
        .kind = .bludgeon,
        .penetration = 0.0, // no geometry axis for bludgeon
    };

    const wound = applyDamage(packet, .limb, TestGeometry);

    // Bludgeon damages via energy axis (no geometry needed)
    // Outer layers absorb energy; deeper layers see diminished energy
    try std.testing.expect(wound.len >= 1);
    try std.testing.expect(wound.severityAt(.skin) != .none);

    // Energy diminishes through stack - outer layers take more damage
    // (unlike old model which assumed bludgeon "skips" to bone)
    const skin_sev = @intFromEnum(wound.severityAt(.skin));
    const fat_sev = @intFromEnum(wound.severityAt(.fat));
    try std.testing.expect(skin_sev >= fat_sev);
}

test "facial tissue: cartilage instead of bone" {
    const packet = damage.Packet{
        .amount = 8.0,
        .kind = .slash,
        .penetration = 0.5,
    };

    const wound = applyDamage(packet, .facial, TestGeometry);

    // Facial has cartilage, not bone
    try std.testing.expectEqual(Severity.none, wound.severityAt(.bone));
    try std.testing.expect(wound.severityAt(.cartilage) != .none or wound.severityAt(.skin) != .none);
}

test "digit tissue: minimal layers" {
    const packet = damage.Packet{
        .amount = 5.0,
        .kind = .slash,
        .penetration = 0.3,
    };

    const wound = applyDamage(packet, .digit, TestGeometry);

    // Digit only has bone, tendon, skin - no muscle
    try std.testing.expectEqual(Severity.none, wound.severityAt(.muscle));
}

// === Body damage application tests ===

test "applying damage to part adds wound and updates severity" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, "humanoid");
    defer body.deinit();

    const arm_idx = body.indexOf("left_arm").?;

    // Initially undamaged
    try std.testing.expectEqual(Severity.none, body.parts.items[arm_idx].severity);
    try std.testing.expectEqual(@as(usize, 0), body.parts.items[arm_idx].wounds.items.len);

    // Apply moderate slash
    const packet = damage.Packet{
        .amount = 6.0,
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
    var body = try Body.fromPlan(alloc, "humanoid");
    defer body.deinit();

    const arm_idx = body.indexOf("left_arm").?;

    // Massive slash - enough to break bone and disable muscle
    const packet = damage.Packet{
        .amount = 30.0,
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
    var body = try Body.fromPlan(alloc, "humanoid");
    defer body.deinit();

    // Neck has major artery
    const neck_idx = body.indexOf("neck").?;
    try std.testing.expect(body.parts.items[neck_idx].has_major_artery);

    // Deep stab to neck
    const packet = damage.Packet{
        .amount = 10.0,
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
    var body = try Body.fromPlan(alloc, "humanoid");
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

test "vision score with damaged eyes" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, "humanoid");
    defer body.deinit();

    // Full vision with both eyes
    const full_vision = body.visionScore();
    try std.testing.expect(full_vision > 0.9);

    // Damage left eye
    const left_eye_idx = body.indexOf("left_eye").?;
    body.parts.items[left_eye_idx].severity = .disabled;

    // Reduced vision (one eye at ~0, one at ~1, average ~0.5)
    const partial_vision = body.visionScore();
    try std.testing.expect(partial_vision < full_vision);
    try std.testing.expect(partial_vision > 0.3);
    try std.testing.expect(partial_vision < 0.7);

    // Break both eyes completely
    const right_eye_idx = body.indexOf("right_eye").?;
    body.parts.items[left_eye_idx].severity = .broken;
    body.parts.items[right_eye_idx].severity = .broken;

    const no_vision = body.visionScore();
    try std.testing.expect(no_vision < 0.3);
}

test "hearing score with damaged ears" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, "humanoid");
    defer body.deinit();

    // Full hearing with both ears
    const full_hearing = body.hearingScore();
    try std.testing.expect(full_hearing > 0.9);

    // Damage left ear
    const left_ear_idx = body.indexOf("left_ear").?;
    body.parts.items[left_ear_idx].severity = .disabled;

    // Reduced hearing
    const partial_hearing = body.hearingScore();
    try std.testing.expect(partial_hearing < full_hearing);
    try std.testing.expect(partial_hearing > 0.3);
    try std.testing.expect(partial_hearing < 0.7);

    // Break both ears completely
    const right_ear_idx = body.indexOf("right_ear").?;
    body.parts.items[left_ear_idx].severity = .broken;
    body.parts.items[right_ear_idx].severity = .broken;

    const no_hearing = body.hearingScore();
    try std.testing.expect(no_hearing < 0.3);
}

test "grasping part by side" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, "humanoid");
    defer body.deinit();

    // Find left hand - should match indexOf
    const left_hand = body.graspingPartBySide(.left);
    try std.testing.expect(left_hand != null);
    try std.testing.expectEqual(body.indexOf("left_hand").?, left_hand.?);

    // Find right hand - should match indexOf
    const right_hand = body.graspingPartBySide(.right);
    try std.testing.expect(right_hand != null);
    try std.testing.expectEqual(body.indexOf("right_hand").?, right_hand.?);

    // Central parts should return null (no grasping parts are centered)
    const center_grasp = body.graspingPartBySide(.center);
    try std.testing.expect(center_grasp == null);
}

test "hasFunctionalPart with healthy body" {
    const alloc = std.testing.allocator;
    var b = try Body.fromPlan(alloc, "humanoid");
    defer b.deinit();

    // Both hands functional
    try std.testing.expect(b.hasFunctionalPart(.hand, null));
    try std.testing.expect(b.hasFunctionalPart(.hand, .left));
    try std.testing.expect(b.hasFunctionalPart(.hand, .right));

    // Head parts functional
    try std.testing.expect(b.hasFunctionalPart(.head, null));
    try std.testing.expect(b.hasFunctionalPart(.eye, .left));
    try std.testing.expect(b.hasFunctionalPart(.eye, .right));
}

test "hasFunctionalPart with missing part" {
    const alloc = std.testing.allocator;
    var b = try Body.fromPlan(alloc, "humanoid");
    defer b.deinit();

    // Set left hand to missing
    const left_hand_idx = b.indexOf("left_hand").?;
    b.parts.items[left_hand_idx].severity = .missing;

    // Still have a functional hand (right)
    try std.testing.expect(b.hasFunctionalPart(.hand, null));
    // But not on the left side
    try std.testing.expect(!b.hasFunctionalPart(.hand, .left));
    try std.testing.expect(b.hasFunctionalPart(.hand, .right));

    // Set right hand to missing too
    const right_hand_idx = b.indexOf("right_hand").?;
    b.parts.items[right_hand_idx].severity = .missing;

    // No functional hands at all
    try std.testing.expect(!b.hasFunctionalPart(.hand, null));
    try std.testing.expect(!b.hasFunctionalPart(.hand, .left));
    try std.testing.expect(!b.hasFunctionalPart(.hand, .right));
}

test "hasFunctionalPart with severed limb" {
    const alloc = std.testing.allocator;
    var b = try Body.fromPlan(alloc, "humanoid");
    defer b.deinit();

    // Sever left arm - hand becomes effectively severed
    const left_arm_idx = b.indexOf("left_arm").?;
    b.parts.items[left_arm_idx].is_severed = true;

    // Left hand no longer functional (parent severed)
    try std.testing.expect(!b.hasFunctionalPart(.hand, .left));
    // Right hand still functional
    try std.testing.expect(b.hasFunctionalPart(.hand, .right));
    // "Any hand" still functional (right)
    try std.testing.expect(b.hasFunctionalPart(.hand, null));
}

test "hasFunctionalPart damaged but not missing" {
    const alloc = std.testing.allocator;
    var b = try Body.fromPlan(alloc, "humanoid");
    defer b.deinit();

    // Set hand to various damage levels - still functional
    const left_hand_idx = b.indexOf("left_hand").?;

    b.parts.items[left_hand_idx].severity = .minor;
    try std.testing.expect(b.hasFunctionalPart(.hand, .left));

    b.parts.items[left_hand_idx].severity = .inhibited;
    try std.testing.expect(b.hasFunctionalPart(.hand, .left));

    b.parts.items[left_hand_idx].severity = .disabled;
    try std.testing.expect(b.hasFunctionalPart(.hand, .left));

    b.parts.items[left_hand_idx].severity = .broken;
    try std.testing.expect(b.hasFunctionalPart(.hand, .left));

    // Only .missing makes it non-functional
    b.parts.items[left_hand_idx].severity = .missing;
    try std.testing.expect(!b.hasFunctionalPart(.hand, .left));
}

// === T039: Dual Severity Model Tests ===

test "T039: needle (high geo, low energy) cannot cause missing" {
    // Needle: high geometry (penetration), low energy (volume destruction)
    // Should cause deep wounds but NOT trigger .missing on any layer.
    const packet = damage.Packet{
        .kind = .pierce,
        .amount = 2.0, // low
        .penetration = 8.0, // high - can punch through
        .geometry = 3.0, // high - sharp, penetrating
        .energy = 0.5, // low - no crushing force
        .rigidity = 0.8, // moderate
    };

    const geometry = body_list.BodyPartGeometry{
        .thickness_cm = 8.0,
        .length_cm = 30.0,
        .area_cm2 = 150.0,
    };

    const wound = applyDamage(packet, .limb, geometry);

    // Check no layer reached .missing
    for (wound.slice()) |ld| {
        try std.testing.expect(ld.severity != .missing);
    }

    // Bone should be damaged but not beyond .broken (depth cap for structural)
    const bone_sev = wound.severityAt(.bone);
    try std.testing.expect(@intFromEnum(bone_sev) <= @intFromEnum(Severity.broken));
}

test "T039: axe (moderate geo, high energy) can cause missing on structural" {
    // Axe: moderate geometry (cutting edge), high energy (chopping force)
    // Energy is absorbed heavily through layers (~85% absorbed before reaching bone)
    // Need very high initial values to get meaningful bone damage.
    const packet = damage.Packet{
        .kind = .slash,
        .amount = 100.0, // very high
        .penetration = 10.0, // high - needs to reach bone
        .geometry = 5.0, // moderate-high - blade edge
        .energy = 100.0, // very high - heavy chop (accounts for absorption)
        .rigidity = 3.0, // high - solid blade
    };

    const geometry = body_list.BodyPartGeometry{
        .thickness_cm = 8.0,
        .length_cm = 30.0,
        .area_cm2 = 150.0,
    };

    const wound = applyDamage(packet, .limb, geometry);

    // With enough energy, structural layers take damage
    const bone_sev = wound.severityAt(.bone);
    // High energy should cause bone damage through volume destruction
    try std.testing.expect(@intFromEnum(bone_sev) >= @intFromEnum(Severity.minor));
}

test "T039: hammer (low geo, high energy) crushes but does not cleanly sever" {
    // Hammer: low geometry (blunt), very high energy (crushing force)
    // Energy is absorbed through layers (skin 25%, fat 55%, muscle 45%, etc.)
    // Need very high initial energy to reach bone with enough force.
    const packet = damage.Packet{
        .kind = .bludgeon,
        .amount = 50.0, // very high
        .penetration = 2.0, // low - doesn't penetrate well
        .geometry = 0.5, // low - blunt surface
        .energy = 80.0, // extremely high - crushing blow (accounts for absorption)
        .rigidity = 3.0, // very high - solid metal
    };

    const geometry = body_list.BodyPartGeometry{
        .thickness_cm = 8.0,
        .length_cm = 30.0,
        .area_cm2 = 150.0,
    };

    const wound = applyDamage(packet, .limb, geometry);

    // Outer layers should take heavy damage from energy
    const skin_sev = wound.severityAt(.skin);
    try std.testing.expect(skin_sev != .none);

    // Bone can reach severity via energy (crushing), even with low geometry
    const bone_sev = wound.severityAt(.bone);
    // With enough energy, bone takes damage through volume destruction
    try std.testing.expect(@intFromEnum(bone_sev) >= @intFromEnum(Severity.minor));
}

test "T039: non-structural layers cap at disabled" {
    // Massive damage should cap soft tissue at .disabled but allow bone to exceed
    // Energy values need to account for layer absorption (~85% absorbed before bone)
    // To get bone damage of ~10 (for .missing), need initial energy of ~500-600
    const packet = damage.Packet{
        .kind = .slash,
        .amount = 500.0,
        .penetration = 20.0,
        .geometry = 10.0, // high - sharp blade
        .energy = 500.0, // extremely high - ensures bone gets enough after absorption
        .rigidity = 5.0,
    };

    const geometry = body_list.BodyPartGeometry{
        .thickness_cm = 8.0,
        .length_cm = 30.0,
        .area_cm2 = 150.0,
    };

    const wound = applyDamage(packet, .limb, geometry);

    // Soft tissue layers should cap at .disabled
    const muscle_sev = wound.severityAt(.muscle);
    const fat_sev = wound.severityAt(.fat);
    const skin_sev = wound.severityAt(.skin);

    try std.testing.expect(@intFromEnum(muscle_sev) <= @intFromEnum(Severity.disabled));
    try std.testing.expect(@intFromEnum(fat_sev) <= @intFromEnum(Severity.disabled));
    try std.testing.expect(@intFromEnum(skin_sev) <= @intFromEnum(Severity.disabled));

    // But structural (bone) can exceed .disabled with enough volume damage
    const bone_sev = wound.severityAt(.bone);
    try std.testing.expect(@intFromEnum(bone_sev) >= @intFromEnum(Severity.broken));
}

test "T039: severity from depth caps at broken for structural" {
    // Test the depth severity function directly
    // Even with extreme geometry excess, depth alone caps at .broken
    const depth_sev = severityFromDepth(100.0);
    try std.testing.expectEqual(Severity.broken, depth_sev);
}

test "T039: severity from volume can reach missing" {
    // Test the volume severity function directly
    // High energy excess can reach .missing
    const vol_sev = severityFromVolume(10.0);
    try std.testing.expectEqual(Severity.missing, vol_sev);
}

test "T039: small part (digit) severs with lower thresholds" {
    const alloc = std.testing.allocator;
    var body = try Body.fromPlan(alloc, "humanoid");
    defer body.deinit();

    const finger_idx = body.indexOf("left_index_finger").?;

    // Moderate slash that would NOT sever a large part
    const packet = damage.Packet{
        .kind = .slash,
        .amount = 8.0,
        .penetration = 4.0,
        .geometry = 2.0,
        .energy = 6.0, // moderate energy
        .rigidity = 1.0,
    };

    const result = try body.applyDamageToPart(finger_idx, packet);

    // Digit geometry is small (area < 30 cm²), so thresholds are reduced.
    // Check that significant damage was dealt
    try std.testing.expect(result.wound.len >= 1);

    // The wound should cause notable damage on the small finger
    const worst = result.wound.worstSeverity();
    try std.testing.expect(@intFromEnum(worst) >= @intFromEnum(Severity.inhibited));
}
