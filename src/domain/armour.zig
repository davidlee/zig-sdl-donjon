const std = @import("std");
const lib = @import("infra");
const body = @import("body.zig");
const damage = @import("damage.zig");
const entity = lib.entity;
const events = @import("events.zig");
const inventory = @import("inventory.zig");
const random = @import("random.zig");
const world = @import("world.zig");

const Resistance = damage.Resistance;
const Vulnerability = damage.Vulnerability;

const Quality = enum {
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

const Material = struct {
    name: []const u8,

    // these modify to the wearer
    resistances: []const Resistance,
    vulnerabilities: []const Vulnerability,

    // these modify to the material itself
    self_resistances: []const Resistance,
    self_vulnerabilities: []const Vulnerability,

    quality: Quality,
    durability: f32, // base - modified by size, quality, etc
    thickness: f32, // cm - affects penetration cost
    hardness: f32, // deflection chance for glancing blows
    flexibility: f32, // affects mobility penalty, gap size
};

// coverage of a particular part by a particular material - or,
// how hard is it to get around the tough stuff with a lucky stab or a shiv in the kidneys?
const Totality = enum {
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
const PatternCoverage = struct {
    part_tags: []const body.PartTag,
    side: ?body.Side, // null = assigned on instantiation (e.g., "left pauldron")
    layer: inventory.Layer,
    totality: Totality,
};

const Pattern = struct {
    coverage: []const PatternCoverage,
};

// designed to be easily definable at comptime
const Template = struct {
    id: u64,
    name: []const u8,
    material: *const Material,
    pattern: *const Pattern,
};

/// A specific piece of armor with runtime state
const Instance = struct {
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
fn resolvePartIndex(bod: *const body.Body, tag: body.PartTag, side: body.Side) ?body.PartIndex {
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
    deflected: bool, // hardness deflection stopped the attack
    deflected_at_layer: ?u8, // which layer deflected (if any)
    layers_destroyed: u8, // layers that hit 0 integrity this resolution
};

/// Process a damage packet through armour layers, returning what reaches the body.
/// Mutates layer integrity as armour is damaged.
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

    // Process layers outer to inner (Cloak=8 down to Skin=0)
    var layer_idx: usize = 9;
    while (layer_idx > 0) {
        layer_idx -= 1;
        const layer = protection[layer_idx] orelse continue;

        // Skip destroyed armour
        if (layer.integrity.* <= 0) continue;

        const integrity_before = layer.integrity.*;

        // Gap check - attack might find a hole
        if (rng.float(f32) < layer.totality.gapChance()) {
            continue; // slipped through
        }

        layers_hit += 1;

        // Hardness check - glancing blow deflection
        if (rng.float(f32) < layer.material.hardness) {
            // Deflected - minimal damage to armour, attack stopped
            layer.integrity.* -= remaining.amount * 0.1;
            remaining.amount = 0;
            deflected = true;
            deflected_at_layer = @intCast(layer_idx);
            if (integrity_before > 0 and layer.integrity.* <= 0) {
                layers_destroyed += 1;
            }
            break;
        }

        // Material resistance reduces damage
        const resistance = getMaterialResistance(layer.material, remaining.kind);
        if (remaining.amount < resistance.threshold) {
            // Below threshold - no penetration, minor armour wear
            layer.integrity.* -= remaining.amount * 0.05;
            remaining.amount = 0;
            if (integrity_before > 0 and layer.integrity.* <= 0) {
                layers_destroyed += 1;
            }
            break;
        }

        // Damage that gets through
        const effective_damage = (remaining.amount - resistance.threshold) * resistance.ratio;
        const absorbed = remaining.amount - effective_damage;

        // Armour takes damage
        layer.integrity.* -= absorbed * 0.5;
        if (integrity_before > 0 and layer.integrity.* <= 0) {
            layers_destroyed += 1;
        }

        // Penetration reduced by thickness
        remaining.penetration -= layer.material.thickness;
        remaining.amount = effective_damage;

        // If penetration exhausted, stop (for piercing/slashing)
        if (remaining.penetration <= 0 and
            (remaining.kind == .pierce or remaining.kind == .slash))
        {
            remaining.amount = 0;
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
pub fn resolveThroughArmourWithEvents(
    w: *world.World,
    agent_id: entity.ID,
    stack: *const Stack,
    part_idx: body.PartIndex,
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

        // Gap check
        const gap_roll = try w.drawRandom(.combat);
        if (gap_roll < layer.totality.gapChance()) {
            try w.events.push(.{ .attack_found_gap = .{
                .agent_id = agent_id,
                .part_idx = part_idx,
                .layer = layer_u8,
            } });
            continue;
        }

        layers_hit += 1;

        // Hardness check
        const hardness_roll = try w.drawRandom(.combat);
        if (hardness_roll < layer.material.hardness) {
            layer.integrity.* -= remaining.amount * 0.1;
            remaining.amount = 0;
            deflected = true;
            deflected_at_layer = layer_u8;

            try w.events.push(.{ .armour_deflected = .{
                .agent_id = agent_id,
                .part_idx = part_idx,
                .layer = layer_u8,
            } });

            if (integrity_before > 0 and layer.integrity.* <= 0) {
                layers_destroyed += 1;
                try w.events.push(.{ .armour_layer_destroyed = .{
                    .agent_id = agent_id,
                    .part_idx = part_idx,
                    .layer = layer_u8,
                } });
            }
            break;
        }

        const resistance = getMaterialResistance(layer.material, remaining.kind);
        if (remaining.amount < resistance.threshold) {
            layer.integrity.* -= remaining.amount * 0.05;
            remaining.amount = 0;
            if (integrity_before > 0 and layer.integrity.* <= 0) {
                layers_destroyed += 1;
                try w.events.push(.{ .armour_layer_destroyed = .{
                    .agent_id = agent_id,
                    .part_idx = part_idx,
                    .layer = layer_u8,
                } });
            }
            break;
        }

        const effective_damage = (remaining.amount - resistance.threshold) * resistance.ratio;
        const absorbed = remaining.amount - effective_damage;

        layer.integrity.* -= absorbed * 0.5;
        if (integrity_before > 0 and layer.integrity.* <= 0) {
            layers_destroyed += 1;
            try w.events.push(.{ .armour_layer_destroyed = .{
                .agent_id = agent_id,
                .part_idx = part_idx,
                .layer = layer_u8,
            } });
        }

        remaining.penetration -= layer.material.thickness;
        remaining.amount = effective_damage;

        if (remaining.penetration <= 0 and
            (remaining.kind == .pierce or remaining.kind == .slash))
        {
            remaining.amount = 0;
            break;
        }
    }

    // Emit summary event if armour absorbed any damage
    if (layers_hit > 0) {
        const damage_reduced = initial_amount - remaining.amount;
        try w.events.push(.{ .armour_absorbed = .{
            .agent_id = agent_id,
            .part_idx = part_idx,
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

fn getMaterialResistance(material: *const Material, kind: damage.Kind) Resistance {
    for (material.self_resistances) |res| {
        if (res.damage == kind) return res;
    }
    // No specific resistance - use defaults
    return .{ .damage = kind, .threshold = 0, .ratio = 1.0 };
}

// =============================================================================
// Tests
// =============================================================================

// --- Test fixtures ---

const TestMaterials = struct {
    // Cloth: soft, flexible, minimal protection
    pub const cloth = Material{
        .name = "cloth",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{
            .{ .damage = .slash, .threshold = 0.0, .ratio = 0.9 },
        },
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 0.5,
        .thickness = 0.2,
        .hardness = 0.0,
        .flexibility = 0.9,
    };

    // Mail: good vs slash, weak vs pierce, medium hardness
    pub const mail = Material{
        .name = "chainmail",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{
            .{ .damage = .slash, .threshold = 0.3, .ratio = 0.3 },
            .{ .damage = .pierce, .threshold = 0.1, .ratio = 0.7 },
        },
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 1.0,
        .thickness = 0.5,
        .hardness = 0.3,
        .flexibility = 0.5,
    };

    // Plate: high hardness, high threshold, excellent protection
    pub const plate = Material{
        .name = "steel plate",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{
            .{ .damage = .slash, .threshold = 0.5, .ratio = 0.2 },
            .{ .damage = .pierce, .threshold = 0.4, .ratio = 0.3 },
            .{ .damage = .bludgeon, .threshold = 0.2, .ratio = 0.6 },
        },
        .self_vulnerabilities = &.{},
        .quality = .excellent,
        .durability = 2.0,
        .thickness = 1.0,
        .hardness = 0.8,
        .flexibility = 0.1,
    };

    // For tests that need no resistances
    pub const bare = Material{
        .name = "bare",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{},
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 1.0,
        .thickness = 0.0,
        .hardness = 0.0,
        .flexibility = 1.0,
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
    },
};

fn makeTestBody(alloc: std.mem.Allocator) !body.Body {
    return body.Body.fromPlan(alloc, &TestBodyPlan);
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

test "getMaterialResistance returns specific resistance when defined" {
    // Mail has specific slash resistance
    const res = getMaterialResistance(&TestMaterials.mail, .slash);
    try std.testing.expectEqual(@as(f32, 0.3), res.threshold);
    try std.testing.expectEqual(@as(f32, 0.3), res.ratio);

    // Plate has different pierce resistance
    const plate_res = getMaterialResistance(&TestMaterials.plate, .pierce);
    try std.testing.expectEqual(@as(f32, 0.4), plate_res.threshold);
    try std.testing.expectEqual(@as(f32, 0.3), plate_res.ratio);
}

test "getMaterialResistance returns default for undefined damage type" {
    // Mail has no fire resistance defined
    const res = getMaterialResistance(&TestMaterials.mail, .fire);
    try std.testing.expectEqual(@as(f32, 0.0), res.threshold);
    try std.testing.expectEqual(@as(f32, 1.0), res.ratio);

    // Bare material has no resistances at all
    const bare_res = getMaterialResistance(&TestMaterials.bare, .slash);
    try std.testing.expectEqual(@as(f32, 0.0), bare_res.threshold);
    try std.testing.expectEqual(@as(f32, 1.0), bare_res.ratio);
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

test "resolveThroughArmour: hardness deflects attack" {
    const alloc = std.testing.allocator;

    // Plate has hardness = 0.8, totality = .intimidating (5% gap)
    // Use .total totality to eliminate gap chance
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
    const packet = damage.Packet{ .amount = 1.0, .kind = .slash, .penetration = 1.0 };

    // Find a seed that deflects (second float < 0.8 hardness)
    var seed: u64 = 0;
    while (seed < 100) : (seed += 1) {
        var prng = testRng(seed);
        var rng = prng.random();

        const initial_integrity = armor.coverage[0].integrity;
        const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

        // If deflected: amount=0, layers_hit=1, minor armor damage
        if (result.remaining.amount == 0 and result.layers_hit == 1) {
            // Armor took 10% of original damage
            const integrity_loss = initial_integrity - armor.coverage[0].integrity;
            try std.testing.expect(integrity_loss > 0);
            try std.testing.expect(integrity_loss <= packet.amount * 0.15); // some tolerance
            break;
        }

        // Reset for next attempt
        armor.coverage[0].integrity = TestMaterials.plate.durability * Quality.excellent.durabilityMult();
    }
}

test "resolveThroughArmour: resistance threshold blocks weak attacks" {
    const alloc = std.testing.allocator;

    // Plate has slash threshold=0.5 - attacks below this are blocked
    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .total,
        }},
    };

    // Create material with 0 hardness to skip deflection
    const soft_plate = Material{
        .name = "soft plate",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{
            .{ .damage = .slash, .threshold = 0.5, .ratio = 0.2 },
        },
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 2.0,
        .thickness = 1.0,
        .hardness = 0.0, // no deflection
        .flexibility = 0.1,
    };

    const soft_template = Template{
        .id = 102,
        .name = "soft plate",
        .material = &soft_plate,
        .pattern = &solid_pattern,
    };

    var bod = try makeTestBody(alloc);
    defer bod.deinit();

    var armor = try Instance.init(alloc, &soft_template, null);
    defer armor.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&armor};
    try stack.buildFromEquipped(&bod, &equipped);

    const torso_idx = resolvePartIndex(&bod, .torso, .center).?;

    // Attack below threshold
    const weak_packet = damage.Packet{ .amount = 0.3, .kind = .slash, .penetration = 1.0 };
    var prng = testRng(42);
    var rng = prng.random();

    const initial_integrity = armor.coverage[0].integrity;
    const result = resolveThroughArmour(&stack, torso_idx, weak_packet, &rng);

    // Attack blocked
    try std.testing.expectEqual(@as(f32, 0), result.remaining.amount);
    try std.testing.expectEqual(@as(u8, 1), result.layers_hit);

    // Minor armor wear (5% of attack)
    const integrity_loss = initial_integrity - armor.coverage[0].integrity;
    try std.testing.expect(integrity_loss > 0);
    try std.testing.expect(integrity_loss <= weak_packet.amount * 0.1);
}

test "resolveThroughArmour: damage reduction applies correctly" {
    const alloc = std.testing.allocator;

    // Material with threshold=0.1, ratio=0.7 for pierce (mail)
    const solid_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Mail,
            .totality = .total,
        }},
    };

    // Use mail but with 0 hardness for predictable test
    const test_mail = Material{
        .name = "test mail",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{
            .{ .damage = .pierce, .threshold = 0.1, .ratio = 0.7 },
        },
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 1.0,
        .thickness = 0.5,
        .hardness = 0.0,
        .flexibility = 0.5,
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

    // Attack: amount=1.0, threshold=0.1, ratio=0.7
    // Expected: (1.0 - 0.1) * 0.7 = 0.63 passes through
    const packet = damage.Packet{ .amount = 1.0, .kind = .pierce, .penetration = 2.0 };
    var prng = testRng(42);
    var rng = prng.random();

    const result = resolveThroughArmour(&stack, torso_idx, packet, &rng);

    const expected = (1.0 - 0.1) * 0.7;
    try std.testing.expectApproxEqAbs(expected, result.remaining.amount, 0.01);
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

    // Material with 0 hardness and minimal resistance for predictable behavior
    const thick_material = Material{
        .name = "thick",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{},
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 2.0,
        .thickness = 1.5,
        .hardness = 0.0,
        .flexibility = 0.1,
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

    // Material with high thickness but 0 hardness
    const thick_material = Material{
        .name = "thick",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{},
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 2.0,
        .thickness = 5.0, // very thick - would stop pierce
        .hardness = 0.0,
        .flexibility = 0.1,
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

    // Material with no hardness for predictable test
    const soft_mail = Material{
        .name = "soft mail",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{
            .{ .damage = .slash, .threshold = 0.0, .ratio = 0.5 },
        },
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 2.0,
        .thickness = 0.5,
        .hardness = 0.0,
        .flexibility = 0.5,
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
    var bod = try body.Body.fromPlan(alloc, &body.HumanoidPlan);
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

    // Material with 0 hardness for predictable test
    const test_mail = Material{
        .name = "test mail",
        .resistances = &.{},
        .vulnerabilities = &.{},
        .self_resistances = &.{
            .{ .damage = .slash, .threshold = 0.2, .ratio = 0.5 },
        },
        .self_vulnerabilities = &.{},
        .quality = .common,
        .durability = 1.0,
        .thickness = 0.3,
        .hardness = 0.0,
        .flexibility = 0.5,
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
        .amount = 1.0,
        .kind = .slash,
        .penetration = 1.0,
    };

    const torso_idx = bod.indexOf("torso").?;

    // 4. Resolve through armor
    var prng = testRng(42);
    var rng = prng.random();

    const armor_result = resolveThroughArmour(&stack, torso_idx, initial_packet, &rng);

    // Damage should be reduced: (1.0 - 0.2) * 0.5 = 0.4
    const expected_remaining = (1.0 - 0.2) * 0.5;
    try std.testing.expectApproxEqAbs(expected_remaining, armor_result.remaining.amount, 0.01);
    try std.testing.expectEqual(@as(u8, 1), armor_result.layers_hit);

    // 5. Apply remaining damage to body
    const body_result = try bod.applyDamageToPart(torso_idx, armor_result.remaining);

    // Should have created a wound with reduced severity compared to unarmored hit
    try std.testing.expect(body_result.wound.len > 0);

    // The wound severity should be lower than if we'd taken full damage
    const wound_severity = body_result.wound.worstSeverity();
    try std.testing.expect(@intFromEnum(wound_severity) < @intFromEnum(body.Severity.disabled));

    // Compare with unarmored damage
    var unarmored_bod = try body.Body.fromPlan(alloc, &body.HumanoidPlan);
    defer unarmored_bod.deinit();

    const unarmored_torso_idx = unarmored_bod.indexOf("torso").?;
    const unarmored_result = try unarmored_bod.applyDamageToPart(unarmored_torso_idx, initial_packet);

    // Unarmored should take more severe damage
    const unarmored_severity = unarmored_result.wound.worstSeverity();
    try std.testing.expect(@intFromEnum(unarmored_severity) >= @intFromEnum(wound_severity));
}
