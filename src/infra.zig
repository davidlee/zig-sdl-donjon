const std = @import("std");

// helpers / utilities
pub const util = @import("util.zig");
pub const config = @import("config.zig");
pub const Config = config.Config;
pub const Cast = @import("util.zig").Cast;
// pub const random = @import("random.zig");

// 3rd party libs (SDL intentionally excluded - use presentation/mod.zig)
pub const zigfsm = @import("zigfsm");

// conveniences - not that much point but why not
pub const log = std.debug.print;
