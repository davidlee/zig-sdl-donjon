// Presentation module - SDL-dependent rendering and input
//
// This is the only place SDL should be imported in the codebase.
// Domain code must not depend on this module.

pub const sdl = @import("sdl3");

pub const graphics = @import("graphics.zig");
pub const controls = @import("controls.zig");

// Type aliases
pub const UX = graphics.UX;
