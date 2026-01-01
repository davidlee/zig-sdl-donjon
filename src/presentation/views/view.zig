// View - union of all view types, plus shared Renderable types
//
// Views are read-only lenses into World state.
// They expose what each screen needs and handle input to produce Commands.

const std = @import("std");
const s = @import("sdl3");
const infra = @import("infra");
const Command = infra.commands.Command;
const World = @import("../../domain/world.zig").World;
const combat_log = @import("../combat_log.zig");

const splash = @import("splash.zig");
const menu = @import("menu.zig");
const combat = @import("combat.zig");
const summary = @import("summary.zig");
pub const card_view = @import("card_view.zig");
pub const vs = @import("../view_state.zig");

pub const logical_w = 1920;
pub const logical_h = 1080;

// Re-export SDL types for view layer
pub const Point = s.rect.FPoint;
pub const Rect = s.rect.FRect;
pub const Color = s.pixels.Color;

// Re-export view state types
pub const ViewState = vs.ViewState;
pub const CombatState = vs.CombatState;
pub const DragState = vs.DragState;

// Re-export card view model
pub const CardViewModel = card_view.CardViewModel;
pub const CardState = card_view.CardState;

// Asset identifiers - views reference assets by ID, UX resolves to textures
pub const AssetId = enum {
    splash_background,
    splash_tagline,
    player_halberdier,
    fredrick_snail,
    thief,
    end_turn,
};

// Renderable primitives - what UX knows how to draw
pub const Renderable = union(enum) {
    sprite: Sprite,
    text: Text,
    filled_rect: FilledRect,
    card: Card,
    log_pane: LogPane,
};

/// Combat log pane - UX renders with texture caching
pub const LogPane = struct {
    entries: []const combat_log.Entry,
    rect: Rect,
    scroll_offset: usize, // cache invalidation key
    entry_count: usize, // cache invalidation key
};

// Card renderable - UX will use CardRenderer to get/create texture
pub const Card = struct {
    model: CardViewModel,
    dst: Rect, // where to draw (position + size)
};

pub const Sprite = struct {
    asset: AssetId,
    dst: ?Rect = null, // null = texture's native size at (0,0)
    src: ?Rect = null, // null = entire texture
    rotation: f32 = 0,
    alpha: u8 = 255,
};

pub const FontSize = enum {
    small, // 14pt - combat log, UI details
    normal, // 24pt - general text
};

pub const Text = struct {
    content: []const u8,
    pos: Point,
    font_size: FontSize = .normal,
    color: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
};

pub const FilledRect = struct {
    rect: Rect,
    color: Color,
};

// Result from handleInput - command to execute + optional view state update
pub const InputResult = struct {
    command: ?Command = null,
    vs: ?ViewState = null,
};

// View union - active view determined by game state
pub const View = union(enum) {
    title: splash.TitleScreenView,
    menu: menu.MenuView,
    combat: combat.CombatView,
    summary: summary.SummaryView,

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
