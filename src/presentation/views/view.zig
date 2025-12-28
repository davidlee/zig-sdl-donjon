// View - union of all view types, plus shared Renderable types
//
// Views are read-only lenses into World state.
// They expose what each screen needs and handle input to produce Commands.

const std = @import("std");
const s = @import("sdl3");
const commands = @import("../../commands.zig");
const Command = commands.Command;

const menu = @import("menu.zig");
const combat = @import("combat.zig");
const summary = @import("summary.zig");

// Renderable primitives - what UX knows how to draw
pub const Renderable = union(enum) {
    sprite: Sprite,
    text: Text,
    rect: Rect,
    // TODO: add more as needed
};

pub const Sprite = struct {
    texture_id: u32, // index into texture atlas / asset manager
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    rotation: f32 = 0,
    alpha: f32 = 1.0,
};

pub const Text = struct {
    content: []const u8,
    x: f32,
    y: f32,
    size: f32 = 16,
    // color, font, etc.
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    fill_r: u8 = 0,
    fill_g: u8 = 0,
    fill_b: u8 = 0,
    fill_a: u8 = 255,
};

// Logical coordinates (for input hit testing)
pub const Point = struct {
    x: f32,
    y: f32,
};

// Input event (simplified from SDL)
pub const InputEvent = union(enum) {
    click: Point,
    key: u32,
};

// View union - active view determined by game state
pub const View = union(enum) {
    menu: menu.MenuView,
    combat: combat.CombatView,
    summary: summary.SummaryView,

    pub fn handleInput(self: *View, event: InputEvent) ?Command {
        return switch (self.*) {
            .menu => |*v| v.handleInput(event),
            .combat => |*v| v.handleInput(event),
            .summary => |*v| v.handleInput(event),
        };
    }

    pub fn renderables(self: *const View, alloc: std.mem.Allocator) !std.ArrayList(Renderable) {
        return switch (self.*) {
            .menu => |*v| v.renderables(alloc),
            .combat => |*v| v.renderables(alloc),
            .summary => |*v| v.renderables(alloc),
        };
    }
};
