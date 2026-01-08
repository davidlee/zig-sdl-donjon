//! Test fixtures for instantiating personas and common test setups.
//!
//! Usage:
//!   const fixtures = @import("testing/fixtures.zig");
//!   var handle = try fixtures.agentFromTemplate(alloc, &personas.Agents.grunni);
//!   defer handle.deinit();

const std = @import("std");

// TODO: T019 - implement fixture helpers
// - AgentHandle, WorldHandle structs with deinit
// - agentFromTemplate(alloc, template) -> AgentHandle
// - worldFromEncounter(alloc, template) -> WorldHandle
// - giveCard(world, agent, template_name) -> entity.ID

test "fixtures module compiles" {
    // Placeholder - will have real tests once implemented
}
