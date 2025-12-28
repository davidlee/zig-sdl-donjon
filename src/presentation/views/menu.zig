// MenuView - main menu screen
//
// Displays menu options, handles menu navigation.

const std = @import("std");
const view = @import("view.zig");
const commands = @import("../../commands.zig");
const World = @import("../../domain/world.zig").World;

const Renderable = view.Renderable;
const InputEvent = view.InputEvent;
const Command = commands.Command;

pub const MenuView = struct {
    world: *const World,

    pub fn init(world: *const World) MenuView {
        return .{ .world = world };
    }

    pub fn handleInput(self: *MenuView, event: InputEvent) ?Command {
        _ = self;
        switch (event) {
            .click => |_| {
                // TODO: hit test menu buttons
                return Command{ .start_game = {} };
            },
            .key => |_| {
                return null;
            },
        }
    }

    pub fn renderables(self: *const MenuView, alloc: std.mem.Allocator) !std.ArrayList(Renderable) {
        _ = self;
        var list = std.ArrayList(Renderable).init(alloc);
        // TODO: add menu renderables
        // - title sprite
        // - menu buttons
        return list;
    }
};
