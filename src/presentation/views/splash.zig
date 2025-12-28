// TitleScreenView - splash/title screen
//
// Displays title image and tagline. Any input starts the game.

const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const World = @import("../../domain/world.zig").World;

const Renderable = view.Renderable;
const InputEvent = view.InputEvent;
const Command = infra.commands.Command;
const AssetId = view.AssetId;

pub const TitleScreenView = struct {
    world: *const World,

    pub fn init(world: *const World) TitleScreenView {
        return .{ .world = world };
    }

    pub fn handleInput(self: *TitleScreenView, event: InputEvent) ?Command {
        _ = self;
        _ = event;
        // Any input starts the game
        return Command{ .start_game = {} };
    }

    pub fn renderables(self: *const TitleScreenView, alloc: std.mem.Allocator) !std.ArrayList(Renderable) {
        _ = self;
        var list = try std.ArrayList(Renderable).initCapacity(alloc, 8);

        // Background image
        try list.append(alloc, .{ .sprite = .{
            .asset = AssetId.splash_background,
            .x = 0,
            .y = 0,
        } });

        // Tagline
        try list.append(alloc, .{ .sprite = .{
            .asset = AssetId.splash_tagline,
            .x = 160,
            .y = 420,
        } });

        return list;
    }
};
