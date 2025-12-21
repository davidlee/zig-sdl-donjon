/// Combat resolves encounters, implements the pipelines which apply player
/// stats & equipment to cards / moves, applies damage, etc.
/// 
const std = @import("std");
const lib = @import("infra"); 
const Event = @import("events.zig").Event; const
EventTag = std.meta.Tag(Event);

const EntityID = @import("entity.zig").EntityID; 
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const World = @import("world.zig").World;