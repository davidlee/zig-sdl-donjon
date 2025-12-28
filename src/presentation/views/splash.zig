// TitleScreenView - splash/title screen
//
// Displays title image and tagline. Any input starts the game.

const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const s = @import("sdl3");
const World = @import("../../domain/world.zig").World;

const Renderable = view.Renderable;
const ViewState = view.ViewState;
const InputResult = view.InputResult;
const Command = infra.commands.Command;
const AssetId = view.AssetId;

pub const TitleScreenView = struct {
    world: *const World,

    pub fn init(world: *const World) TitleScreenView {
        return .{ .world = world };
    }

    pub fn handleInput(self: *TitleScreenView, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = self;
        _ = world;
        _ = vs;
        switch (event) {
            .key_down, .mouse_button_down => return .{ .command = .{ .start_game = {} } },
            else => {},
        }
        return .{};
    }

    pub fn renderables(self: *const TitleScreenView, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        _ = self;
        _ = vs;
        var list = try std.ArrayList(Renderable).initCapacity(alloc, 8);

        // Background image (null dst = native size at origin)
        try list.append(alloc, .{ .sprite = .{
            .asset = AssetId.splash_background,
        } });

        // Tagline
        try list.append(alloc, .{
            .sprite = .{
                .asset = AssetId.splash_tagline,
                .dst = .{ .x = 160, .y = 420, .w = 0, .h = 0 }, // w/h ignored when 0
            },
        });

        return list;
    }
};
