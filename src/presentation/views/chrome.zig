// Chrome View - UI chrome (header, footer, sidebar with combat log)
// Access as: chrome.View
//
// Renders persistent UI elements around the game viewport.

const std = @import("std");
const view = @import("view.zig");
const s = @import("sdl3");
const World = @import("../../domain/world.zig").World;
const CombatLog = @import("../combat_log.zig").CombatLog;

const Renderable = view.Renderable;
const ViewState = view.ViewState;
const InputResult = view.InputResult;
const Rect = s.rect.FRect;
const IRect = s.rect.IRect;
const Color = s.pixels.Color;
const Point = view.Point;

const logical_w = view.logical_w;
const logical_h = view.logical_h;

const colors = .{
    .black = Color{ .r = 0, .g = 0, .b = 0 },
    .dark = Color{ .r = 10, .g = 10, .b = 10 },
    .grey = Color{ .r = 20, .g = 20, .b = 20 },
};

pub const header_h = 100;
pub const footer_h = 100;
pub const sidebar_w = 500;

pub const origin = s.rect.FPoint{ .x = 0, .y = header_h };
pub const viewport = IRect{
    .x = 0,
    .y = header_h,
    .w = logical_w - sidebar_w,
    .h = logical_h - header_h - footer_h,
};

const MenuBar = struct {
    fn render() []const Renderable {
        return &[_]Renderable{
            // top
            .{ .filled_rect = .{
                .rect = .{
                    .x = 0,
                    .y = 0,
                    .w = logical_w,
                    .h = header_h,
                },
                .color = colors.grey,
            } },
            // RHS
            .{ .filled_rect = .{
                .rect = .{
                    .x = logical_w - sidebar_w,
                    .y = header_h,
                    .w = sidebar_w,
                    .h = logical_h - header_h - footer_h,
                },
                .color = colors.grey,
            } },
            .{ .filled_rect = .{
                .rect = .{
                    .x = logical_w - sidebar_w + 3,
                    .y = header_h,
                    .w = sidebar_w,
                    .h = logical_h - header_h - footer_h,
                },
                .color = colors.black,
            } },

            // footer
            .{ .filled_rect = .{
                .rect = .{
                    .x = 0,
                    .y = 1080 - footer_h,
                    .w = 1920,
                    .h = footer_h,
                },
                .color = colors.grey,
            } },
            // footer
        };
    }
};

// Sidebar layout
const sidebar_x: f32 = logical_w - sidebar_w;
const sidebar_y: f32 = header_h;

/// Rectangle for the sidebar content area (for hit testing)
const sidebar_rect = Rect{
    .x = sidebar_x,
    .y = sidebar_y,
    .w = sidebar_w,
    .h = logical_h - header_h - footer_h,
};

const scroll_speed: i32 = 40; // pixels per scroll tick

pub const View = struct {
    world: *const World,
    combat_log: *CombatLog,

    pub fn init(world: *const World, combat_log: *CombatLog) View {
        return .{ .world = world, .combat_log = combat_log };
    }

    pub fn handleInput(self: *View, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = self;
        _ = world;

        // Handle mouse wheel scroll when over sidebar
        switch (event) {
            .mouse_wheel => |data| {
                if (isInSidebar(vs.mouse)) {
                    const current = if (vs.combat) |c| c.log_scroll else @as(i32, 0);
                    // scroll_y > 0 = scroll up = see older = increase offset
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
        try list.appendSlice(alloc, MenuBar.render());

        // Combat log - pass all entries, renderer handles scrolling
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
        // So sidebar_y (100 in screen space) becomes 0 in mouse space
        return mouse.x >= sidebar_rect.x and
            mouse.x <= sidebar_rect.x + sidebar_rect.w and
            mouse.y >= 0 and
            mouse.y <= sidebar_rect.h;
    }
};
