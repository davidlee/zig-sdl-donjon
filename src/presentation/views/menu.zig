// MenuView - main menu screen
//
// Displays menu options, handles menu navigation.

const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const s = @import("sdl3");
const World = @import("../../domain/world.zig").World;

const Renderable = view.Renderable;
const ViewState = view.ViewState;
const InputResult = view.InputResult;
const Command = infra.commands.Command;

pub const MenuView = struct {
    world: *const World,

    pub fn init(world: *const World) MenuView {
        return .{ .world = world };
    }

    pub fn handleInput(self: *MenuView, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = self;
        _ = event;
        _ = world;
        _ = vs;
        return .{};
    }

    pub fn renderables(self: *const MenuView, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        _ = self;
        _ = vs;
        const list = try std.ArrayList(Renderable).initCapacity(alloc, 8);
        // TODO: add menu renderables
        // - title sprite
        // - menu buttons
        return list;
    }
};
