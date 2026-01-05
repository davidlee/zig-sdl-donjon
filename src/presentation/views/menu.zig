// Main menu view
//
// Displays menu options, handles menu navigation.
// Access as: menu.View

const std = @import("std");
const view_mod = @import("view.zig");
const infra = @import("infra");
const s = @import("sdl3");
const World = @import("../../domain/world.zig").World;

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
        _ = event;
        _ = world;
        _ = vs;
        return .{};
    }

    pub fn renderables(self: *const View, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        _ = self;
        _ = vs;
        const list = try std.ArrayList(Renderable).initCapacity(alloc, 8);
        // TODO: add menu renderables
        return list;
    }
};
