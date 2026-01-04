// SummaryView - encounter summary / loot screen
//
// Displays rewards, stats, loot choices after combat.

const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const World = @import("../../domain/world.zig").World;
const s = @import("sdl3");

const Renderable = view.Renderable;
const ViewState = view.ViewState;
const InputResult = view.InputResult;
const Command = infra.commands.Command;

pub const SummaryView = struct {
    world: *const World,

    pub fn init(world: *const World) SummaryView {
        return .{ .world = world };
    }

    pub fn handleInput(self: *SummaryView, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
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

    pub fn renderables(self: *const SummaryView, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        _ = self;
        _ = vs;
        const list = try std.ArrayList(Renderable).initCapacity(alloc, 16);
        // TODO: add summary renderables
        // - victory/defeat banner
        // - rewards list
        // - loot choices
        // - continue button
        return list;
    }
};
