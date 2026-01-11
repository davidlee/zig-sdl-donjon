// View - union of all view types, plus shared Renderable types
//
// Views are read-only lenses into World state.
// They expose what each screen needs and handle input to produce Commands.

const std = @import("std");
const s = @import("sdl3");
const infra = @import("infra");
const Command = infra.commands.Command;
const World = @import("../../domain/world.zig").World;

const title = @import("title.zig");
const menu = @import("menu.zig");
const combat = @import("combat/mod.zig");
const summary = @import("summary.zig");
pub const card = @import("card/mod.zig");
pub const vs = @import("../view_state.zig");
const types = @import("types.zig");

// Re-export from types.zig
pub const logical_w = types.logical_w;
pub const logical_h = types.logical_h;
pub const Point = types.Point;
pub const Rect = types.Rect;
pub const Color = types.Color;
pub const AssetId = types.AssetId;
pub const Renderable = types.Renderable;
pub const LogPane = types.LogPane;
pub const Card = types.Card;
pub const Sprite = types.Sprite;
pub const FontSize = types.FontSize;
pub const Text = types.Text;
pub const FilledRect = types.FilledRect;
pub const FilledTriangle = types.FilledTriangle;
pub const CircleOutline = types.CircleOutline;
pub const StanceWeights = types.StanceWeights;

// Re-export view state types (from types.zig)
pub const ViewState = types.ViewState;
pub const CombatUIState = types.CombatUIState;
pub const DragState = types.DragState;
pub const InputResult = types.InputResult;

// Re-export card view model
pub const CardViewModel = card.Model;
pub const CardState = card.State;

// View union - active view determined by game state
pub const View = union(enum) {
    title: title.View,
    menu: menu.View,
    combat: combat.View,
    summary: summary.View,

    pub fn handleInput(self: *View, event: s.events.Event, world: *const World, state: ViewState) InputResult {
        return switch (self.*) {
            .title => |*v| v.handleInput(event, world, state),
            .menu => |*v| v.handleInput(event, world, state),
            .combat => |*v| v.handleInput(event, world, state),
            .summary => |*v| v.handleInput(event, world, state),
        };
    }

    pub fn renderables(self: *const View, alloc: std.mem.Allocator, state: ViewState) !std.ArrayList(Renderable) {
        return switch (self.*) {
            .title => |*v| v.renderables(alloc, state),
            .menu => |*v| v.renderables(alloc, state),
            .combat => |*v| v.renderables(alloc, state),
            .summary => |*v| v.renderables(alloc, state),
        };
    }
};
