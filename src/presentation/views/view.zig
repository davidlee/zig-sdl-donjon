// View - union of all view types, plus shared Renderable types
//
// Views are read-only lenses into World state.
// They expose what each screen needs and handle input to produce Commands.

const std = @import("std");
const s = @import("sdl3");
const infra = @import("infra");
const Command = infra.commands.Command;

const splash = @import("splash.zig");
const menu = @import("menu.zig");
const combat = @import("combat.zig");
const summary = @import("summary.zig");

// Asset identifiers - views reference assets by ID, UX resolves to textures
pub const AssetId = enum {
    splash_background,
    splash_tagline,
    // TODO: add more as needed
};

// Renderable primitives - what UX knows how to draw
pub const Renderable = union(enum) {
    sprite: Sprite,
    text: Text,
    rect: Rect,
    // TODO: add more as needed
};

pub const Sprite = struct {
    asset: AssetId,
    x: f32,
    y: f32,
    w: ?f32 = null, // null = use texture's native size
    h: ?f32 = null,
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
    key: s.keycode.Keycode,
};

// View union - active view determined by game state
pub const View = union(enum) {
    title: splash.TitleScreenView,
    menu: menu.MenuView,
    combat: combat.CombatView,
    summary: summary.SummaryView,

    pub fn handleInput(self: *View, event: InputEvent) ?Command {
        return switch (self.*) {
            .title => |*v| v.handleInput(event),
            .menu => |*v| v.handleInput(event),
            .combat => |*v| v.handleInput(event),
            .summary => |*v| v.handleInput(event),
        };
    }

    pub fn renderables(self: *const View, alloc: std.mem.Allocator) !std.ArrayList(Renderable) {
        return switch (self.*) {
            .title => |*v| v.renderables(alloc),
            .menu => |*v| v.renderables(alloc),
            .combat => |*v| v.renderables(alloc),
            .summary => |*v| v.renderables(alloc),
        };
    }
};
