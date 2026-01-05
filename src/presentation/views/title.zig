// Title screen view
//
// Displays title image and tagline. Any input starts the game.
// Access as: title.View

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

pub const View = struct {
    world: *const World,

    pub fn init(world: *const World) View {
        return .{ .world = world };
    }

    pub fn handleInput(self: *View, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = self;
        _ = world;
        _ = vs;
        const ok = switch (event) {
            .key_up => |data| (data.key.? == .space),
            .mouse_button_down => true,
            else => false,
        };
        if (ok) {
            return .{ .command = .{ .start_game = {} } };
        } else return .{};
    }

    pub fn renderables(self: *const View, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        _ = self;
        _ = vs;
        var list = try std.ArrayList(Renderable).initCapacity(alloc, 8);

        // Background image
        try list.append(alloc, .{ .sprite = .{
            .asset = AssetId.splash_background,
            .dst = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 },
        } });

        // Tagline
        try list.append(alloc, .{
            .sprite = .{
                .asset = AssetId.splash_tagline,
                .dst = .{ .x = 720, .y = 680, .w = 0, .h = 0 },
            },
        });

        return list;
    }
};
