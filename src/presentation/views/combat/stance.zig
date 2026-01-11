// Stance Selection View - pre-round stance triangle UI
//
// Displays triangle selector for attack/defense/movement weighting.
// Mouse follows cursor, click to lock, space to confirm.

const std = @import("std");
const views = @import("../view.zig");
const view_state = @import("../../view_state.zig");
const infra = @import("infra");
const s = @import("sdl3");

const Renderable = views.Renderable;
const Point = views.Point;
const Rect = views.Rect;
const ViewState = views.ViewState;
const CombatUIState = views.CombatUIState;
const StanceCursor = view_state.StanceCursor;
const InputResult = views.InputResult;
const commands = infra.commands;
const Command = commands.Command;
const Keycode = s.keycode.Keycode;

/// Stance weights - uses command type for compatibility.
pub const Stance = commands.Stance;

/// Triangle geometry for stance selection.
/// Uses screen coordinates with origin at triangle center.
pub const Triangle = struct {
    /// Center of the triangle in screen coordinates.
    center: Point,
    /// Distance from center to each vertex.
    radius: f32,

    /// Vertex positions (attack=top, movement=bottom-left, defense=bottom-right).
    pub fn vertices(self: Triangle) [3]Point {
        const angle_top = -std.math.pi / 2.0; // -90 degrees (up)
        const angle_left = angle_top + 2.0 * std.math.pi / 3.0; // +120 degrees
        const angle_right = angle_top + 4.0 * std.math.pi / 3.0; // +240 degrees

        return .{
            // Attack (top)
            .{ .x = self.center.x + self.radius * @cos(angle_top), .y = self.center.y + self.radius * @sin(angle_top) },
            // Movement (bottom-left)
            .{ .x = self.center.x + self.radius * @cos(angle_left), .y = self.center.y + self.radius * @sin(angle_left) },
            // Defense (bottom-right)
            .{ .x = self.center.x + self.radius * @cos(angle_right), .y = self.center.y + self.radius * @sin(angle_right) },
        };
    }

    /// Convert screen point to barycentric coordinates (attack, defense, movement).
    /// Returns null if point is outside triangle.
    pub fn toBarycentric(self: Triangle, p: Point) ?Stance {
        const v = self.vertices();
        const v0 = v[0]; // attack
        const v1 = v[1]; // movement
        const v2 = v[2]; // defense

        // Compute vectors
        const d00 = dot(sub(v1, v0), sub(v1, v0));
        const d01 = dot(sub(v1, v0), sub(v2, v0));
        const d11 = dot(sub(v2, v0), sub(v2, v0));
        const d20 = dot(sub(p, v0), sub(v1, v0));
        const d21 = dot(sub(p, v0), sub(v2, v0));

        const denom = d00 * d11 - d01 * d01;
        if (@abs(denom) < 1e-10) return null; // degenerate triangle

        const movement = (d11 * d20 - d01 * d21) / denom;
        const defense = (d00 * d21 - d01 * d20) / denom;
        const attack = 1.0 - movement - defense;

        // Check if inside triangle with small epsilon for floating point tolerance
        // (clamped edge points may have tiny negative values due to precision)
        const eps: f32 = 1e-5;
        if (attack < -eps or defense < -eps or movement < -eps) return null;
        if (attack > 1 + eps or defense > 1 + eps or movement > 1 + eps) return null;

        // Clamp to valid range and renormalize
        const a = std.math.clamp(attack, 0, 1);
        const d = std.math.clamp(defense, 0, 1);
        const m = std.math.clamp(movement, 0, 1);
        const sum = a + d + m;
        return .{ .attack = a / sum, .defense = d / sum, .movement = m / sum };
    }

    /// Clamp a point to the nearest point inside/on the triangle.
    pub fn clampToTriangle(self: Triangle, p: Point) Point {
        // If inside, return as-is
        if (self.toBarycentric(p) != null) return p;

        // Otherwise, find nearest point on each edge and pick closest
        const v = self.vertices();
        var best = p;
        var best_dist: f32 = std.math.inf(f32);

        // Check each edge
        const edges = [_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 } };
        for (edges) |edge| {
            const nearest = nearestPointOnSegment(p, v[edge[0]], v[edge[1]]);
            const dist = length(sub(nearest, p));
            if (dist < best_dist) {
                best_dist = dist;
                best = nearest;
            }
        }

        return best;
    }

    /// Convert barycentric coordinates to screen point.
    pub fn fromBarycentric(self: Triangle, stance: Stance) Point {
        const v = self.vertices();
        return .{
            .x = stance.attack * v[0].x + stance.defense * v[1].x + stance.movement * v[2].x,
            .y = stance.attack * v[0].y + stance.defense * v[1].y + stance.movement * v[2].y,
        };
    }
};

// Vector math helpers
fn sub(a: Point, b: Point) Point {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

fn dot(a: Point, b: Point) f32 {
    return a.x * b.x + a.y * b.y;
}

fn length(v: Point) f32 {
    return @sqrt(v.x * v.x + v.y * v.y);
}

fn nearestPointOnSegment(p: Point, a: Point, b: Point) Point {
    const ab = sub(b, a);
    const ap = sub(p, a);
    const ab_len_sq = dot(ab, ab);
    if (ab_len_sq < 1e-10) return a; // degenerate segment

    var t = dot(ap, ab) / ab_len_sq;
    t = @max(0, @min(1, t)); // clamp to [0,1]

    return .{ .x = a.x + t * ab.x, .y = a.y + t * ab.y };
}

/// Stance selection view state and rendering.
pub const View = struct {
    triangle: Triangle,

    // Button dimensions
    const button_w: f32 = 200;
    const button_h: f32 = 36;
    const button_y_offset: f32 = 50; // below triangle

    pub fn init(center: Point, radius: f32) View {
        return .{ .triangle = .{ .center = center, .radius = radius } };
    }

    fn confirmButtonRect(self: *const View) Rect {
        return .{
            .x = self.triangle.center.x - button_w / 2,
            .y = self.triangle.center.y + self.triangle.radius + button_y_offset,
            .w = button_w,
            .h = button_h,
        };
    }

    fn pointInRect(p: Point, r: Rect) bool {
        return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h;
    }

    /// Handle input during stance selection phase.
    pub fn handleInput(self: *View, event: s.events.Event, vs: ViewState) InputResult {
        var cs = vs.combat orelse CombatUIState{};
        const button_rect = self.confirmButtonRect();

        switch (event) {
            .mouse_button_down => {
                // Check button click first (when locked)
                if (cs.stance_cursor.locked and pointInRect(vs.mouse_vp, button_rect)) {
                    const cursor_pos = cs.stance_cursor.position orelse self.triangle.center;
                    const stance = self.triangle.toBarycentric(cursor_pos) orelse Stance.balanced;
                    return .{ .command = .{ .confirm_stance = stance } };
                }
                // Toggle lock state
                cs.stance_cursor.locked = !cs.stance_cursor.locked;
                if (cs.stance_cursor.locked) {
                    // Lock at current position (clamped to triangle)
                    cs.stance_cursor.position = self.triangle.clampToTriangle(vs.mouse_vp);
                }
                return .{ .vs = vs.withCombat(cs) };
            },
            .mouse_motion => {
                // Update button hover state when locked
                if (cs.stance_cursor.locked) {
                    const hovered = pointInRect(vs.mouse_vp, button_rect);
                    if (hovered != cs.stance_cursor.confirm_hovered) {
                        cs.stance_cursor.confirm_hovered = hovered;
                        return .{ .vs = vs.withCombat(cs) };
                    }
                } else {
                    // Update cursor position when not locked
                    cs.stance_cursor.position = self.triangle.clampToTriangle(vs.mouse_vp);
                    return .{ .vs = vs.withCombat(cs) };
                }
            },
            .key_down => |data| {
                if (data.key) |key| {
                    if (key == .space and cs.stance_cursor.locked) {
                        // Confirm stance - issue command to transition phase
                        const cursor_pos = cs.stance_cursor.position orelse self.triangle.center;
                        const stance = self.triangle.toBarycentric(cursor_pos) orelse Stance.balanced;
                        return .{ .command = .{ .confirm_stance = stance } };
                    }
                }
            },
            else => {},
        }
        return .{};
    }

    /// Generate renderables for stance triangle UI.
    pub fn appendRenderables(self: *const View, alloc: std.mem.Allocator, list: *std.ArrayList(Renderable), vs: ViewState) !void {
        const cs = vs.combat orelse CombatUIState{};
        const verts = self.triangle.vertices();

        // Compute cursor position and stance weights early (needed for fill color)
        const cursor_pos = cs.stance_cursor.position orelse self.triangle.center;
        const stance = self.triangle.toBarycentric(cursor_pos) orelse Stance.balanced;

        // Title
        try list.append(alloc, .{ .text = .{
            .content = "Select Stance",
            .pos = .{ .x = self.triangle.center.x - 70, .y = self.triangle.center.y - self.triangle.radius - 50 },
            .font_size = .normal,
            .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        } });

        // Draw outer square frame (circumscribes circle)
        const side = self.triangle.radius * 2;
        try list.append(alloc, .{ .rect_outline = .{
            .rect = .{
                .x = self.triangle.center.x - self.triangle.radius,
                .y = self.triangle.center.y - self.triangle.radius,
                .w = side,
                .h = side,
            },
            .color = .{ .r = 50, .g = 50, .b = 55, .a = 255 },
            .thickness = 2,
        } });

        // Draw circumscribed circle (behind triangle)
        try list.append(alloc, .{ .circle_outline = .{
            .center = self.triangle.center,
            .radius = self.triangle.radius,
            .color = .{ .r = 60, .g = 60, .b = 65, .a = 255 },
            .thickness = 2,
        } });

        // Black outline masks circle overflow at corners
        try list.append(alloc, .{ .rect_outline = .{
            .rect = .{
                .x = self.triangle.center.x - self.triangle.radius - 1,
                .y = self.triangle.center.y - self.triangle.radius - 1,
                .w = side + 2,
                .h = side + 2,
            },
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
            .thickness = 1,
        } });

        // Draw filled triangle - color from stance weights (ATK=R, MOV=G, DEF=B)
        // Base 20 + weight*80 gives 20-100 range per channel (muted but visible tint)
        const base: f32 = 20;
        const range: f32 = 80;
        const fill_color = s.pixels.Color{
            .r = @intFromFloat(base + stance.attack * range),
            .g = @intFromFloat(base + stance.movement * range),
            .b = @intFromFloat(base + stance.defense * range),
            .a = 255,
        };
        try list.append(alloc, .{ .filled_triangle = .{
            .points = verts,
            .color = fill_color,
        } });

        // Draw vertex labels
        const label_offset: f32 = 20;
        try list.append(alloc, .{ .text = .{
            .content = "ATK",
            .pos = .{ .x = verts[0].x - 15, .y = verts[0].y - label_offset - 15 },
            .font_size = .normal,
            .color = .{ .r = 255, .g = 100, .b = 100, .a = 255 },
        } });
        try list.append(alloc, .{ .text = .{
            .content = "MOV",
            .pos = .{ .x = verts[1].x - label_offset - 20, .y = verts[1].y + 5 },
            .font_size = .normal,
            .color = .{ .r = 100, .g = 255, .b = 100, .a = 255 },
        } });
        try list.append(alloc, .{ .text = .{
            .content = "DEF",
            .pos = .{ .x = verts[2].x + label_offset - 10, .y = verts[2].y + 5 },
            .font_size = .normal,
            .color = .{ .r = 100, .g = 100, .b = 255, .a = 255 },
        } });

        // Draw cursor
        const cursor_size: f32 = if (cs.stance_cursor.locked) 12 else 10;
        const cursor_color = if (cs.stance_cursor.locked)
            s.pixels.Color{ .r = 255, .g = 255, .b = 255, .a = 255 }
        else
            s.pixels.Color{ .r = 200, .g = 200, .b = 200, .a = 200 };

        try list.append(alloc, .{
            .filled_rect = .{
                .rect = .{
                    .x = cursor_pos.x - cursor_size / 2,
                    .y = cursor_pos.y - cursor_size / 2,
                    .w = cursor_size,
                    .h = cursor_size,
                },
                .color = cursor_color,
            },
        });

        // Draw weight percentages
        try list.append(alloc, .{ .stance_weights = .{
            .attack = stance.attack,
            .defense = stance.defense,
            .movement = stance.movement,
            .pos = .{ .x = self.triangle.center.x - 100, .y = self.triangle.center.y + self.triangle.radius + 30 },
        } });

        // Confirm button (only active when locked)
        const button_rect = self.confirmButtonRect();
        const button_color = if (!cs.stance_cursor.locked)
            s.pixels.Color{ .r = 40, .g = 40, .b = 40, .a = 255 } // disabled
        else if (cs.stance_cursor.confirm_hovered)
            s.pixels.Color{ .r = 80, .g = 120, .b = 80, .a = 255 } // hover
        else
            s.pixels.Color{ .r = 60, .g = 90, .b = 60, .a = 255 }; // active

        try list.append(alloc, .{
            .filled_rect = .{
                .rect = button_rect,
                .color = button_color,
            },
        });

        const instruction = if (cs.stance_cursor.locked) "Confirm" else "Click to lock";
        const text_color = if (cs.stance_cursor.locked)
            s.pixels.Color{ .r = 220, .g = 220, .b = 220, .a = 255 }
        else
            s.pixels.Color{ .r = 100, .g = 100, .b = 100, .a = 255 };

        try list.append(alloc, .{ .text = .{
            .content = instruction,
            .pos = .{ .x = button_rect.x + button_w / 2 - 35, .y = button_rect.y + 8 },
            .font_size = .normal,
            .color = text_color,
        } });
    }
};

// Tests
const testing = std.testing;

test "barycentric coords at vertices" {
    const tri = Triangle{ .center = .{ .x = 100, .y = 100 }, .radius = 50 };
    const verts = tri.vertices();

    // At attack vertex: attack=1, defense=0, movement=0
    const at_attack = tri.toBarycentric(verts[0]).?;
    try testing.expectApproxEqAbs(@as(f32, 1.0), at_attack.attack, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), at_attack.defense, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), at_attack.movement, 0.01);

    // At movement vertex (bottom-left)
    const at_movement = tri.toBarycentric(verts[1]).?;
    try testing.expectApproxEqAbs(@as(f32, 0.0), at_movement.attack, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), at_movement.defense, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), at_movement.movement, 0.01);

    // At defense vertex (bottom-right)
    const at_defense = tri.toBarycentric(verts[2]).?;
    try testing.expectApproxEqAbs(@as(f32, 0.0), at_defense.attack, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0), at_defense.defense, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.0), at_defense.movement, 0.01);
}

test "barycentric coords at center" {
    const tri = Triangle{ .center = .{ .x = 100, .y = 100 }, .radius = 50 };

    // At center: all weights ~0.33
    const at_center = tri.toBarycentric(tri.center).?;
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), at_center.attack, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), at_center.defense, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), at_center.movement, 0.01);
}

test "barycentric coords outside triangle returns null" {
    const tri = Triangle{ .center = .{ .x = 100, .y = 100 }, .radius = 50 };

    // Point far outside
    const outside = tri.toBarycentric(.{ .x = 0, .y = 0 });
    try testing.expect(outside == null);
}

test "weights sum to 1.0" {
    const tri = Triangle{ .center = .{ .x = 100, .y = 100 }, .radius = 50 };

    // Test various points inside triangle
    const test_points = [_]Point{
        tri.center,
        .{ .x = 100, .y = 80 },
        .{ .x = 90, .y = 110 },
        .{ .x = 110, .y = 110 },
    };

    for (test_points) |p| {
        if (tri.toBarycentric(p)) |stance| {
            const sum = stance.attack + stance.defense + stance.movement;
            try testing.expectApproxEqAbs(@as(f32, 1.0), sum, 0.001);
        }
    }
}

test "clampToTriangle returns same point if inside" {
    const tri = Triangle{ .center = .{ .x = 100, .y = 100 }, .radius = 50 };

    const inside = tri.center;
    const clamped = tri.clampToTriangle(inside);
    try testing.expectApproxEqAbs(inside.x, clamped.x, 0.01);
    try testing.expectApproxEqAbs(inside.y, clamped.y, 0.01);
}

test "fromBarycentric at vertices" {
    const tri = Triangle{ .center = .{ .x = 100, .y = 100 }, .radius = 50 };
    const verts = tri.vertices();

    // Pure attack stance should give attack vertex
    const attack_pos = tri.fromBarycentric(.{ .attack = 1, .defense = 0, .movement = 0 });
    try testing.expectApproxEqAbs(verts[0].x, attack_pos.x, 0.01);
    try testing.expectApproxEqAbs(verts[0].y, attack_pos.y, 0.01);

    // Balanced stance should give center
    const center_pos = tri.fromBarycentric(Stance.balanced);
    try testing.expectApproxEqAbs(tri.center.x, center_pos.x, 0.01);
    try testing.expectApproxEqAbs(tri.center.y, center_pos.y, 0.01);
}
