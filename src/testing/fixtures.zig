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

    // Allocate weapons and build Armament
    var weapon_storage: AgentHandle.WeaponStorage = .none;
    const armament: Armament = switch (template.armament) {
        .unarmed => undefined, // Will need to handle this case
        .single => |tmpl| blk: {
            const w = try alloc.create(weapon.Instance);
            w.* = .{ .id = entity.ID{ .index = 0, .generation = 999 }, .template = tmpl };
            weapon_storage = .{ .single = w };
            break :blk .{ .single = w };
        },
        .dual => |d| blk: {
            const primary = try alloc.create(weapon.Instance);
            primary.* = .{ .id = entity.ID{ .index = 0, .generation = 998 }, .template = d.primary };
            errdefer alloc.destroy(primary);

            const secondary = try alloc.create(weapon.Instance);
            secondary.* = .{ .id = entity.ID{ .index = 1, .generation = 997 }, .template = d.secondary };

            weapon_storage = .{ .dual = .{ .primary = primary, .secondary = secondary } };
            break :blk .{ .dual = .{ .primary = primary, .secondary = secondary } };
        },
    };

    // Convert DirectorKind to combat.Director
    const director: combat.Director = switch (template.director) {
        .player => .player,
        .noop_ai => ai.noop(),
    };

    // Create body from plan
    const agent_body = try body.Body.fromPlan(alloc, template.body_plan);

    // Create agent
    const agent = try Agent.init(
        alloc,
        agents_map,
        director,
        template.draw_style,
        template.base_stats,
        agent_body,
        template.stamina,
        template.focus,
        template.blood,
        armament,
    );

    // Set name
    agent.name = .{ .static = template.name };

    return AgentHandle{
        .alloc = alloc,
        .agent = agent,
        .agents_map = agents_map,
        .weapons = weapon_storage,
    };
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

    try std.testing.expect(handle.agent.weapons == .single);
    try std.testing.expectEqualStrings("knight's sword", handle.agent.weapons.single.template.name);
}

test "agentFromTemplate with dual wield" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.sword_and_board);
    defer handle.deinit();

    try std.testing.expect(handle.agent.weapons == .dual);
    try std.testing.expectEqualStrings("knight's sword", handle.agent.weapons.dual.primary.template.name);
    try std.testing.expectEqualStrings("buckler", handle.agent.weapons.dual.secondary.template.name);
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

test "agentFromTemplate respects stats" {
    const alloc = std.testing.allocator;
    var handle = try agentFromTemplate(alloc, &personas.Agents.grunni_the_desperate);
    defer handle.deinit();

    // Grunni has stamina 8/8
    try std.testing.expectEqual(@as(f32, 8.0), handle.agent.stamina.current);
    try std.testing.expectEqual(@as(f32, 8.0), handle.agent.stamina.max);
}
