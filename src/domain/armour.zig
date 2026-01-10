/// Armour data and resolution helpers.
///
/// Owns armour materials, durability, and how armour interacts with incoming
/// damage/conditions. Does not perform rendering or UI decisions.
const std = @import("std");
const lib = @import("infra");
const body = @import("body.zig");
const body_list = @import("body_list.zig");
const damage = @import("damage.zig");
const entity = lib.entity;
const events = @import("events.zig");
const inventory = @import("inventory.zig");
const random = @import("random.zig");
const world = @import("world.zig");

const Resistance = damage.Resistance;
const Vulnerability = damage.Vulnerability;

pub const Quality = enum {
    terrible,
    poor,
    common,
    excellent,
    masterwork,

    pub fn durabilityMult(self: Quality) f32 {
        return switch (self) {
            .terrible => 0.5,
            .poor => 0.75,
            .common => 1.0,
            .excellent => 1.25,
            .masterwork => 1.5,
        };
    }
};

/// Shape profile affects how material properties manifest in practice.
/// A quilted gambeson absorbs differently than solid plate of similar material.
pub const ShapeProfile = enum {
    solid, // rigid continuous surface (plate)
    mesh, // interlocking rings/links (mail)
    quilted, // layered padding (gambeson)
    laminar, // overlapping scales/bands
    composite, // mixed construction

    pub fn fromString(s: []const u8) ShapeProfile {
        if (std.mem.eql(u8, s, "solid")) return .solid;
        if (std.mem.eql(u8, s, "mesh")) return .mesh;
        if (std.mem.eql(u8, s, "quilted")) return .quilted;
        if (std.mem.eql(u8, s, "laminar")) return .laminar;
        if (std.mem.eql(u8, s, "composite")) return .composite;
        return .solid; // default
    }
};

/// Material properties using the 3-axis physics model.
///
/// Shielding coefficients (0-1) describe how the layer protects what's beneath:
/// - deflection: redirect/blunt penetrating edges before they enter
/// - absorption: soak energy into the layer's own structure
/// - dispersion: spread residual force across a larger area
///
/// Susceptibility (threshold + ratio per axis) describes how the layer itself
/// takes damage. Threshold is minimum to cause damage; ratio is multiplier
/// for excess.
pub const Material = struct {
    name: []const u8,
    quality: Quality = .common,

    // === Shielding (protects layers beneath) ===
    deflection: f32, // 0-1, chance to redirect/blunt geometry
    absorption: f32, // 0-1, fraction of energy soaked
    dispersion: f32, // 0-1, force spread to larger area

    // === Susceptibility (damage to this layer) ===
    geometry_threshold: f32,
    geometry_ratio: f32,
    energy_threshold: f32, // "energy" in design doc
    energy_ratio: f32,
    rigidity_threshold: f32,
    rigidity_ratio: f32,

    // === Shape modifiers ===
    shape: ShapeProfile = .solid,
    shape_dispersion_bonus: f32 = 0,
    shape_absorption_bonus: f32 = 0,

    // === Physical properties ===
    thickness: f32 = 0, // cm - material path that attack must cut through
    durability: f32 = 100, // base integrity for armour instances

    /// Effective deflection including shape bonus (clamped 0-1)
    pub fn effectiveDeflection(self: Material) f32 {
        return @min(1.0, @max(0.0, self.deflection));
    }

    /// Effective absorption including shape bonus (clamped 0-1)
    pub fn effectiveAbsorption(self: Material) f32 {
        return @min(1.0, @max(0.0, self.absorption + self.shape_absorption_bonus));
    }

    /// Effective dispersion including shape bonus (clamped 0-1)
    pub fn effectiveDispersion(self: Material) f32 {
        return @min(1.0, @max(0.0, self.dispersion + self.shape_dispersion_bonus));
    }
};

// coverage of a particular part by a particular material - or,
// how hard is it to get around the tough stuff with a lucky stab or a shiv in the kidneys?
pub const Totality = enum {
    // full-fit simple construction (gambeson, etc) with no secondary materials
    total,
    // as good as it gets. More fully articulated plates than a pixar film about anthropomorphic
    // kitchen utensils - only visor slits, armpits, etc admit any entry.
    intimidating,
    // a practical compromise, but with attention paid to the back and kidneys, calves, etc.
    comprehensive,
    // most of the bits that might get hit - as long as you're facing the right way.
    frontal,
    // concerningly optimistic, e.g. a miserly panel over the vitals
    minimal,

    /// Chance (0-1) that an attack finds a gap in this coverage
    pub fn gapChance(self: Totality) f32 {
        return switch (self) {
            .total => 0.0,
            .intimidating => 0.05,
            .comprehensive => 0.15,
            .frontal => 0.30,
            .minimal => 0.50,
        };
    }
};

/// Runtime coverage for a specific piece of armor on a specific part
const InstanceCoverage = struct {
    part_tag: body.PartTag,
    side: body.Side, // resolved at instantiation
    layer: inventory.Layer,
    totality: Totality,
    material: *const Material,
    integrity: f32, // current durability (0 = destroyed)
    // tags: ?[]const Tag, // TODO: enchantments, conditions (dented, rusted, etc)
};

/// Design-time coverage pattern - reusable across bodies
pub const PatternCoverage = struct {
    part_tags: []const body.PartTag,
    side: ?body.Side = null, // null = assigned on instantiation (e.g., "left pauldron")
    layer: inventory.Layer,
    totality: Totality,
};

pub const Pattern = struct {
    coverage: []const PatternCoverage,
};

// designed to be easily definable at comptime
pub const Template = struct {
    id: u64,
    name: []const u8,
    material: *const Material,
    pattern: *const Pattern,
};

/// A specific piece of armor with runtime state
pub const Instance = struct {
    name: []const u8,
    template_id: u64,
    id: entity.ID,
    coverage: []InstanceCoverage, // unpacked from template, tracks integrity per-part
    // tags: ?[]const Tag, // TODO: enchantments, conditions

    pub fn init(alloc: std.mem.Allocator, template: *const Template, side_assignment: ?body.Side) !Instance {
        // Count total entries (each part_tag becomes one InstanceCoverage)
        var total_entries: usize = 0;
        for (template.pattern.coverage) |pat_cov| {
            total_entries += pat_cov.part_tags.len;
        }

        const coverage = try alloc.alloc(InstanceCoverage, total_entries);
        errdefer alloc.free(coverage);

        const base_integrity = template.material.durability * template.material.quality.durabilityMult();

        var idx: usize = 0;
        for (template.pattern.coverage) |pat_cov| {
            // Resolve side: pattern-specified, or assigned at instantiation
            const resolved_side = pat_cov.side orelse side_assignment orelse body.Side.center;

            for (pat_cov.part_tags) |tag| {
                coverage[idx] = .{
                    .part_tag = tag,
                    .side = resolved_side,
                    .layer = pat_cov.layer,
                    .totality = pat_cov.totality,
                    .material = template.material,
                    .integrity = base_integrity,
                };
                idx += 1;
            }
        }

        return .{
            .name = template.name,
            .template_id = template.id,
            .id = .{ .index = 0, .generation = 0 }, // assigned by entity system
            .coverage = coverage,
        };
    }

    pub fn deinit(self: *Instance, alloc: std.mem.Allocator) void {
        alloc.free(self.coverage);
    }
};

/// Protection provided by a single armor layer
pub const LayerProtection = struct {
    material: *const Material,
    totality: Totality,
    integrity: *f32, // pointer back to Instance.coverage[].integrity for mutation
};

/// Runtime armor state for a specific body, optimized for combat lookups
pub const Stack = struct {
    alloc: std.mem.Allocator,
    // PartIndex → layers covering that part (indexed by inventory.Layer)
    coverage: std.AutoHashMap(body.PartIndex, [9]?LayerProtection),

    pub fn init(alloc: std.mem.Allocator) Stack {
        return .{
            .alloc = alloc,
            .coverage = std.AutoHashMap(body.PartIndex, [9]?LayerProtection).init(alloc),
        };
    }

    pub fn deinit(self: *Stack) void {
        self.coverage.deinit();
    }

    /// Rebuild stack from equipped armor instances for a specific body
    pub fn buildFromEquipped(self: *Stack, bod: *const body.Body, equipped: []const *Instance) !void {
        self.coverage.clearRetainingCapacity();

        for (equipped) |instance| {
            for (instance.coverage) |*cov| {
                // Resolve PartTag + Side → PartIndex using body's lookup
                const part_idx = resolvePartIndex(bod, cov.part_tag, cov.side) orelse continue;

                const entry = try self.coverage.getOrPut(part_idx);
                if (!entry.found_existing) {
                    entry.value_ptr.* = [_]?LayerProtection{null} ** 9;
                }

                const layer_idx = @intFromEnum(cov.layer);
                entry.value_ptr[layer_idx] = .{
                    .material = cov.material,
                    .totality = cov.totality,
                    .integrity = &cov.integrity,
                };
            }
        }
    }

    /// Get protection layers for a part, outer to inner (Cloak → Skin)
    pub fn getProtection(self: *const Stack, part_idx: body.PartIndex) [9]?LayerProtection {
        return self.coverage.get(part_idx) orelse [_]?LayerProtection{null} ** 9;
    }
};

/// Resolve PartTag + Side to PartIndex for a specific body
pub fn resolvePartIndex(bod: *const body.Body, tag: body.PartTag, side: body.Side) ?body.PartIndex {
    // Search for matching part - TODO: could precompute (tag,side) → index map
    for (bod.parts.items, 0..) |part, i| {
        if (part.tag == tag and part.side == side) {
            return @intCast(i);
        }
    }
    return null;
}

/// Result of armour absorbing damage
pub const AbsorptionResult = struct {
    remaining: damage.Packet, // damage that reached the body
    gap_found: bool, // attack bypassed armour entirely
    layers_hit: u8, // number of armour layers damaged
    deflected: bool, // shielding reduced attack to negligible (effectively blocked)
    deflected_at_layer: ?u8, // which layer blocked (if any)
    layers_destroyed: u8, // layers that hit 0 integrity this resolution
};

/// Fallback rigidity derivation for legacy packets that don't have axis values.
/// Used during migration from amount/penetration to geometry/energy/rigidity.
fn deriveRigidityFromKind(kind: damage.Kind) f32 {
    return switch (kind) {
        .pierce => 1.0,
        .slash => 0.7,
        .bludgeon => 0.8,
        .crush => 1.0,
        .shatter => 1.0,
        else => 0.0,
    };
}

/// Process a damage packet through armour layers, returning what reaches the body.
/// Mutates layer integrity as armour is damaged.
///
/// Uses 3-axis physics model:
/// - Geometry (penetration): reduced by deflection
/// - Momentum (amount): reduced by absorption
/// - Rigidity (from damage kind): affects susceptibility calculations
///
/// NOTE: For production use resolveThroughArmourWithEvents which uses World.drawRandom
/// and emits events. This function is public for testing with controlled RNG.
pub fn resolveThroughArmour(
    stack: *const Stack,
    part_idx: body.PartIndex,
    packet: damage.Packet,
    rng: *std.Random,
) AbsorptionResult {
    var remaining = packet;
    var layers_hit: u8 = 0;
    var deflected = false;
    var deflected_at_layer: ?u8 = null;
    var layers_destroyed: u8 = 0;
    const protection = stack.getProtection(part_idx);

    // Track axes through the layer stack:
    // - Geometry: dimensionless coefficient (0-1) for shielding/susceptibility math
    // - Penetration: cm of material the attack can punch through (for thickness consumption)
    // - Energy: joules for absorption calculations
    // - Rigidity: dimensionless coefficient for susceptibility
    var remaining_geo = if (packet.geometry > 0) packet.geometry else packet.penetration;
    var remaining_energy = if (packet.energy > 0) packet.energy else packet.amount;
    const rigidity = if (packet.rigidity > 0) packet.rigidity else deriveRigidityFromKind(packet.kind);
    var remaining_penetration = packet.penetration; // cm - consumed by layer thickness

    // Process layers outer to inner (Cloak=8 down to Skin=0)
    var layer_idx: usize = 9;
    while (layer_idx > 0) {
        layer_idx -= 1;
        const layer = protection[layer_idx] orelse continue;

        // Skip destroyed armour
        if (layer.integrity.* <= 0) continue;

        const integrity_before = layer.integrity.*;

        // Gap check - attack might find a hole in coverage
        if (rng.float(f32) < layer.totality.gapChance()) {
            continue; // slipped through
        }

        layers_hit += 1;
        const mat = layer.material;

        // === Susceptibility: compute damage to this layer ===
        // Layer takes damage when incoming axes exceed its thresholds
        const geo_excess = @max(0.0, remaining_geo - mat.geometry_threshold);
        const energy_excess = @max(0.0, remaining_energy - mat.energy_threshold);
        const rig_excess = @max(0.0, rigidity - mat.rigidity_threshold);

        const layer_damage =
            geo_excess * mat.geometry_ratio +
            energy_excess * mat.energy_ratio +
            rig_excess * mat.rigidity_ratio;

        layer.integrity.* -= layer_damage;
        if (integrity_before > 0 and layer.integrity.* <= 0) {
            layers_destroyed += 1;
        }

        // === Shielding: compute what passes through to next layer ===
        // Deflection reduces geometry coefficient (blunts/redirects penetrating edges)
        // Absorption reduces energy (soaks kinetic energy into layer)
        // Thickness subtracts from penetration (cm of material to cut through)
        const deflection_coeff = mat.effectiveDeflection();
        const absorption_coeff = mat.effectiveAbsorption();

        remaining_geo = remaining_geo * (1.0 - deflection_coeff);
        remaining_energy = remaining_energy * (1.0 - absorption_coeff);
        remaining_penetration -= mat.thickness; // cm consumed by this layer

        // Update packet for return and backward compat
        remaining.geometry = remaining_geo;
        remaining.energy = remaining_energy;
        remaining.penetration = @max(0.0, remaining_penetration);
        remaining.amount = remaining_energy;

        // Pierce/slash attacks stop when they can't penetrate further
        // Bludgeon continues (transfers energy even without penetration)
        if (remaining_penetration <= 0 and
            (remaining.kind == .pierce or remaining.kind == .slash))
        {
            remaining.energy = 0;
            remaining.amount = 0;
            deflected = true;
            deflected_at_layer = @intCast(layer_idx);
            break;
        }

        // Attack fully absorbed - negligible energy remains
        if (remaining_energy < 0.05) {
            remaining.energy = 0;
            remaining.amount = 0;
            deflected = true;
            deflected_at_layer = @intCast(layer_idx);
            break;
        }
    }

    return .{
        .remaining = remaining,
        .gap_found = layers_hit == 0 and remaining.amount > 0,
        .layers_hit = layers_hit,
        .deflected = deflected,
        .deflected_at_layer = deflected_at_layer,
        .layers_destroyed = layers_destroyed,
    };
}

/// Production wrapper: resolves armour using World.drawRandom and emits events.
/// Uses same 3-axis physics model as resolveThroughArmour.
pub fn resolveThroughArmourWithEvents(
    w: *world.World,
    agent_id: entity.ID,
    stack: *const Stack,
    part_idx: body.PartIndex,
    part_tag: body.PartTag,
    part_side: body.Side,
    packet: damage.Packet,
) !AbsorptionResult {
    var remaining = packet;
    var layers_hit: u8 = 0;
    var deflected = false;
    var deflected_at_layer: ?u8 = null;
    var layers_destroyed: u8 = 0;
    const protection = stack.getProtection(part_idx);
    const initial_amount = packet.amount;

    // Process layers outer to inner (Cloak=8 down to Skin=0)
    var layer_idx: usize = 9;
    while (layer_idx > 0) {
        layer_idx -= 1;
        const layer = protection[layer_idx] orelse continue;

        if (layer.integrity.* <= 0) continue;

        const integrity_before = layer.integrity.*;
        const layer_u8: u8 = @intCast(layer_idx);

        // Gap check - attack might find a hole in coverage
        const gap_roll = try w.drawRandom(.combat);
        if (gap_roll < layer.totality.gapChance()) {
            try w.events.push(.{ .attack_found_gap = .{
                .agent_id = agent_id,
                .part_idx = part_idx,
                .part_tag = part_tag,
                .part_side = part_side,
                .layer = layer_u8,
            } });
            continue;
        }

        layers_hit += 1;

        // === Get axes from packet (T037: real physics values or legacy fallback) ===
        const geometry = if (remaining.geometry > 0) remaining.geometry else remaining.penetration;
        const energy_axis = if (remaining.energy > 0) remaining.energy else remaining.amount;
        const rigidity = if (remaining.rigidity > 0) remaining.rigidity else deriveRigidityFromKind(remaining.kind);
        const mat = layer.material;

        // === Susceptibility: compute damage to this layer ===
        const geo_excess = @max(0.0, geometry - mat.geometry_threshold);
        const energy_excess = @max(0.0, energy_axis - mat.energy_threshold);
        const rig_excess = @max(0.0, rigidity - mat.rigidity_threshold);

        const layer_damage =
            geo_excess * mat.geometry_ratio +
            energy_excess * mat.energy_ratio +
            rig_excess * mat.rigidity_ratio;

        layer.integrity.* -= layer_damage;
        if (integrity_before > 0 and layer.integrity.* <= 0) {
            layers_destroyed += 1;
            try w.events.push(.{ .armour_layer_destroyed = .{
                .agent_id = agent_id,
                .part_idx = part_idx,
                .part_tag = part_tag,
                .part_side = part_side,
                .layer = layer_u8,
            } });
        }

        // === Shielding: compute what passes through to next layer ===
        const deflection_coeff = mat.effectiveDeflection();
        const absorption_coeff = mat.effectiveAbsorption();

        remaining.geometry = geometry * (1.0 - deflection_coeff) - mat.thickness;
        remaining.geometry = @max(0.0, remaining.geometry);
        remaining.energy = energy_axis * (1.0 - absorption_coeff);
        // Also update legacy fields for backward compat
        remaining.penetration = remaining.geometry;
        remaining.amount = remaining.energy;

        // Penetration exhausted - piercing/slashing attacks stop
        if (remaining.geometry <= 0 and
            (remaining.kind == .pierce or remaining.kind == .slash))
        {
            remaining.energy = 0;
            remaining.amount = 0;
            deflected = true;
            deflected_at_layer = layer_u8;
            try w.events.push(.{ .armour_deflected = .{
                .agent_id = agent_id,
                .part_idx = part_idx,
                .part_tag = part_tag,
                .part_side = part_side,
                .layer = layer_u8,
            } });
            break;
        }

        // Attack fully absorbed - negligible energy remains
        if (remaining.energy < 0.05) {
            remaining.energy = 0;
            remaining.amount = 0;
            deflected = true;
            deflected_at_layer = layer_u8;
            try w.events.push(.{ .armour_deflected = .{
                .agent_id = agent_id,
                .part_idx = part_idx,
                .part_tag = part_tag,
                .part_side = part_side,
                .layer = layer_u8,
            } });
            break;
        }
    }

    // Emit summary event if armour absorbed any damage
    if (layers_hit > 0) {
        const damage_reduced = initial_amount - remaining.amount;
        try w.events.push(.{ .armour_absorbed = .{
            .agent_id = agent_id,
            .part_idx = part_idx,
            .part_tag = part_tag,
            .part_side = part_side,
            .damage_reduced = damage_reduced,
            .layers_hit = layers_hit,
        } });
    }

    return .{
        .remaining = remaining,
        .gap_found = layers_hit == 0 and remaining.amount > 0,
        .layers_hit = layers_hit,
        .deflected = deflected,
        .deflected_at_layer = deflected_at_layer,
        .layers_destroyed = layers_destroyed,
    };
}

// =============================================================================
// Tests
// =============================================================================

// --- Test fixtures ---

const TestMaterials = struct {
    // Cloth/gambeson: soft padding, absorbs energy, poor vs geometry
    pub const cloth = Material{
        .name = "cloth",
        .quality = .common,
        // Shielding: absorbs well, doesn't deflect or disperse
        .deflection = 0.1,
        .absorption = 0.5,
        .dispersion = 0.3,
        // Susceptibility: easily cut/pierced, resists blunt better
        .geometry_threshold = 0.02,
        .geometry_ratio = 0.9,
        .energy_threshold = 0.1,
        .energy_ratio = 0.6,
        .rigidity_threshold = 0.05,
        .rigidity_ratio = 0.7,
        // Shape
        .shape = .quilted,
        .shape_absorption_bonus = 0.1,
        .shape_dispersion_bonus = 0.1,
        // Physical
        .thickness = 0.2,
        .durability = 50,
    };

    // Mail: mesh of rings, good vs slash (geometry), weak vs thrust, poor vs blunt
    pub const mail = Material{
        .name = "chainmail",
        .quality = .common,
        // Shielding: deflects edges, minimal absorption
        .deflection = 0.55,
        .absorption = 0.25,
        .dispersion = 0.15,
        // Susceptibility: rings stop cuts, thrusts can slip through, blunt transfers
        .geometry_threshold = 0.15,
        .geometry_ratio = 0.5,
        .energy_threshold = 0.2,
        .energy_ratio = 0.7,
        .rigidity_threshold = 0.2,
        .rigidity_ratio = 0.6,
        // Shape
        .shape = .mesh,
        .shape_absorption_bonus = 0.05,
        .shape_dispersion_bonus = -0.05,
        // Physical
        .thickness = 0.5,
        .durability = 100,
    };

    // Plate: rigid surface, excellent deflection, transmits blunt force
    pub const plate = Material{
        .name = "steel plate",
        .quality = .excellent,
        // Shielding: great deflection, poor absorption, some dispersion
        .deflection = 0.85,
        .absorption = 0.2,
        .dispersion = 0.35,
        // Susceptibility: hard to damage, but concentrated force gets through
        .geometry_threshold = 0.3,
        .geometry_ratio = 0.3,
        .energy_threshold = 0.4,
        .energy_ratio = 0.5,
        .rigidity_threshold = 0.35,
        .rigidity_ratio = 0.4,
        // Shape
        .shape = .solid,
        .shape_absorption_bonus = -0.05,
        .shape_dispersion_bonus = 0.1,
        // Physical
        .thickness = 1.0,
        .durability = 200,
    };

    // Bare: no protection at all
    pub const bare = Material{
        .name = "bare",
        .quality = .common,
        .deflection = 0,
        .absorption = 0,
        .dispersion = 0,
        .geometry_threshold = 0,
        .geometry_ratio = 1.0,
        .energy_threshold = 0,
        .energy_ratio = 1.0,
        .rigidity_threshold = 0,
        .rigidity_ratio = 1.0,
        .shape = .solid,
        .thickness = 0,
        .durability = 0,
    };
};

const TestPatterns = struct {
    // Single part coverage (e.g., a gauntlet)
    pub const single_arm = Pattern{
        .coverage = &.{
            .{
                .part_tags = &.{.arm},
                .side = null, // assigned at instantiation
                .layer = .Mail,
                .totality = .comprehensive,
            },
        },
    };

    // Multi-part coverage (e.g., torso armor)
    pub const torso_coverage = Pattern{
        .coverage = &.{
            .{
                .part_tags = &.{ .torso, .abdomen },
                .side = .center,
                .layer = .Plate,
                .totality = .intimidating,
            },
        },
    };

    // Multi-layer coverage (gambeson + mail)
    pub const layered_torso = Pattern{
        .coverage = &.{
            .{
                .part_tags = &.{.torso},
                .side = .center,
                .layer = .Gambeson,
                .totality = .total,
            },
        },
    };

    pub const mail_torso = Pattern{
        .coverage = &.{
            .{
                .part_tags = &.{.torso},
                .side = .center,
                .layer = .Mail,
                .totality = .comprehensive,
            },
        },
    };
};

const TestTemplates = struct {
    pub const mail_sleeve = Template{
        .id = 1,
        .name = "mail sleeve",
        .material = &TestMaterials.mail,
        .pattern = &TestPatterns.single_arm,
    };

    pub const plate_cuirass = Template{
        .id = 2,
        .name = "plate cuirass",
        .material = &TestMaterials.plate,
        .pattern = &TestPatterns.torso_coverage,
    };

    pub const gambeson = Template{
        .id = 3,
        .name = "gambeson",
        .material = &TestMaterials.cloth,
        .pattern = &TestPatterns.layered_torso,
    };

    pub const mail_shirt = Template{
        .id = 4,
        .name = "mail shirt",
        .material = &TestMaterials.mail,
        .pattern = &TestPatterns.mail_torso,
    };
};

// Minimal body plan for armor tests - just the parts we need
// Placeholder geometry; real data comes from CUE-generated plans.
const TestGeometry = body_list.BodyPartGeometry{
    .thickness_cm = 5.0,
    .length_cm = 10.0,
    .area_cm2 = 100.0,
};

const TestBodyPlan = [_]body.PartDef{
    .{
        .id = body.PartId.init("torso"),
        .parent = null,
        .enclosing = null,
        .tag = .torso,
        .side = .center,
        .name = "torso",
        .base_hit_chance = 0.3,
        .base_durability = 2.0,
        .trauma_mult = 1.0,
        .flags = .{ .is_vital = true },
        .tissue = .core,
        .has_major_artery = false,
        .geometry = TestGeometry,
    },
    .{
        .id = body.PartId.init("abdomen"),
        .parent = body.PartId.init("torso"),
        .enclosing = null,
        .tag = .abdomen,
        .side = .center,
        .name = "abdomen",
        .base_hit_chance = 0.15,
        .base_durability = 1.5,
        .trauma_mult = 1.2,
        .flags = .{ .is_vital = true },
        .tissue = .core,
        .has_major_artery = false,
        .geometry = TestGeometry,
    },
    .{
        .id = body.PartId.init("left_arm"),
        .parent = body.PartId.init("torso"),
        .enclosing = null,
        .tag = .arm,
        .side = .left,
        .name = "left arm",
        .base_hit_chance = 0.05,
        .base_durability = 0.8,
        .trauma_mult = 1.0,
        .flags = .{},
        .tissue = .limb,
        .has_major_artery = false,
        .geometry = TestGeometry,
    },
    .{
        .id = body.PartId.init("right_arm"),
        .parent = body.PartId.init("torso"),
        .enclosing = null,
        .tag = .arm,
        .side = .right,
        .name = "right arm",
        .base_hit_chance = 0.05,
        .base_durability = 0.8,
        .trauma_mult = 1.0,
        .flags = .{},
        .tissue = .limb,
        .has_major_artery = false,
        .geometry = TestGeometry,
    },
};

fn makeTestBody(alloc: std.mem.Allocator) !body.Body {
    return body.Body.fromParts(alloc, &TestBodyPlan);
}

/// Create a seeded RNG for deterministic tests
fn testRng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

test "Totality.gapChance returns expected values" {
    // Verify each totality level returns the documented gap chance
    // .total → 0.0, .intimidating → 0.05, etc.
    try std.testing.expectEqual(@as(f32, 0.0), Totality.total.gapChance());
    try std.testing.expectEqual(@as(f32, 0.05), Totality.intimidating.gapChance());
    try std.testing.expectEqual(@as(f32, 0.15), Totality.comprehensive.gapChance());
    try std.testing.expectEqual(@as(f32, 0.30), Totality.frontal.gapChance());
    try std.testing.expectEqual(@as(f32, 0.50), Totality.minimal.gapChance());
}

test "Stack.buildFromEquipped populates coverage map" {
    const alloc = std.testing.allocator;

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    // Create mail sleeve for left arm
    var sleeve = try Instance.init(alloc, &TestTemplates.mail_sleeve, .left);
    defer sleeve.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();

    var equipped = [_]*Instance{&sleeve};
    try stack.buildFromEquipped(&bod, &equipped);

    // Find left_arm index
    const left_arm_idx = resolvePartIndex(&bod, .arm, .left).?;

    // Should have protection at Mail layer (index 4)
    const protection = stack.getProtection(left_arm_idx);
    try std.testing.expect(protection[@intFromEnum(inventory.Layer.Mail)] != null);

    const layer = protection[@intFromEnum(inventory.Layer.Mail)].?;
    try std.testing.expectEqualStrings("chainmail", layer.material.name);
    try std.testing.expectEqual(Totality.comprehensive, layer.totality);
}

test "Stack.buildFromEquipped handles multiple armor pieces" {
    const alloc = std.testing.allocator;

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    // Create gambeson (Gambeson layer) + mail shirt (Mail layer) for torso
    var gambeson = try Instance.init(alloc, &TestTemplates.gambeson, null);
    defer gambeson.deinit(alloc);

    var mail_shirt = try Instance.init(alloc, &TestTemplates.mail_shirt, null);
    defer mail_shirt.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();

    var equipped = [_]*Instance{ &gambeson, &mail_shirt };
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;
    const protection = stack.getProtection(torso_idx);

    // Both layers should be present
    const gambeson_layer = protection[@intFromEnum(inventory.Layer.Gambeson)];
    const mail_layer = protection[@intFromEnum(inventory.Layer.Mail)];

    try std.testing.expect(gambeson_layer != null);
    try std.testing.expect(mail_layer != null);

    try std.testing.expectEqualStrings("cloth", gambeson_layer.?.material.name);
    try std.testing.expectEqualStrings("chainmail", mail_layer.?.material.name);
}

test "Stack.getProtection returns empty for unarmored part" {
    const alloc = std.testing.allocator;

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    // Only equip torso armor
    var cuirass = try Instance.init(alloc, &TestTemplates.plate_cuirass, null);
    defer cuirass.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();

    var equipped = [_]*Instance{&cuirass};
    try stack.buildFromEquipped(&bod, &equipped);

    // Left arm should have no protection
    const left_arm_idx = resolvePartIndex(&bod, .arm, .left).?;
    const protection = stack.getProtection(left_arm_idx);

    // All slots should be null
    for (protection) |layer| {
        try std.testing.expect(layer == null);
    }
}

test "resolveThroughArmour: gap found bypasses layer" {
    const alloc = std.testing.allocator;

    // Create a minimal armor pattern with .minimal totality (50% gap chance)
    const minimal_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .minimal, // 50% gap chance
        }},
    };
    const minimal_template = Template{
        .id = 100,
        .name = "flimsy plate",
        .material = &TestMaterials.plate,
        .pattern = &minimal_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &minimal_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;
    const packet = damage.Packet{ .amount = 1.0, .kind = .slash, .penetration = 1.0 };

    // Find a seed that produces a gap (first float < 0.5)
    // We'll try multiple seeds until we find one that gaps
    var found_gap = false;
    var seed: u64 = 0;
    while (seed < 100) : (seed += 1) {
        var prng = testRng(seed);
        var rng = prng.random();

        // Reset armor integrity for each attempt
        armor.coverage[0].integrity = TestMaterials.plate.durability * Quality.excellent.durabilityMult();

        const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);
        if (result.gap_found) {
            found_gap = true;
            // Damage should pass through unchanged
            try std.testing.expectEqual(packet.amount, result.remaining.amount);
            try std.testing.expectEqual(@as(u8, 0), result.layers_hit);
            break;
        }
    }
    try std.testing.expect(found_gap);
}

test "resolveThroughArmour: high deflection reduces penetration" {
    const alloc = std.testing.allocator;

    // Plate has deflection=0.85, high deflection should significantly reduce geometry
    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .total, // no gaps
        }},
    };
    const solid_template = Template{
        .id = 101,
        .name = "solid plate",
        .material = &TestMaterials.plate,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &solid_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;
    // Slash with moderate penetration - plate should reduce it significantly
    const packet = damage.Packet{ .amount = 1.0, .kind = .slash, .penetration = 1.0 };

    var prng = testRng(42);
    var rng = prng.random();

    const initial_integrity = armor.coverage[0].integrity;
    const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

    // Penetration reduced: 1.0 * (1 - 0.85) - 1.0 (thickness) = -0.85 -> clamped to 0
    // Slash attack with 0 penetration is stopped (deflected)
    try std.testing.expectEqual(@as(f32, 0), result.remaining.penetration);
    try std.testing.expect(result.deflected);

    // Layer should take susceptibility damage based on incoming axes
    // geometry=1.0, excess = 1.0 - 0.3 = 0.7, damage = 0.7 * 0.3 = 0.21
    // momentum=1.0, excess = 1.0 - 0.4 = 0.6, damage = 0.6 * 0.5 = 0.30
    // rigidity=0.7 (slash), excess = 0.7 - 0.35 = 0.35, damage = 0.35 * 0.4 = 0.14
    // total ~= 0.65
    const integrity_loss = initial_integrity - armor.coverage[0].integrity;
    try std.testing.expect(integrity_loss > 0.5);
    try std.testing.expect(integrity_loss < 0.8);
}

test "resolveThroughArmour: absorption reduces momentum" {
    const alloc = std.testing.allocator;

    // Test that absorption reduces the amount (momentum) that passes through
    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .total,
        }},
    };

    // Material with high absorption, no deflection, no thickness
    const absorbing_material = Material{
        .name = "absorbing",
        .deflection = 0.0,
        .absorption = 0.6, // 60% absorption
        .dispersion = 0.0,
        .geometry_threshold = 10.0, // high thresholds = no layer damage
        .geometry_ratio = 0.0,
        .energy_threshold = 10.0,
        .energy_ratio = 0.0,
        .rigidity_threshold = 10.0,
        .rigidity_ratio = 0.0,
        .thickness = 0.0,
        .durability = 200,
    };

    const absorbing_template = Template{
        .id = 102,
        .name = "absorbing",
        .material = &absorbing_material,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &absorbing_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;

    // Bludgeon attack - not affected by penetration exhaustion
    const packet = damage.Packet{ .amount = 1.0, .kind = .bludgeon, .penetration = 0.5 };
    var prng = testRng(42);
    var rng = prng.random();

    const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

    // Amount reduced by 60% absorption: 1.0 * (1 - 0.6) = 0.4
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), result.remaining.amount, 0.01);
    try std.testing.expectEqual(@as(u8, 1), result.layers_hit);
}

test "resolveThroughArmour: susceptibility damages layer" {
    const alloc = std.testing.allocator;

    // Test that incoming axes above thresholds damage the layer
    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Mail,
            .totality = .total,
        }},
    };

    // Material with specific susceptibility values for predictable damage
    const test_mail = Material{
        .name = "test mail",
        .deflection = 0.0, // no reduction to geometry
        .absorption = 0.0, // no reduction to momentum
        .dispersion = 0.0,
        .geometry_threshold = 0.5, // pierce at 2.0 penetration exceeds this
        .geometry_ratio = 0.5, // 50% of excess becomes damage
        .energy_threshold = 0.5, // amount 1.0 exceeds this
        .energy_ratio = 0.4, // 40% of excess becomes damage
        .rigidity_threshold = 0.5, // pierce rigidity 1.0 exceeds this
        .rigidity_ratio = 0.3, // 30% of excess becomes damage
        .thickness = 0.0,
        .durability = 100,
    };

    const test_template = Template{
        .id = 103,
        .name = "test mail",
        .material = &test_mail,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &test_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;

    // Pierce attack: geometry=2.0, momentum=1.0, rigidity=1.0
    const packet = damage.Packet{ .amount = 1.0, .kind = .pierce, .penetration = 2.0 };
    var prng = testRng(42);
    var rng = prng.random();

    const initial_integrity = armor.coverage[0].integrity;
    const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

    // Expected layer damage:
    // geo: (2.0 - 0.5) * 0.5 = 0.75
    // mom: (1.0 - 0.5) * 0.4 = 0.20
    // rig: (1.0 - 0.5) * 0.3 = 0.15
    // total = 1.10
    const expected_damage: f32 = 0.75 + 0.20 + 0.15;
    const integrity_loss = initial_integrity - armor.coverage[0].integrity;
    try std.testing.expectApproxEqAbs(expected_damage, integrity_loss, 0.01);

    // With no absorption/deflection, attack passes through at full strength
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), result.remaining.amount, 0.01);
}

test "resolveThroughArmour: penetration reduced by thickness" {
    const alloc = std.testing.allocator;

    // Mail has thickness=0.5
    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Mail,
            .totality = .total,
        }},
    };

    const test_template = Template{
        .id = 104,
        .name = "mail",
        .material = &TestMaterials.mail,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &test_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;
    const packet = damage.Packet{ .amount = 1.0, .kind = .pierce, .penetration = 1.0 };

    // Find a seed that doesn't deflect
    var seed: u64 = 0;
    while (seed < 100) : (seed += 1) {
        var prng = testRng(seed);
        var rng = prng.random();
        armor.coverage[0].integrity = TestMaterials.mail.durability;

        const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

        // If damage got through (not deflected)
        if (result.remaining.amount > 0) {
            // Penetration should be reduced by thickness (0.5)
            try std.testing.expectApproxEqAbs(0.5, result.remaining.penetration, 0.01);
            break;
        }
    }
}

test "resolveThroughArmour: pierce stops when penetration exhausted" {
    const alloc = std.testing.allocator;

    // Use thick material (thickness=1.0)
    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .total,
        }},
    };

    // Material with 0 deflection and minimal resistance for predictable behavior
    const thick_material = Material{
        .name = "thick",
        .deflection = 0.0,
        .absorption = 0.2,
        .dispersion = 0.3,
        .geometry_threshold = 0.0,
        .geometry_ratio = 1.0,
        .energy_threshold = 0.0,
        .energy_ratio = 1.0,
        .rigidity_threshold = 0.0,
        .rigidity_ratio = 1.0,
        .thickness = 1.5,
        .durability = 200,
    };

    const test_template = Template{
        .id = 105,
        .name = "thick armor",
        .material = &thick_material,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &test_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;

    // Pierce with low penetration
    const packet = damage.Packet{ .amount = 1.0, .kind = .pierce, .penetration = 0.5 };
    var prng = testRng(42);
    var rng = prng.random();

    const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

    // Penetration exhausted, attack stopped
    try std.testing.expectEqual(@as(f32, 0), result.remaining.amount);
    try std.testing.expect(result.remaining.penetration <= 0);
}

test "resolveThroughArmour: bludgeon ignores penetration" {
    const alloc = std.testing.allocator;

    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .total,
        }},
    };

    // Material with high thickness but 0 deflection
    const thick_material = Material{
        .name = "thick",
        .deflection = 0.0,
        .absorption = 0.2,
        .dispersion = 0.3,
        .geometry_threshold = 0.0,
        .geometry_ratio = 1.0,
        .energy_threshold = 0.0,
        .energy_ratio = 1.0,
        .rigidity_threshold = 0.0,
        .rigidity_ratio = 1.0,
        .thickness = 5.0, // very thick - would stop pierce
        .durability = 200,
    };

    const test_template = Template{
        .id = 106,
        .name = "thick armor",
        .material = &thick_material,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &test_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;

    // Bludgeon with 0 penetration - should still transfer damage
    const packet = damage.Packet{ .amount = 1.0, .kind = .bludgeon, .penetration = 0.0 };
    var prng = testRng(42);
    var rng = prng.random();

    const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

    // Bludgeon should get through based on amount, not penetration
    try std.testing.expect(result.remaining.amount > 0);
}

test "resolveThroughArmour: destroyed layers skipped" {
    const alloc = std.testing.allocator;

    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .total,
        }},
    };

    const test_template = Template{
        .id = 107,
        .name = "destroyed plate",
        .material = &TestMaterials.plate,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &test_template, null);
    defer armor.deinit(alloc);

    // Destroy the armor
    armor.coverage[0].integrity = 0;

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;
    const packet = damage.Packet{ .amount = 1.0, .kind = .slash, .penetration = 1.0 };
    var prng = testRng(42);
    var rng = prng.random();

    const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

    // Destroyed layer skipped - damage passes through, no layers hit
    try std.testing.expectEqual(@as(u8, 0), result.layers_hit);
    try std.testing.expectEqual(packet.amount, result.remaining.amount);
}

test "resolveThroughArmour: multiple layers processed outer to inner" {
    const alloc = std.testing.allocator;

    // Create two armor pieces at different layers
    var gambeson = try Instance.init(alloc, &TestTemplates.gambeson, null);
    defer gambeson.deinit(alloc);

    var mail_shirt = try Instance.init(alloc, &TestTemplates.mail_shirt, null);
    defer mail_shirt.deinit(alloc);

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{ &gambeson, &mail_shirt };
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;
    const packet = damage.Packet{ .amount = 2.0, .kind = .slash, .penetration = 2.0 };

    // Use multiple seeds to find one where both layers are hit
    var seed: u64 = 0;
    while (seed < 100) : (seed += 1) {
        var prng = testRng(seed);
        var rng = prng.random();

        // Reset integrities
        gambeson.coverage[0].integrity = TestMaterials.cloth.durability;
        mail_shirt.coverage[0].integrity = TestMaterials.mail.durability;

        const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

        if (result.layers_hit >= 2) {
            // Both layers were processed
            try std.testing.expect(result.layers_hit >= 2);
            // Damage should be reduced from both layers
            try std.testing.expect(result.remaining.amount < packet.amount);
            break;
        }
    }
}

test "resolveThroughArmour: layer integrity degrades" {
    const alloc = std.testing.allocator;

    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Mail,
            .totality = .total,
        }},
    };

    // Material with no deflection for predictable test
    const soft_mail = Material{
        .name = "soft mail",
        .deflection = 0.0,
        .absorption = 0.25,
        .dispersion = 0.15,
        .geometry_threshold = 0.0,
        .geometry_ratio = 0.5,
        .energy_threshold = 0.15,
        .energy_ratio = 0.6,
        .rigidity_threshold = 0.15,
        .rigidity_ratio = 0.5,
        .thickness = 0.5,
        .durability = 200,
    };

    const test_template = Template{
        .id = 108,
        .name = "soft mail",
        .material = &soft_mail,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &test_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;
    const packet = damage.Packet{ .amount = 1.0, .kind = .slash, .penetration = 1.0 };

    const initial_integrity = armor.coverage[0].integrity;
    var prng = testRng(42);
    var rng = prng.random();

    _ = resolveThroughArmour(&stack, torso_idx, packet, &rng);

    // Integrity should have decreased
    try std.testing.expect(armor.coverage[0].integrity < initial_integrity);
}

test "full flow: armor absorption then body damage" {
    const alloc = std.testing.allocator;

    // 1. Create body with full humanoid plan (has torso with proper tissue)
    var bod = try body.Body.fromPlan(alloc, "humanoid");
    defer bod.deinit();

    // 2. Create and equip mail shirt
    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Mail,
            .totality = .total,
        }},
    };

    // Material with 0 deflection for predictable test
    const test_mail = Material{
        .name = "test mail",
        .deflection = 0.0,
        .absorption = 0.25,
        .dispersion = 0.15,
        .geometry_threshold = 0.2,
        .geometry_ratio = 0.5,
        .energy_threshold = 0.15,
        .energy_ratio = 0.6,
        .rigidity_threshold = 0.15,
        .rigidity_ratio = 0.5,
        .thickness = 0.3,
        .durability = 100,
    };

    const test_template = Template{
        .id = 200,
        .name = "test mail",
        .material = &test_mail,
        .pattern = &solid_pattern,
    };

    var armor = try Instance.init(alloc, &test_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    // 3. Create damage packet
    const initial_packet = damage.Packet{
        .amount = 10.0,
        .kind = .slash,
        .penetration = 1.0,
    };

    const torso_idx = bod.indexOf("torso").?;

    // 4. Resolve through armor
    var prng = testRng(42);
    var rng = prng.random();

    const armor_result = resolveThroughArmour(&stack, torso_idx, initial_packet, &rng);

    // 3-axis model: momentum reduced by absorption (25%)
    // remaining.amount = 10.0 * (1 - 0.25) = 7.5
    const expected_remaining = 10.0 * (1.0 - 0.25);
    try std.testing.expectApproxEqAbs(expected_remaining, armor_result.remaining.amount, 0.01);
    try std.testing.expectEqual(@as(u8, 1), armor_result.layers_hit);

    // 5. Apply remaining damage to body
    const body_result = try bod.applyDamageToPart(torso_idx, armor_result.remaining);

    // Should have created a wound
    try std.testing.expect(body_result.wound.len > 0);
    const wound_severity = body_result.wound.worstSeverity();

    // 6. Compare with unarmored damage - armor should reduce or equal severity
    var unarmored_bod = try body.Body.fromPlan(alloc, "humanoid");
    defer unarmored_bod.deinit();

    const unarmored_torso_idx = unarmored_bod.indexOf("torso").?;
    const unarmored_result = try unarmored_bod.applyDamageToPart(unarmored_torso_idx, initial_packet);

    // Unarmored should take at least as severe damage (armor helps or is neutral)
    const unarmored_severity = unarmored_result.wound.worstSeverity();
    try std.testing.expect(@intFromEnum(unarmored_severity) >= @intFromEnum(wound_severity));

    // Verify armor actually reduced the damage amount
    try std.testing.expect(armor_result.remaining.amount < initial_packet.amount);
}
