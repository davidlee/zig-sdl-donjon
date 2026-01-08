//! Test personas - named characters, weapons, and encounters.
//!
//! Shared between tests and game proper. These are memorable fixtures
//! that cover common test scenarios while also serving as game content.
//!
//! Usage:
//!   const personas = @import("data/personas.zig");
//!   const template = personas.Agents.grunni_the_desperate;
//!   var handle = try fixtures.agentFromTemplate(alloc, template);

const std = @import("std");
const body = @import("../domain/body.zig");
const stats = @import("../domain/stats.zig");
const weapon = @import("../domain/weapon.zig");
const weapon_list = @import("../domain/weapon_list.zig");
const combat = @import("../domain/combat.zig");

// ============================================================================
// Template Types
// ============================================================================

/// How the agent is controlled. Stored as enum for comptime compatibility;
/// fixtures convert to combat.Director at runtime.
pub const DirectorKind = enum {
    player,
    noop_ai,
    // Future: aggressive_ai, cowardly_ai, etc.
};

/// Describes weapons without requiring runtime allocation.
/// Fixtures convert to combat.Armament by allocating weapon.Instance.
pub const ArmamentTemplate = union(enum) {
    unarmed,
    single: *const weapon.Template,
    dual: struct {
        primary: *const weapon.Template,
        secondary: *const weapon.Template,
    },
};

/// Blueprint for creating an Agent. All fields are comptime-safe.
pub const AgentTemplate = struct {
    name: []const u8,
    director: DirectorKind = .noop_ai,
    draw_style: combat.DrawStyle = .shuffled_deck,
    body_plan: []const body.PartDef = &body.HumanoidPlan,
    base_stats: stats.Block = stats.Block.splat(5),
    stamina: stats.Resource = stats.Resource.init(10.0, 10.0, 2.0),
    focus: stats.Resource = stats.Resource.init(3.0, 5.0, 3.0),
    blood: stats.Resource = stats.Resource.init(5.0, 5.0, 0.0),
    armament: ArmamentTemplate = .unarmed,
};

/// Blueprint for creating an Encounter.
pub const EncounterTemplate = struct {
    player: *const AgentTemplate,
    enemies: []const *const AgentTemplate,
    initial_range: combat.Reach = .sabre,
};

// ============================================================================
// Weapons (test-specific, supplement weapon_list.zig)
// ============================================================================

pub const Weapons = struct {
    /// Basic rock. Simplest possible weapon for minimal tests.
    pub const thrown_rock = weapon.Template{
        .name = "rock",
        .categories = &.{.improvised},
        .grip = .{ .one_handed = true },
        .length = 0.1,
        .weight = 0.5,
        .balance = 0.5,
        .swing = .{
            .name = "rock bash",
            .reach = .dagger,
            .damage_types = &.{.bludgeon},
            .accuracy = 0.6,
            .speed = 1.2,
            .damage = 0.5,
            .penetration = 0.0,
            .penetration_max = 0.2,
            .fragility = 0.1,
            .defender_modifiers = .{
                .reach = .dagger,
                .parry = 0.8,
                .deflect = 0.9,
                .block = 0.9,
                .fragility = 0.5,
            },
        },
        .thrust = null,
        .defence = .{
            .name = "rock defence",
            .reach = .dagger,
            .parry = 0.2,
            .deflect = 0.1,
            .block = 0.1,
            .fragility = 0.1,
        },
    };

    /// Garbage magic sword. Tests magic weapon paths without being OP.
    pub const maybe_haunted = weapon.Template{
        .name = "Maybe Haunted",
        .categories = &.{.sword},
        .grip = .{ .one_handed = true },
        .length = 0.8,
        .weight = 1.2,
        .balance = 0.4,
        .swing = .{
            .name = "haunted slash",
            .reach = .sabre,
            .damage_types = &.{.slash},
            .accuracy = 0.7,
            .speed = 0.9,
            .damage = 0.8,
            .penetration = 0.1,
            .penetration_max = 0.5,
            .fragility = 0.3,
            .defender_modifiers = .{
                .reach = .sabre,
                .parry = 0.7,
                .deflect = 0.6,
                .block = 0.8,
                .fragility = 1.0,
            },
        },
        .thrust = .{
            .name = "haunted thrust",
            .reach = .sabre,
            .damage_types = &.{.pierce},
            .accuracy = 0.65,
            .speed = 1.0,
            .damage = 0.7,
            .penetration = 0.2,
            .penetration_max = 0.7,
            .fragility = 0.4,
            .defender_modifiers = .{
                .reach = .sabre,
                .parry = 0.6,
                .deflect = 0.5,
                .block = 0.7,
                .fragility = 0.8,
            },
        },
        .defence = .{
            .name = "haunted defence",
            .reach = .sabre,
            .parry = 0.5,
            .deflect = 0.4,
            .block = 0.2,
            .fragility = 0.3,
        },
    };

    /// Simple shortbow for ranged tests.
    pub const shortbow = weapon.Template{
        .name = "shortbow",
        .categories = &.{.bow},
        .grip = .two_handed,
        .length = 1.0,
        .weight = 0.8,
        .balance = 0.5,
        .swing = null,
        .thrust = null,
        .defence = .{
            .name = "bow defence",
            .reach = .staff,
            .parry = 0.1,
            .deflect = 0.1,
            .block = 0.0,
            .fragility = 0.8,
        },
        .ranged = .{
            .projectile = .{
                .name = "arrow",
                .range_min = .sabre,
                .range_max = .abstract_far,
                .accuracy = 0.7,
                .damage_types = &.{.pierce},
                .damage = 0.6,
                .penetration = 0.3,
            },
        },
    };
};

// ============================================================================
// Agent Personas
// ============================================================================

pub const Agents = struct {
    /// Naked dwarf with a rock. Minimal baseline for simple tests.
    pub const grunni_the_desperate = AgentTemplate{
        .name = "Grunni the Desperate",
        .director = .noop_ai,
        .body_plan = &body.HumanoidPlan, // TODO: DwarfPlan when available
        .base_stats = stats.Block.splat(4),
        .stamina = stats.Resource.init(8.0, 8.0, 1.0),
        .focus = stats.Resource.init(2.0, 3.0, 1.0),
        .blood = stats.Resource.init(4.0, 4.0, 0.0),
        .armament = .{ .single = &Weapons.thrown_rock },
    };

    /// Cowardly goblin archer. Ranged, low stats.
    pub const snik = AgentTemplate{
        .name = "Snik",
        .director = .noop_ai,
        .body_plan = &body.HumanoidPlan, // TODO: GoblinPlan when available
        .base_stats = stats.Block.splat(3),
        .stamina = stats.Resource.init(5.0, 5.0, 1.0),
        .focus = stats.Resource.init(2.0, 2.0, 0.5),
        .blood = stats.Resource.init(3.0, 3.0, 0.0),
        .armament = .{ .single = &Weapons.shortbow },
    };

    /// Veteran human swordsman. Competent baseline enemy.
    pub const ser_marcus = AgentTemplate{
        .name = "Ser Marcus",
        .director = .noop_ai,
        .body_plan = &body.HumanoidPlan,
        .base_stats = stats.Block.splat(6),
        .stamina = stats.Resource.init(12.0, 12.0, 2.0),
        .focus = stats.Resource.init(4.0, 5.0, 2.0),
        .blood = stats.Resource.init(5.0, 5.0, 0.0),
        .armament = .{ .single = &weapon_list.knights_sword },
    };

    /// Shield-bearer for testing shield predicates.
    pub const shield_bearer = AgentTemplate{
        .name = "Shield Bearer",
        .director = .noop_ai,
        .body_plan = &body.HumanoidPlan,
        .base_stats = stats.Block.splat(5),
        .stamina = stats.Resource.init(10.0, 10.0, 2.0),
        .focus = stats.Resource.init(3.0, 4.0, 1.0),
        .blood = stats.Resource.init(5.0, 5.0, 0.0),
        .armament = .{ .single = &weapon_list.buckler },
    };

    /// Sword and shield dual wielder.
    pub const sword_and_board = AgentTemplate{
        .name = "Sword and Board",
        .director = .noop_ai,
        .body_plan = &body.HumanoidPlan,
        .base_stats = stats.Block.splat(5),
        .stamina = stats.Resource.init(10.0, 10.0, 2.0),
        .focus = stats.Resource.init(3.0, 4.0, 1.0),
        .blood = stats.Resource.init(5.0, 5.0, 0.0),
        .armament = .{ .dual = .{
            .primary = &weapon_list.knights_sword,
            .secondary = &weapon_list.buckler,
        } },
    };

    /// Player-controlled template for player-vs-enemy tests.
    pub const player_swordsman = AgentTemplate{
        .name = "Player",
        .director = .player,
        .body_plan = &body.HumanoidPlan,
        .base_stats = stats.Block.splat(5),
        .stamina = stats.Resource.init(10.0, 10.0, 2.0),
        .focus = stats.Resource.init(3.0, 5.0, 3.0),
        .blood = stats.Resource.init(5.0, 5.0, 0.0),
        .armament = .{ .single = &weapon_list.knights_sword },
    };

    /// Spear-wielder for reach tests.
    pub const spearman = AgentTemplate{
        .name = "Spearman",
        .director = .noop_ai,
        .body_plan = &body.HumanoidPlan,
        .base_stats = stats.Block.splat(5),
        .stamina = stats.Resource.init(10.0, 10.0, 2.0),
        .focus = stats.Resource.init(3.0, 4.0, 1.0),
        .blood = stats.Resource.init(5.0, 5.0, 0.0),
        .armament = .{ .single = &weapon_list.spear },
    };

    /// Dagger-wielder for short reach tests.
    pub const knifeman = AgentTemplate{
        .name = "Knifeman",
        .director = .noop_ai,
        .body_plan = &body.HumanoidPlan,
        .base_stats = stats.Block.splat(5),
        .stamina = stats.Resource.init(10.0, 10.0, 2.0),
        .focus = stats.Resource.init(3.0, 4.0, 1.0),
        .blood = stats.Resource.init(5.0, 5.0, 0.0),
        .armament = .{ .single = &weapon_list.dirk },
    };
};

// ============================================================================
// Encounter Personas
// ============================================================================

pub const Encounters = struct {
    /// 1v1 at sword range. Most common test scenario.
    pub const duel_at_sword_range = EncounterTemplate{
        .player = &Agents.player_swordsman,
        .enemies = &.{&Agents.ser_marcus},
        .initial_range = .sabre,
    };

    /// Player vs shield-bearer for shield predicate tests.
    pub const vs_shield_bearer = EncounterTemplate{
        .player = &Agents.player_swordsman,
        .enemies = &.{&Agents.shield_bearer},
        .initial_range = .sabre,
    };

    /// Player outnumbered by archers.
    pub const goblin_ambush = EncounterTemplate{
        .player = &Agents.grunni_the_desperate,
        .enemies = &.{ &Agents.snik, &Agents.snik, &Agents.snik },
        .initial_range = .spear,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "AgentTemplate compiles" {
    const t = Agents.grunni_the_desperate;
    try std.testing.expectEqualStrings("Grunni the Desperate", t.name);
    try std.testing.expect(t.armament == .single);
}

test "EncounterTemplate compiles" {
    const e = Encounters.duel_at_sword_range;
    try std.testing.expectEqualStrings("Player", e.player.name);
    try std.testing.expectEqual(@as(usize, 1), e.enemies.len);
}

test "Weapons compile" {
    try std.testing.expectEqualStrings("rock", Weapons.thrown_rock.name);
    try std.testing.expectEqualStrings("Maybe Haunted", Weapons.maybe_haunted.name);
}
