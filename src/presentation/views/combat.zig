// CombatView - combat encounter screen
//
// Displays player hand, enemies, engagements, combat phase.
// Handles card selection, targeting, reactions.

const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const World = @import("../../domain/world.zig").World;
const cards = @import("../../domain/cards.zig");
const combat = @import("../../domain/combat.zig");
const s = @import("sdl3");
const entity = infra.entity;

const Renderable = view.Renderable;
const Point = view.Point;
const Rect = view.Rect;
const CardViewModel = view.CardViewModel;
const CardState = view.CardState;
const ViewState = view.ViewState;
const CombatState = view.CombatState;
const DragState = view.DragState;
const InputResult = view.InputResult;
const Command = infra.commands.Command;
const ID = infra.commands.ID;
const Keycode = s.keycode.Keycode;
const card_renderer = @import("../card_renderer.zig");

pub const CombatView = struct {
    world: *const World,

    pub fn init(world: *const World) CombatView {
        return .{ .world = world };
    }

    // Query methods - expose what the view needs from World

    pub fn playerHand(self: *const CombatView) []const *cards.Instance {
        return self.world.player.cards.deck.hand.items;
    }

    pub fn enemies(self: *const CombatView) []const *combat.Agent {
        if (self.world.encounter) |*enc| {
            return enc.enemies.items;
        }
        return &.{};
    }

    pub fn combatPhase(self: *const CombatView) World.GameState {
        return self.world.fsm.currentState();
    }

    // Input handling - returns command + optional view state update

    pub fn handleInput(self: *CombatView, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = world;
        const cs = vs.combat orelse CombatState{};

        switch (event) {
            .mouse_button_down => {
                return self.handleClick(vs.mouse, vs, cs);
            },
            .mouse_button_up => {
                return self.handleRelease(vs.mouse, vs, cs);
            },
            .mouse_motion => {
                // Update drag offset if dragging
                if (cs.drag) |drag| {
                    const new_drag = DragState{
                        .id = drag.id,
                        .grab_offset = drag.grab_offset,
                        .original_pos = drag.original_pos,
                    };
                    return .{ .vs = vs.withCombat(.{
                        .drag = new_drag,
                        .selected_card = cs.selected_card,
                        .hover_target = cs.hover_target,
                    }) };
                }
            },
            .key_down => |data| {
                if (data.key) |key| {
                    return self.handleKey(key, vs);
                }
            },
            else => {},
        }
        return .{};
    }

    fn handleClick(self: *CombatView, pos: Point, vs: ViewState, cs: CombatState) InputResult {
        _ = cs;

        // Hit test cards in hand
        if (self.hitTestHand(pos)) |drag| {
            std.debug.print("CARD HIT: id={d}:{d} at ({d:.0}, {d:.0})\n", .{
                drag.id.index,
                drag.id.generation,
                pos.x,
                pos.y,
            });

            // Start drag, don't emit command yet (wait for drop)
            return .{
                .vs = vs.withCombat(.{ .drag = drag }),
            };
        }

        // Hit test enemies (for targeting)
        if (self.hitTestEnemies(pos)) |target_id| {
            std.debug.print("ENEMY HIT: id={d}:{d}\n", .{ target_id.index, target_id.generation });
            return .{ .command = .{ .select_target = .{ .target_id = target_id } } };
        }

        std.debug.print("CLICK MISS at ({d:.0}, {d:.0})\n", .{ pos.x, pos.y });
        return .{};
    }

    fn handleRelease(self: *CombatView, pos: Point, vs: ViewState, cs: CombatState) InputResult {
        _ = self;

        if (cs.drag) |drag| {
            // TODO: hit test drop zones (enemies, discard, etc.)
            _ = pos;

            std.debug.print("RELEASE card {d}:{d}\n", .{ drag.id.index, drag.id.generation });

            // For now, just clear drag state (snap back)
            return .{
                .vs = vs.withCombat(.{
                    .drag = null,
                    .selected_card = cs.selected_card,
                    .hover_target = cs.hover_target,
                }),
            };
        }

        return .{};
    }

    fn handleKey(self: *CombatView, keycode: Keycode, vs: ViewState) InputResult {
        _ = self;
        _ = vs;
        switch (keycode) {
            .q => std.process.exit(0),
            .space => return .{ .command = .{ .end_turn = {} } },
            else => {},
        }
        return .{};
    }

    // Hit testing - recomputes layout on demand

    fn hitTestHand(self: *CombatView, pos: Point) ?DragState {
        const hand = self.playerHand();

        for (hand, 0..) |card, i| {
            const card_origin = Point{
                .x = hand_layout.start_x + @as(f32, @floatFromInt(i)) * hand_layout.spacing,
                .y = hand_layout.y,
            };
            const card_rect = Rect{
                .x = card_origin.x,
                .y = card_origin.y,
                .w = hand_layout.card_width,
                .h = hand_layout.card_height,
            };

            if (card_rect.pointIn(pos)) {
                return DragState{
                    .id = card.id,
                    .grab_offset = .{ .x = pos.x - card_origin.x, .y = pos.y - card_origin.y },
                    .original_pos = card_origin,
                };
            }
        }
        return null;
    }

    fn hitTestEnemies(self: *CombatView, pos: Point) ?entity.ID {
        const enemy_list = self.enemies();
        const enemy_width: f32 = 80;
        const enemy_height: f32 = 120;
        const enemy_y: f32 = 100;
        const start_x: f32 = 100;
        const spacing: f32 = 120;

        for (enemy_list, 0..) |enemy, i| {
            const enemy_x = start_x + @as(f32, @floatFromInt(i)) * spacing;
            if (pos.x >= enemy_x and pos.x < enemy_x + enemy_width and
                pos.y >= enemy_y and pos.y < enemy_y + enemy_height)
            {
                return enemy.id;
            }
        }
        return null;
    }

    // Rendering - layout constants (shared with hit testing)

    const hand_layout = struct {
        const card_width: f32 = card_renderer.CARD_WIDTH;
        const card_height: f32 = card_renderer.CARD_HEIGHT;
        const y: f32 = 400; // bottom area
        const start_x: f32 = 100;
        const spacing: f32 = card_width + 10;
    };

    pub fn renderables(self: *const CombatView, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        var list = try std.ArrayList(Renderable).initCapacity(alloc, 32);
        const cs = vs.combat orelse CombatState{};

        // Debug: dark background to show combat view is active
        try list.append(alloc, .{
            .filled_rect = .{
                .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 },
                .color = .{ .r = 20, .g = 25, .b = 30, .a = 255 },
            },
        });

        // Player hand
        const hand = self.playerHand();
        var dragged_card: ?Renderable = null;

        for (hand, 0..) |card, i| {
            const base_x = hand_layout.start_x + @as(f32, @floatFromInt(i)) * hand_layout.spacing;
            const base_y = hand_layout.y;

            const card_vm = CardViewModel.fromInstance(card.*, .{});

            // Check if this card is being dragged
            const is_dragged = if (cs.drag) |drag| drag.id.index == card.id.index and drag.id.generation == card.id.generation else false;

            if (is_dragged) {
                const drag = cs.drag.?;
                // Position at mouse minus grab offset
                dragged_card = .{
                    .card = .{
                        .model = card_vm,
                        .dst = .{
                            .x = vs.mouse.x - drag.grab_offset.x,
                            .y = vs.mouse.y - drag.grab_offset.y,
                            .w = hand_layout.card_width,
                            .h = hand_layout.card_height,
                        },
                    },
                };
            } else {
                try list.append(alloc, .{
                    .card = .{
                        .model = card_vm,
                        .dst = .{
                            .x = base_x,
                            .y = base_y,
                            .w = hand_layout.card_width,
                            .h = hand_layout.card_height,
                        },
                    },
                });
            }
        }

        // Render dragged card last (on top)
        if (dragged_card) |dc| {
            try list.append(alloc, dc);
        }

        // TODO: enemies (top area)
        // TODO: engagement info / advantage bars
        // TODO: stamina/time indicators
        // TODO: phase indicator

        return list;
    }
};
