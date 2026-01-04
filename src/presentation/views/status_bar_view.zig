const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const w = @import("../../domain/world.zig");
const combat = @import("../../domain/combat.zig");
const s = @import("sdl3");
const chrome = @import("chrome.zig");

const Renderable = view.Renderable;
const Point = view.Point;
const Rect = view.Rect;
const ViewState = view.ViewState;

pub const StatusBarView = struct {
    stamina: f32,
    stamina_available: f32,
    focus: f32,
    focus_available: f32,
    time_available: f32,

    pub fn init(player: *combat.Agent) StatusBarView {
        return StatusBarView{
            .stamina = player.stamina.current,
            .stamina_available = player.stamina.available,
            .focus = player.focus.current,
            .focus_available = player.focus.available,
            .time_available = player.time_available,
        };
    }

    const margin_x = 80;
    const height = 40;
    const line = 3;
    const border = 4;
    const trim = 5;
    const pip_spacing = 3;
    const max_pips = 20;
    const trim_color = s.pixels.Color{ .r = 10, .g = 10, .b = 10 };
    const black = s.pixels.Color{ .r = 0, .g = 0, .b = 0 };

    pub fn render(self: *StatusBarView, alloc: std.mem.Allocator, vs: ViewState, list: *std.ArrayList(Renderable)) !void {
        _ = .{ self, alloc, list, vs };

        // Stamina Bar
        {
            const y = 780;
            const r_outer = Rect{ .x = margin_x, .y = y, .w = (chrome.viewport.w - (2 * margin_x)), .h = height };
            const r_inner = Rect{ .x = r_outer.x + trim, .y = r_outer.y + trim, .w = r_outer.w - (2 * trim), .h = r_outer.h - (2 * trim) };

            const outer: Renderable = .{ .filled_rect = .{ .rect = r_outer, .color = trim_color } };
            const inner: Renderable = .{ .filled_rect = .{ .rect = r_inner, .color = black } };

            try list.append(alloc, outer);
            try list.append(alloc, inner);

            const pip_total_w = r_inner.w - (border * 2);
            const pip_w = (pip_total_w / max_pips) - pip_spacing;

            for (0..max_pips) |n| {
                const m: f32 = @floatFromInt(n);
                const start_x = r_inner.x + border;
                const pip: Renderable = .{ .filled_rect = .{ .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing),
                    .y = r_inner.y + border,
                    .w = pip_w,
                    .h = r_inner.h - border * 2,
                }, .color = s.pixels.Color{ .r = 0, .g = 30, .b = 0 } } };
                try list.append(alloc, pip);
            }
            for (0..@intFromFloat(@ceil(self.stamina))) |n| {
                const m: f32 = @floatFromInt(n);
                const start_x = r_inner.x + border;
                const pip: Renderable = .{ .filled_rect = .{ .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing),
                    .y = r_inner.y + border,
                    .w = pip_w,
                    .h = r_inner.h - border * 2,
                }, .color = s.pixels.Color{ .r = 0, .g = 60, .b = 0 } } };
                try list.append(alloc, pip);
            }

            for (0..@intFromFloat(@ceil(self.stamina_available))) |n| {
                const m: f32 = @floatFromInt(n);
                const start_x = r_inner.x + border;
                const pip: Renderable = .{ .filled_rect = .{ .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing) + border,
                    .y = r_inner.y + border,
                    .w = pip_w - border * 2,
                    .h = (r_inner.h - border * 2) / 2,
                }, .color = s.pixels.Color{ .r = 0, .g = 120, .b = 0 } } };
                try list.append(alloc, pip);
            }
        }

        // Focus Bar
        {
            // Stamina Bar
            //
            const y = 830;
            const r_outer = Rect{ .x = margin_x, .y = y, .w = (chrome.viewport.w - (2 * margin_x)), .h = height };
            const r_inner = Rect{ .x = r_outer.x + trim, .y = r_outer.y + trim, .w = r_outer.w - (2 * trim), .h = r_outer.h - (2 * trim) };

            const outer: Renderable = .{ .filled_rect = .{ .rect = r_outer, .color = trim_color } };
            const inner: Renderable = .{ .filled_rect = .{ .rect = r_inner, .color = black } };

            try list.append(alloc, outer);
            try list.append(alloc, inner);

            const pip_total_w = r_inner.w - (border * 2);
            const pip_w = (pip_total_w / max_pips) - pip_spacing;

            for (0..max_pips) |n| {
                const m: f32 = @floatFromInt(n);
                const start_x = r_inner.x + border;
                const pip: Renderable = .{ .filled_rect = .{ .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing),
                    .y = r_inner.y + border,
                    .w = pip_w,
                    .h = r_inner.h - border * 2,
                }, .color = s.pixels.Color{ .r = 0, .g = 0, .b = 40 } } };
                try list.append(alloc, pip);
            }

            for (0..@intFromFloat(@ceil(self.focus))) |n| {
                const m: f32 = @floatFromInt(n);
                const start_x = r_inner.x + border;
                const pip: Renderable = .{ .filled_rect = .{ .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing),
                    .y = r_inner.y + border,
                    .w = pip_w,
                    .h = r_inner.h - border * 2,
                }, .color = s.pixels.Color{ .r = 0, .g = 0, .b = 90 } } };
                try list.append(alloc, pip);
            }

            for (0..@intFromFloat(@ceil(self.focus_available))) |n| {
                const m: f32 = @floatFromInt(n);
                const start_x = r_inner.x + border;
                const pip: Renderable = .{ .filled_rect = .{ .rect = .{
                    .x = start_x + (m * pip_w) + (m * pip_spacing) + border,
                    .y = r_inner.y + border,
                    .w = pip_w - border * 2,
                    .h = (r_inner.h - border * 2) / 2,
                }, .color = s.pixels.Color{ .r = 0, .g = 0, .b = 180 } } };
                try list.append(alloc, pip);
            }
        }
    }
};
