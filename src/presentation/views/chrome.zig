/// Chrome View - UI chrome (header, footer, sidebar with combat log).
///
/// Renders persistent UI elements around the game viewport:
/// - Header: status bars (stamina, focus), End Turn button
/// - Sidebar: combat log
/// - Footer: (placeholder)
const std = @import("std");
const view = @import("view.zig");
const s = @import("sdl3");
const World = @import("../../domain/world.zig").World;
const CombatLog = @import("../combat_log.zig").CombatLog;
const combat = @import("../../domain/combat.zig");

const Renderable = view.Renderable;
const ViewState = view.ViewState;
const InputResult = view.InputResult;
const Rect = s.rect.FRect;
const IRect = s.rect.IRect;
const Color = s.pixels.Color;
const Point = view.Point;
const AssetId = view.AssetId;

const logical_w = view.logical_w;
const logical_h = view.logical_h;

const colors = .{
    .black = Color{ .r = 0, .g = 0, .b = 0 },
    .dark = Color{ .r = 10, .g = 10, .b = 10 },
    .grey = Color{ .r = 20, .g = 20, .b = 20 },
};

pub const header_h: f32 = 80;
pub const footer_h: f32 = 100;
pub const sidebar_w: f32 = 500;

pub const origin = s.rect.FPoint{ .x = 0, .y = header_h };
pub const viewport = IRect{
    .x = 0,
    .y = @intFromFloat(header_h),
    .w = @intFromFloat(logical_w - sidebar_w),
    .h = @intFromFloat(logical_h - header_h - footer_h),
};

// Sidebar layout
const sidebar_x: f32 = logical_w - sidebar_w;
const sidebar_y: f32 = header_h;

const sidebar_rect = Rect{
    .x = sidebar_x,
    .y = sidebar_y,
    .w = sidebar_w,
    .h = logical_h - header_h - footer_h,
};

const scroll_speed: i32 = 40;

// --- Resource Bar (pip-style display) ---

const ResourceBar = struct {
    current: f32,
    available: f32,
    max_pips: u8,
    bar_colors: Colors,
    rect: Rect,

    const Colors = struct {
        background: Color,
        current: Color,
        available: Color,
    };

    const border: f32 = 3;
    const pip_spacing: f32 = 2;
    const trim: f32 = 4;
    const trim_color = Color{ .r = 10, .g = 10, .b = 10 };
    const black = Color{ .r = 0, .g = 0, .b = 0 };

    fn render(self: ResourceBar, alloc: std.mem.Allocator, list: *std.ArrayList(Renderable)) !void {
        const r_outer = self.rect;
        const r_inner = Rect{
            .x = r_outer.x + trim,
            .y = r_outer.y + trim,
            .w = r_outer.w - (2 * trim),
            .h = r_outer.h - (2 * trim),
        };

        try list.append(alloc, .{ .filled_rect = .{ .rect = r_outer, .color = trim_color } });
        try list.append(alloc, .{ .filled_rect = .{ .rect = r_inner, .color = black } });

        const pip_total_w = r_inner.w - (border * 2);
        const pip_w = (pip_total_w / @as(f32, @floatFromInt(self.max_pips))) - pip_spacing;
        const start_x = r_inner.x + border;
        const pip_y = r_inner.y + border;
        const pip_h = r_inner.h - border * 2;

        // Background pips
        for (0..self.max_pips) |n| {
            const m: f32 = @floatFromInt(n);
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing),
                    .y = pip_y,
                    .w = pip_w,
                    .h = pip_h,
                },
                .color = self.bar_colors.background,
            } });
        }

        // Current value pips
        const current_pips: usize = @intFromFloat(@ceil(self.current));
        for (0..current_pips) |n| {
            const m: f32 = @floatFromInt(n);
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing),
                    .y = pip_y,
                    .w = pip_w,
                    .h = pip_h,
                },
                .color = self.bar_colors.current,
            } });
        }

        // Available value pips (half height)
        const available_pips: usize = @intFromFloat(@ceil(self.available));
        for (0..available_pips) |n| {
            const m: f32 = @floatFromInt(n);
            try list.append(alloc, .{ .filled_rect = .{
                .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing) + border,
                    .y = pip_y,
                    .w = pip_w - border * 2,
                    .h = pip_h / 2,
                },
                .color = self.bar_colors.available,
            } });
        }
    }
};

// --- Status Chrome Layout ---
// Stacked bars with EndTurn button to the right:
//   [========= Stamina =========] [End]
//   [========= Focus   =========] [Trn]

const status_chrome = struct {
    const margin: f32 = 10;
    const bar_width: f32 = 400;
    const bar_height: f32 = 30;
    const bar_gap: f32 = 5;
    const max_pips: u8 = 20;

    const btn_width: f32 = 70;
    const btn_height: f32 = bar_height * 2 + bar_gap; // spans both bars

    // Position in header (screen coords)
    const start_x: f32 = logical_w - sidebar_w + margin;
    const start_y: f32 = margin;
    const btn_x: f32 = start_x + bar_width + margin;
    const btn_y: f32 = start_y;
};

// --- End Turn Button ---

const EndTurnButton = struct {
    rect: Rect,
    active: bool,

    fn init(turn_phase: ?combat.TurnPhase) EndTurnButton {
        const active = if (turn_phase) |phase|
            (phase == .player_card_selection or phase == .commit_phase)
        else
            false;
        return .{
            .active = active,
            .rect = .{
                .x = status_chrome.btn_x,
                .y = status_chrome.btn_y,
                .w = status_chrome.btn_width,
                .h = status_chrome.btn_height,
            },
        };
    }

    fn hitTest(self: EndTurnButton, screen_pt: Point) bool {
        return self.active and self.rect.pointIn(screen_pt);
    }

    fn renderable(self: EndTurnButton) ?Renderable {
        if (self.active) {
            return .{ .sprite = .{ .asset = AssetId.end_turn, .dst = self.rect } };
        }
        return null;
    }
};

// --- Status Bars ---

const StatusBars = struct {
    stamina: f32,
    stamina_available: f32,
    focus: f32,
    focus_available: f32,

    fn init(player: *const combat.Agent) StatusBars {
        return .{
            .stamina = player.stamina.current,
            .stamina_available = player.stamina.available,
            .focus = player.focus.current,
            .focus_available = player.focus.available,
        };
    }

    fn render(self: StatusBars, alloc: std.mem.Allocator, list: *std.ArrayList(Renderable)) !void {
        // Stamina bar (top)
        const stamina_bar = ResourceBar{
            .current = self.stamina,
            .available = self.stamina_available,
            .max_pips = status_chrome.max_pips,
            .bar_colors = .{
                .background = Color{ .r = 0, .g = 30, .b = 0 },
                .current = Color{ .r = 0, .g = 60, .b = 0 },
                .available = Color{ .r = 0, .g = 120, .b = 0 },
            },
            .rect = .{
                .x = status_chrome.start_x,
                .y = status_chrome.start_y,
                .w = status_chrome.bar_width,
                .h = status_chrome.bar_height,
            },
        };
        try stamina_bar.render(alloc, list);

        // Focus bar (below stamina)
        const focus_bar = ResourceBar{
            .current = self.focus,
            .available = self.focus_available,
            .max_pips = status_chrome.max_pips,
            .bar_colors = .{
                .background = Color{ .r = 0, .g = 0, .b = 40 },
                .current = Color{ .r = 0, .g = 0, .b = 90 },
                .available = Color{ .r = 0, .g = 0, .b = 180 },
            },
            .rect = .{
                .x = status_chrome.start_x,
                .y = status_chrome.start_y + status_chrome.bar_height + status_chrome.bar_gap,
                .w = status_chrome.bar_width,
                .h = status_chrome.bar_height,
            },
        };
        try focus_bar.render(alloc, list);
    }
};

// --- Chrome Background ---

const MenuBar = struct {
    fn render() []const Renderable {
        return &[_]Renderable{
            // Header
            .{ .filled_rect = .{
                .rect = .{ .x = 0, .y = 0, .w = logical_w, .h = header_h },
                .color = colors.grey,
            } },
            // Sidebar background
            .{ .filled_rect = .{
                .rect = .{
                    .x = logical_w - sidebar_w,
                    .y = header_h,
                    .w = sidebar_w,
                    .h = logical_h - header_h - footer_h,
                },
                .color = colors.grey,
            } },
            // Sidebar inner (black)
            .{ .filled_rect = .{
                .rect = .{
                    .x = logical_w - sidebar_w + 3,
                    .y = header_h,
                    .w = sidebar_w,
                    .h = logical_h - header_h - footer_h,
                },
                .color = colors.black,
            } },
            // Footer
            .{ .filled_rect = .{
                .rect = .{ .x = 0, .y = logical_h - footer_h, .w = logical_w, .h = footer_h },
                .color = colors.grey,
            } },
        };
    }
};

// --- Chrome View ---

pub const View = struct {
    world: *const World,
    combat_log: *CombatLog,

    pub fn init(world: *const World, combat_log: *CombatLog) View {
        return .{ .world = world, .combat_log = combat_log };
    }

    pub fn handleInput(self: *View, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = self;

        switch (event) {
            .mouse_button_up => |data| {
                // Use raw screen coords for header hit testing
                const screen_pt = Point{ .x = data.x, .y = data.y };

                // End Turn button
                const turn_phase = world.turnPhase();
                const end_turn_btn = EndTurnButton.init(turn_phase);
                if (end_turn_btn.hitTest(screen_pt)) {
                    if (turn_phase == .player_card_selection) {
                        return .{ .command = .{ .end_turn = {} } };
                    } else if (turn_phase == .commit_phase) {
                        return .{ .command = .{ .commit_done = {} } };
                    }
                }
            },
            .mouse_wheel => |data| {
                if (isInSidebar(vs.mouse)) {
                    const current = if (vs.combat) |c| c.log_scroll else @as(i32, 0);
                    const delta: i32 = if (data.scroll_y > 0) scroll_speed else -scroll_speed;
                    const new_scroll = @max(0, current + delta);
                    if (new_scroll != current) {
                        return .{ .vs = vs.withLogScroll(new_scroll) };
                    }
                }
            },
            else => {},
        }
        return .{};
    }

    pub fn renderables(self: *const View, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        var list = try std.ArrayList(Renderable).initCapacity(alloc, 64);

        // Chrome backgrounds
        try list.appendSlice(alloc, MenuBar.render());

        // Status bars (in header, requires player in combat)
        if (self.world.player.combat_state != null) {
            const status_bars = StatusBars.init(self.world.player);
            try status_bars.render(alloc, &list);
        }

        // End Turn button (in header)
        const turn_phase = self.world.turnPhase();
        const end_turn_btn = EndTurnButton.init(turn_phase);
        if (end_turn_btn.renderable()) |btn| {
            try list.append(alloc, btn);
        }

        // Combat log
        const scroll_y = if (vs.combat) |c| c.log_scroll else @as(i32, 0);
        try list.append(alloc, .{ .log_pane = .{
            .entries = self.combat_log.entries.items,
            .rect = sidebar_rect,
            .scroll_y = scroll_y,
            .entry_count = self.combat_log.entryCount(),
        } });

        return list;
    }

    fn isInSidebar(mouse: Point) bool {
        // Mouse coords are viewport-adjusted (y offset by -header_h)
        return mouse.x >= sidebar_rect.x and
            mouse.x <= sidebar_rect.x + sidebar_rect.w and
            mouse.y >= 0 and
            mouse.y <= sidebar_rect.h;
    }
};
