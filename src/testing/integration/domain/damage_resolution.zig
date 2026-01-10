//! Damage resolution integration tests.
//!
//! Tests the armour → tissue → wound pipeline with explicit axis values.
//! Validates the 3-axis physics model (geometry/energy/rigidity) flows
//! correctly through material layers.

const std = @import("std");
const testing = std.testing;

const root = @import("integration_root");
const domain = root.domain;
const damage = domain.damage;
const body = domain.body;
const body_list = domain.body_list;
const armour = domain.armour;

const Material = armour.Material;
const Pattern = armour.Pattern;
const Template = armour.Template;
const Instance = armour.Instance;
const Stack = armour.Stack;

// ============================================================================
// Test Materials - Predictable coefficients for test assertions
// ============================================================================

const TestMaterial = struct {
    /// Plate: high deflection, low absorption, blocks penetrating attacks
    const plate = Material{
        .name = "test plate",
        .deflection = 0.8, // blocks 80% of geometry
        .absorption = 0.2, // absorbs 20% of energy
        .dispersion = 0.1, // spreads 10% of rigidity
        .geometry_threshold = 0.3,
        .geometry_ratio = 0.4,
        .energy_threshold = 0.5,
        .energy_ratio = 0.3,
        .rigidity_threshold = 0.4,
        .rigidity_ratio = 0.3,
        .thickness = 0.5, // cm
        .durability = 100,
    };

    /// Padding: low deflection, high absorption, good energy dispersion
    const padding = Material{
        .name = "test padding",
        .deflection = 0.1, // blocks 10% of geometry
        .absorption = 0.6, // absorbs 60% of energy
        .dispersion = 0.5, // spreads 50% of rigidity
        .geometry_threshold = 0.1,
        .geometry_ratio = 0.8,
        .energy_threshold = 0.2,
        .energy_ratio = 0.5,
        .rigidity_threshold = 0.1,
        .rigidity_ratio = 0.6,
        .thickness = 1.0, // cm
        .durability = 50,
    };
};

// ============================================================================
// Helper Functions
// ============================================================================

fn testRng(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

fn makeArmourInstance(
    alloc: std.mem.Allocator,
    material: *const Material,
    part_tag: body.PartTag,
    layer: armour.InstanceCoverage.Layer,
) !*Instance {
    const pattern = try alloc.create(Pattern);
    const coverage = try alloc.create(armour.PatternCoverage);
    const part_tags = try alloc.alloc(body.PartTag, 1);
    part_tags[0] = part_tag;
    coverage.* = .{
        .part_tags = part_tags,
        .side = .center,
        .layer = layer,
        .totality = .total, // 100% coverage, no gaps
    };
    pattern.* = .{ .coverage = @ptrCast(&[_]armour.PatternCoverage{coverage.*}) };

    const template = try alloc.create(Template);
    template.* = .{
        .id = 999,
        .name = "test armour",
        .material = material,
        .pattern = pattern,
    };

    var instance = try Instance.init(alloc, template, null);
    return &instance;
}

// ============================================================================
// Integration Tests
// ============================================================================

test "pierce vs unarmoured arm: penetrates through tissue layers" {
    const alloc = testing.allocator;

    // Setup: create body, get arm part
    var bod = try body.Body.fromPlan(alloc, "humanoid", null);
    defer bod.deinit();

    const arm_idx = bod.indexOf("left_arm").?;

    // Pierce attack with moderate penetration
    const packet = damage.Packet{
        .amount = 8.0,
        .kind = .pierce,
        .penetration = 5.0, // 5 cm penetration
        .geometry = 0.6, // good blade geometry
        .energy = 8.0, // joules
        .rigidity = 0.5,
    };

    // Apply damage
    const result = try bod.applyDamageToPart(arm_idx, packet);

    // Pierce should reach multiple layers
    try testing.expect(result.wound.len >= 2);

    // Should damage skin (outermost) and at least fat
    const skin_sev = result.wound.severityAt(.skin);
    const fat_sev = result.wound.severityAt(.fat);
    try testing.expect(skin_sev != .none);
    try testing.expect(fat_sev != .none);

    // Verify part took damage (severity should be non-zero)
    const arm_part = &bod.parts.items[arm_idx];
    try testing.expect(arm_part.severity != .none);
}

test "bludgeon vs unarmoured torso: energy transfers through layers" {
    const alloc = testing.allocator;

    var bod = try body.Body.fromPlan(alloc, "humanoid", null);
    defer bod.deinit();

    const torso_idx = bod.indexOf("torso").?;

    // Bludgeon attack: high energy, low geometry, high rigidity
    const packet = damage.Packet{
        .amount = 15.0,
        .kind = .bludgeon,
        .penetration = 1.0, // minimal penetration
        .geometry = 0.2, // blunt weapon
        .energy = 20.0, // high impact
        .rigidity = 0.8, // very rigid (hammer)
    };

    const result = try bod.applyDamageToPart(torso_idx, packet);

    // Bludgeon should damage multiple layers via energy transfer
    try testing.expect(result.wound.len >= 2);

    // Energy transfers inward - muscle should take damage
    const muscle_sev = result.wound.severityAt(.muscle);
    try testing.expect(muscle_sev != .none);
}

test "slash with insufficient penetration: stops at bone" {
    const alloc = testing.allocator;

    var bod = try body.Body.fromPlan(alloc, "humanoid", null);
    defer bod.deinit();

    const arm_idx = bod.indexOf("left_arm").?;

    // Slash with very limited penetration (1 cm vs ~8 cm arm thickness)
    const packet = damage.Packet{
        .amount = 10.0,
        .kind = .slash,
        .penetration = 1.0, // only 1 cm
        .geometry = 0.5,
        .energy = 10.0,
        .rigidity = 0.6,
    };

    const result = try bod.applyDamageToPart(arm_idx, packet);

    // With 1 cm penetration vs ~8 cm arm, should only reach outer layers
    // Arm "limb" tissue: skin (0.1), fat (0.25), muscle (0.45), tendon (0.05), nerve (0.02), bone (0.13)
    // Layer thicknesses: skin = 0.8 cm, fat = 2.0 cm, muscle = 3.6 cm...
    // 1 cm penetration should stop after skin or early in fat

    // Should NOT reach bone
    const bone_sev = result.wound.severityAt(.bone);
    try testing.expect(bone_sev == .none);

    // Should damage outer layers
    const skin_sev = result.wound.severityAt(.skin);
    try testing.expect(skin_sev != .none);
}

test "armour reduces damage severity" {
    const alloc = testing.allocator;

    // Create two bodies for comparison
    var armoured_bod = try body.Body.fromPlan(alloc, "humanoid", null);
    defer armoured_bod.deinit();
    var unarmoured_bod = try body.Body.fromPlan(alloc, "humanoid", null);
    defer unarmoured_bod.deinit();

    const torso_idx = armoured_bod.indexOf("torso").?;

    // Setup plate armour on torso
    const plate_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .total,
        }},
    };
    const plate_template = Template{
        .id = 100,
        .name = "test plate",
        .material = &TestMaterial.plate,
        .pattern = &plate_pattern,
    };
    var plate_instance = try Instance.init(alloc, &plate_template, null);
    defer plate_instance.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{&plate_instance};
    try stack.buildFromEquipped(&armoured_bod, &equipped);

    // Slash attack
    const packet = damage.Packet{
        .amount = 12.0,
        .kind = .slash,
        .penetration = 3.0,
        .geometry = 0.6,
        .energy = 12.0,
        .rigidity = 0.6,
    };

    // Resolve through armour
    var prng = testRng(42);
    var rng = prng.random();
    const armour_result = armour.resolveThroughArmour(&stack, torso_idx, packet, &rng);

    // Apply remaining damage to armoured body
    const armoured_result = try armoured_bod.applyDamageToPart(torso_idx, armour_result.remaining);

    // Apply full damage to unarmoured body
    const unarmoured_result = try unarmoured_bod.applyDamageToPart(torso_idx, packet);

    // Armour should reduce overall severity
    const armoured_severity = armoured_result.wound.worstSeverity();
    const unarmoured_severity = unarmoured_result.wound.worstSeverity();

    // Unarmoured should take at least as much damage
    try testing.expect(@intFromEnum(unarmoured_severity) >= @intFromEnum(armoured_severity));

    // Armour should have absorbed some energy
    try testing.expect(armour_result.remaining.amount < packet.amount);
}

test "plate deflects pierce, padding absorbs bludgeon" {
    const alloc = testing.allocator;

    var bod = try body.Body.fromPlan(alloc, "humanoid", null);
    defer bod.deinit();

    const torso_idx = bod.indexOf("torso").?;

    // Setup: plate over padding (realistic layering)
    const padding_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Gambeson,
            .totality = .total,
        }},
    };
    const padding_template = Template{
        .id = 101,
        .name = "test padding",
        .material = &TestMaterial.padding,
        .pattern = &padding_pattern,
    };
    var padding_instance = try Instance.init(alloc, &padding_template, null);
    defer padding_instance.deinit(alloc);

    const plate_pattern = Pattern{
        .coverage = &.{.{
            .part_tags = &.{.torso},
            .side = .center,
            .layer = .Plate,
            .totality = .total,
        }},
    };
    const plate_template = Template{
        .id = 100,
        .name = "test plate",
        .material = &TestMaterial.plate,
        .pattern = &plate_pattern,
    };
    var plate_instance = try Instance.init(alloc, &plate_template, null);
    defer plate_instance.deinit(alloc);

    var stack = Stack.init(alloc);
    defer stack.deinit();
    var equipped = [_]*Instance{ &plate_instance, &padding_instance };
    try stack.buildFromEquipped(&bod, &equipped);

    // Test 1: Pierce attack - plate should deflect geometry
    const pierce_packet = damage.Packet{
        .amount = 10.0,
        .kind = .pierce,
        .penetration = 2.0,
        .geometry = 0.7, // high geometry
        .energy = 8.0,
        .rigidity = 0.5,
    };

    var prng = testRng(42);
    var rng = prng.random();
    const pierce_result = armour.resolveThroughArmour(&stack, torso_idx, pierce_packet, &rng);

    // Plate deflection (0.8) should heavily reduce geometry
    // geometry * (1 - 0.8) = 0.7 * 0.2 = 0.14, minus thickness 0.5 = negative, clamped to 0
    try testing.expect(pierce_result.remaining.geometry < pierce_packet.geometry * 0.3);

    // Test 2: Bludgeon attack - padding should absorb energy
    const bludgeon_packet = damage.Packet{
        .amount = 15.0,
        .kind = .bludgeon,
        .penetration = 1.0,
        .geometry = 0.2, // low geometry
        .energy = 20.0, // high energy
        .rigidity = 0.8,
    };

    prng = testRng(43);
    rng = prng.random();
    const bludgeon_result = armour.resolveThroughArmour(&stack, torso_idx, bludgeon_packet, &rng);

    // Combined absorption: plate (0.2) then padding (0.6)
    // First layer: 20 * (1 - 0.2) = 16
    // Second layer: 16 * (1 - 0.6) = 6.4
    // Expected remaining energy ~6.4
    try testing.expectApproxEqAbs(6.4, bludgeon_result.remaining.energy, 0.5);
}

test "layer damage accumulates correctly through tissue stack" {
    const alloc = testing.allocator;

    var bod = try body.Body.fromPlan(alloc, "humanoid", null);
    defer bod.deinit();

    const arm_idx = bod.indexOf("left_arm").?;

    // High-energy pierce that should damage multiple layers
    const packet = damage.Packet{
        .amount = 20.0,
        .kind = .pierce,
        .penetration = 10.0, // enough to reach bone
        .geometry = 0.7,
        .energy = 25.0,
        .rigidity = 0.6,
    };

    const result = try bod.applyDamageToPart(arm_idx, packet);

    // Count damaged layers
    var damaged_layer_count: u8 = 0;
    for (result.wound.slice()) |entry| {
        if (entry.severity != .none) {
            damaged_layer_count += 1;
        }
    }

    // Should damage at least 3 layers (skin, fat, muscle minimum)
    try testing.expect(damaged_layer_count >= 3);

    // Outer layers should generally take more damage (they see unshielded axes)
    const skin_sev = @intFromEnum(result.wound.severityAt(.skin));
    const muscle_sev = @intFromEnum(result.wound.severityAt(.muscle));
    const bone_sev = @intFromEnum(result.wound.severityAt(.bone));

    // Skin faces full axes before any shielding
    try testing.expect(skin_sev >= muscle_sev);
    // With high penetration, bone should be reached
    try testing.expect(bone_sev > 0);
}
