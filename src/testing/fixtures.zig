//! Test fixtures for instantiating personas and common test setups.
//!
//! Usage:
//!   const fixtures = @import("testing/fixtures.zig");
//!   const personas = @import("data/personas.zig");
//!
//!   var handle = try fixtures.agentFromTemplate(alloc, &personas.Agents.ser_marcus);
//!   defer handle.deinit();
//!
//!   // Use handle.agent, handle.agents_map as needed

const std = @import("std");
const lib = @import("infra");
const SlotMap = @import("../domain/slot_map.zig").SlotMap;

const personas = @import("../data/personas.zig");
const body = @import("../domain/body.zig");
const combat = @import("../domain/combat.zig");
const weapon = @import("../domain/weapon.zig");
const stats = @import("../domain/stats.zig");
const ai = @import("../domain/ai.zig");
const entity = lib.entity;

const Agent = combat.Agent;
const Armament = combat.Armament;
const AgentTemplate = personas.AgentTemplate;
const ArmamentTemplate = personas.ArmamentTemplate;

// ============================================================================
// AgentHandle
// ============================================================================

/// Handle returned by agentFromTemplate. Owns all allocated resources.
/// Caller must call deinit() to free memory.
pub const AgentHandle = struct {
    alloc: std.mem.Allocator,
    agent: *Agent,
    agents_map: *SlotMap(*Agent),
    weapons: WeaponStorage,

    const WeaponStorage = union(enum) {
        none,
        single: *weapon.Instance,
        dual: struct {
            primary: *weapon.Instance,
            secondary: *weapon.Instance,
        },
    };

    pub fn deinit(self: *AgentHandle) void {
        self.agent.destroy(self.agents_map);
        switch (self.weapons) {
            .none => {},
            .single => |w| self.alloc.destroy(w),
            .dual => |d| {
                self.alloc.destroy(d.primary);
                self.alloc.destroy(d.secondary);
            },
        }
        self.agents_map.deinit();
        self.alloc.destroy(self.agents_map);
    }
};

/// Create an Agent from a template. Returns a handle that must be deinit'd.
pub fn agentFromTemplate(
    alloc: std.mem.Allocator,
    template: *const AgentTemplate,
) !AgentHandle {
    // Allocate agents map
    const agents_map = try alloc.create(SlotMap(*Agent));
    agents_map.* = try SlotMap(*Agent).init(alloc);
    errdefer {
        agents_map.deinit();
        alloc.destroy(agents_map);
    }

    // Convert DirectorKind to combat.Director
    const director: combat.Director = switch (template.director) {
        .player => .player,
        .noop_ai => ai.noop(),
    };

    // Create agent (body, resources, natural weapons derived from species)
    const agent = try Agent.init(
        alloc,
        agents_map,
        director,
        template.draw_style,
        template.species,
        template.base_stats,
    );
    agent.name = .{ .static = template.name };

    // Allocate and equip weapons if template specifies them
    var weapon_storage: AgentHandle.WeaponStorage = .none;
    switch (template.armament) {
        .unarmed => {}, // Agent already starts unarmed with natural weapons
        .single => |tmpl| {
            const w = try alloc.create(weapon.Instance);
            w.* = .{ .id = entity.ID{ .index = 0, .generation = 999 }, .template = tmpl };
            weapon_storage = .{ .single = w };
            agent.weapons = agent.weapons.withEquipped(.{ .single = w });
        },
        .dual => |d| {
            const primary = try alloc.create(weapon.Instance);
            primary.* = .{ .id = entity.ID{ .index = 0, .generation = 998 }, .template = d.primary };
            errdefer alloc.destroy(primary);

            const secondary = try alloc.create(weapon.Instance);
            secondary.* = .{ .id = entity.ID{ .index = 1, .generation = 997 }, .template = d.secondary };

            weapon_storage = .{ .dual = .{ .primary = primary, .secondary = secondary } };
            agent.weapons = agent.weapons.withEquipped(.{ .dual = .{ .primary = primary, .secondary = secondary } });
        },
    }

    return AgentHandle{
        .alloc = alloc,
        .agent = agent,
        .agents_map = agents_map,
        .weapons = weapon_storage,
    };
}

// ============================================================================
// Body damage utilities
// ============================================================================

/// Set the severity of parts matching the given tag (and optionally side).
/// Useful for testing body-gated features like natural weapon availability.
/// Returns the number of parts modified.
pub fn setPartSeverity(
    b: *body.Body,
    tag: body.PartTag,
    side: ?body.Side,
    severity: body.Severity,
) usize {
    var count: usize = 0;
    for (b.parts.items) |*part| {
        if (part.tag != tag) continue;
        if (side) |s| if (part.side != s) continue;
        part.severity = severity;
        count += 1;
    }
    return count;
}

/// Sever parts matching the given tag (and optionally side).
/// Sets is_severed = true on matching parts.
/// Returns the number of parts severed.
pub fn severPart(
    b: *body.Body,
    tag: body.PartTag,
    side: ?body.Side,
) usize {
    var count: usize = 0;
    for (b.parts.items) |*part| {
        if (part.tag != tag) continue;
        if (side) |s| if (part.side != s) continue;
        part.is_severed = true;
        count += 1;
    }
    return count;
}

// ============================================================================
// Tests
// ============================================================================

test "agentFromTemplate creates agent with correct name" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.grunni_the_desperate);
    defer handle.deinit();

    try std.testing.expectEqualStrings("Grunni the Desperate", handle.agent.name.value());
}

test "agentFromTemplate with single weapon" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.ser_marcus);
    defer handle.deinit();

    try std.testing.expect(handle.agent.weapons.equipped == .single);
    try std.testing.expectEqualStrings("knight's sword", handle.agent.weapons.equipped.single.template.name);
}

test "agentFromTemplate with dual wield" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.sword_and_board);
    defer handle.deinit();

    try std.testing.expect(handle.agent.weapons.equipped == .dual);
    try std.testing.expectEqualStrings("knight's sword", handle.agent.weapons.equipped.dual.primary.template.name);
    try std.testing.expectEqualStrings("buckler", handle.agent.weapons.equipped.dual.secondary.template.name);
}

test "agentFromTemplate player director" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.player_swordsman);
    defer handle.deinit();

    try std.testing.expect(handle.agent.director == .player);
}

test "agentFromTemplate noop_ai director" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.ser_marcus);
    defer handle.deinit();

    try std.testing.expect(handle.agent.director == .ai);
}

test "agentFromTemplate derives resources from species" {
    const alloc = std.testing.allocator;
    const species_mod = @import("../domain/species.zig");

    // Grunni is a DWARF - resources come from species
    var handle = try agentFromTemplate(alloc, &personas.Agents.grunni_the_desperate);
    defer handle.deinit();

    // DWARF has base_stamina=12, base_focus=8, base_blood=4.5
    try std.testing.expectEqual(species_mod.DWARF.base_stamina, handle.agent.stamina.current);
    try std.testing.expectEqual(species_mod.DWARF.base_stamina, handle.agent.stamina.max);
    try std.testing.expectEqual(species_mod.DWARF.base_focus, handle.agent.focus.max);
    try std.testing.expectEqual(species_mod.DWARF.base_blood, handle.agent.blood.max);
}

test "setPartSeverity damages matching parts" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.ser_marcus);
    defer handle.deinit();

    // Initially all parts healthy
    try std.testing.expect(handle.agent.body.hasFunctionalPart(.hand, .left));
    try std.testing.expect(handle.agent.body.hasFunctionalPart(.hand, .right));

    // Damage left hand to missing
    const count = setPartSeverity(&handle.agent.body, .hand, .left, .missing);
    try std.testing.expectEqual(@as(usize, 1), count);

    // Left hand no longer functional, right still is
    try std.testing.expect(!handle.agent.body.hasFunctionalPart(.hand, .left));
    try std.testing.expect(handle.agent.body.hasFunctionalPart(.hand, .right));
}

test "setPartSeverity with null side affects all matching" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.ser_marcus);
    defer handle.deinit();

    // Damage all hands (both sides)
    const count = setPartSeverity(&handle.agent.body, .hand, null, .missing);
    try std.testing.expectEqual(@as(usize, 2), count);

    // No functional hands
    try std.testing.expect(!handle.agent.body.hasFunctionalPart(.hand, null));
}

test "severPart severs matching parts" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.ser_marcus);
    defer handle.deinit();

    // Sever left arm
    const count = severPart(&handle.agent.body, .arm, .left);
    try std.testing.expectEqual(@as(usize, 1), count);

    // Left hand not functional (parent severed), right still is
    try std.testing.expect(!handle.agent.body.hasFunctionalPart(.hand, .left));
    try std.testing.expect(handle.agent.body.hasFunctionalPart(.hand, .right));
}
