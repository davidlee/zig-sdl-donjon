// Encounter summary / loot screen
//
// Displays rewards, stats, loot choices after combat.
// Access as: summary.View

const std = @import("std");
const view_mod = @import("view.zig");
const infra = @import("infra");
const World = @import("../../domain/world.zig").World;
const s = @import("sdl3");

const Renderable = view_mod.Renderable;
const ViewState = view_mod.ViewState;
const InputResult = view_mod.InputResult;

pub const View = struct {
    world: *const World,

    pub fn init(world: *const World) View {
        return .{ .world = world };
    }

    pub fn handleInput(self: *View, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = self;
        _ = world;
        _ = vs;
        // Any key or click proceeds to world map
        const proceed = switch (event) {
            .key_up => |data| (data.key.? == .space or data.key.? == .return_key),
            .mouse_button_down => true,
            else => false,
        };
        if (proceed) {
            return .{ .command = .{ .collect_loot = {} } };
        }
        return .{};
    }

    pub fn renderables(self: *const View, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        _ = self;
        _ = vs;
        const list = try std.ArrayList(Renderable).initCapacity(alloc, 16);
        // TODO: add summary renderables
        return list;
    }
};
