//! Test personas - named characters, weapons, and encounters.
//!
//! Shared between tests and game proper. These are memorable fixtures
//! that cover common test scenarios while also serving as game content.
//!
//! Usage:
//!   const personas = @import("data/personas.zig");
//!   const grunni = personas.Agents.grunni_the_desperate;

const std = @import("std");

// TODO: T019 - define persona templates
//
// pub const Agents = struct {
//     /// Naked dwarf with a rock. Minimal baseline.
//     pub const grunni_the_desperate = AgentTemplate{ ... };
//
//     /// Cowardly goblin archer. Ranged, flees.
//     pub const snik = AgentTemplate{ ... };
//
//     /// Veteran human swordsman. Competent baseline.
//     pub const ser_marcus = AgentTemplate{ ... };
// };
//
// pub const Weapons = struct {
//     pub const thrown_rock = weapon.Template{ ... };
//     pub const maybe_haunted = weapon.Template{ ... };
// };
//
// pub const Encounters = struct {
//     pub const duel_at_sword_range = EncounterTemplate{ ... };
//     pub const goblin_ambush = EncounterTemplate{ ... };
// };

test "placeholder: personas not yet implemented" {
    // Will have validation tests once templates defined
}
