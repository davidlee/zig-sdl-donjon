// ChromeView - UI chrome (header, footer, sidebar with combat log)
//
// Renders persistent UI elements around the game viewport.

const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const s = @import("sdl3");
const World = @import("../../domain/world.zig").World;
const CombatLog = @import("../combat_log.zig").CombatLog;

const Renderable = view.Renderable;
const ViewState = view.ViewState;
const InputResult = view.InputResult;
const Command = infra.commands.Command;
const Rect = s.rect.FRect;
const IRect = s.rect.IRect;
const AssetId = view.AssetId;
const Color = s.pixels.Color;
const Text = view.Text;
const Point = view.Point;

const Button = struct {
    rect: Rect,
    color: Color,
    asset_id: ?AssetId,
    text: []const u8,
};

const logical_w = view.logical_w;
const logical_h = view.logical_h;

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
                .color = Color{ .r = 30, .g = 30, .b = 30 },
            } },
            // RHS
            .{ .filled_rect = .{
                .rect = .{
                    .x = logical_w - sidebar_w,
                    .y = header_h,
                    .w = sidebar_w,
                    .h = logical_h - header_h - footer_h,
                },
                .color = Color{ .r = 30, .g = 30, .b = 30 },
            } },

            // footer
            .{ .filled_rect = .{
                .rect = .{
                    .x = 0,
                    .y = 1080 - footer_h,
                    .w = 1920,
                    .h = footer_h,
                },
                .color = Color{ .r = 30, .g = 30, .b = 30 },
            } },
            // footer
        };
    }
};

// Sidebar layout
const sidebar_x: f32 = logical_w - sidebar_w;
const sidebar_y: f32 = header_h;
const log_padding: f32 = 10;
const log_line_height: f32 = 18;

/// Rectangle for the sidebar content area (for hit testing)
const sidebar_rect = Rect{
    .x = sidebar_x,
    .y = sidebar_y,
    .w = sidebar_w,
    .h = logical_h - header_h - footer_h,
};

pub const ChromeView = struct {
    world: *const World,
    combat_log: *CombatLog,

    pub fn init(world: *const World, combat_log: *CombatLog) ChromeView {
        return .{ .world = world, .combat_log = combat_log };
    }

    pub fn handleInput(self: *ChromeView, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = world;

        // Handle mouse wheel scroll when over sidebar
        switch (event) {
            .mouse_wheel => |data| {
                if (isInSidebar(vs.mouse)) {
                    // Scroll: positive y = scroll up (view older), negative = scroll down (view newer)
                    if (data.y > 0) {
                        self.combat_log.scrollUp(3);
                    } else if (data.y < 0) {
                        self.combat_log.scrollDown(3);
                    }
                }
            },
            else => {},
        }
        return .{};
    }

    pub fn renderables(self: *const ChromeView, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        _ = vs;
        var list = try std.ArrayList(Renderable).initCapacity(alloc, 64);
        try list.appendSlice(alloc, MenuBar.render());

        // Render combat log entries
        const entries = self.combat_log.visibleEntries();
        for (entries, 0..) |entry, i| {
            const y = sidebar_y + log_padding + @as(f32, @floatFromInt(i)) * log_line_height;
            try list.append(alloc, .{ .text = Text{
                .content = entry.text,
                .pos = Point{ .x = sidebar_x + log_padding, .y = y },
                .font_size = .small,
                .color = entry.color,
            } });
        }

        return list;
    }

    fn isInSidebar(mouse: Point) bool {
        return mouse.x >= sidebar_rect.x and
            mouse.x <= sidebar_rect.x + sidebar_rect.w and
            mouse.y >= sidebar_rect.y and
            mouse.y <= sidebar_rect.y + sidebar_rect.h;
    }
};
