// Shared types for the presentation/views layer
//
// Contains Renderable primitives and common type re-exports.
// Views produce Renderables; UX consumes them.

const s = @import("sdl3");
const infra = @import("infra");
const Command = infra.commands.Command;
const combat_log = @import("../combat_log.zig");
const vs = @import("../view_state.zig");

pub const logical_w = 1920;
pub const logical_h = 1080;

// Re-export SDL types for view layer
pub const Point = s.rect.FPoint;
pub const Rect = s.rect.FRect;
pub const Color = s.pixels.Color;

// Asset identifiers - views reference assets by ID, UX resolves to textures
pub const AssetId = enum {
    splash_background,
    splash_tagline,
    player_halberdier,
    fredrick_snail,
    thief,
    end_turn,
    // Rune icons for modifier cards
    rune_eo,
    rune_th,
    rune_u,
    rune_y,
    rune_f,
    // Status overlays
    skull,
};

// Renderable primitives - what UX knows how to draw
pub const Renderable = union(enum) {
    sprite: Sprite,
    text: Text,
    filled_rect: FilledRect,
    filled_triangle: FilledTriangle,
    circle_outline: CircleOutline,
    card: Card,
    log_pane: LogPane,
    stance_weights: StanceWeights,
};

/// Combat log pane - UX renders with texture caching
pub const LogPane = struct {
    entries: []const combat_log.Entry,
    rect: Rect,
    scroll_y: i32, // pixel offset into texture (0 = bottom/most recent visible)
    entry_count: usize, // cache invalidation key
};

// Card renderable - UX will use CardRenderer to get/create texture
pub const Card = struct {
    model: @import("card/model.zig").Model,
    dst: Rect, // where to draw (position + size)
    rotation: f32 = 0, // degrees, positive = clockwise
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

pub const FilledTriangle = struct {
    points: [3]Point,
    color: Color,
};

pub const CircleOutline = struct {
    center: Point,
    radius: f32,
    color: Color,
    thickness: f32 = 2,
};

/// Stance weight display - graphics layer formats the values
pub const StanceWeights = struct {
    attack: f32,
    defense: f32,
    movement: f32,
    pos: Point,
};

// Re-export view state types
pub const ViewState = vs.ViewState;
pub const CombatUIState = vs.CombatUIState;
pub const DragState = vs.DragState;

// Result from handleInput - command to execute + optional view state update
pub const InputResult = struct {
    command: ?Command = null,
    vs: ?ViewState = null,
};
