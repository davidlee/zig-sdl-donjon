// CombatView - combat encounter screen
//
// Displays player hand, enemies, engagements, combat phase.
// Handles card selection, targeting, reactions.

const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const World = @import("../../domain/world.zig").World;
const cards = @import("../../domain/cards.zig");
const deck = @import("../../domain/deck.zig");
const combat = @import("../../domain/combat.zig");
const s = @import("sdl3");
const entity = infra.entity;

const Renderable = view.Renderable;
const AssetId = view.AssetId;
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

const CardViewState = enum {
    normal,
    hover,
    drag,
};
const CardLayout = struct {
    w: f32,
    h: f32,
    y: f32,
    start_x: f32,
    spacing: f32,
};

const CardZoneLayout = union(enum) {
    hand: CardLayout,
    in_play: CardLayout,
};

const CardZoneLayoutList = [_]CardZoneLayout{
    .{
        .hand = .{
            .w = card_renderer.CARD_WIDTH,
            .h = card_renderer.CARD_HEIGHT,
            .y = 400,
            .start_x = 10,
            .spacing = card_renderer.CARD_WIDTH + 10,
        },
    },
    .{
        .in_play = .{
            .w = card_renderer.CARD_WIDTH,
            .h = card_renderer.CARD_HEIGHT,
            .y = 200,
            .start_x = 10,
            .spacing = card_renderer.CARD_WIDTH + 10,
        },
    },
};

fn getLayout(zone: cards.Zone) CardLayout {
    for (CardZoneLayoutList) |layout| {
        switch (layout) {
            .hand => |v| if (zone == .hand) return v,
            .in_play => |v| if (zone == .in_play) return v,
        }
    }
    unreachable;
}

pub const CombatView = struct {
    world: *const World,

    pub fn init(world: *const World) CombatView {
        return .{ .world = world };
    }

    // Query methods - expose what the view needs from World

    pub fn playerHand(self: *const CombatView) []const *cards.Instance {
        return self.world.player.cards.deck.hand.items;
    }

    pub fn playerInPlay(self: *const CombatView) []const *cards.Instance {
        return self.world.player.cards.deck.in_play.items;
    }

    // fn playerHandLen(self: *const CombatView) usize {
    //     return self.playerHand().len;
    // }

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
                return self.handleClick(vs);
            },
            .mouse_button_up => {
                return self.handleRelease(vs);
            },
            .mouse_motion => {
                // Update drag offset if dragging
                if (cs.drag) |_| {
                    // Drag position derived from mouse in cardWithRectByIndex, no state change needed
                    return .{};
                } else {
                    // if (self.hitTestHand(vs)) |ds| {
                    //     return self.setHover(vs, ds.id);
                    // } else {
                    //     return self.setHover(vs, null);
                    // }
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

    fn setHover(self: *CombatView, vs: ViewState, id: ?entity.ID) InputResult {
        _ = self;
        if (id) |eid| {
            if (vs.combat == null) {
                return .{ .vs = vs.withCombat(CombatState{ .hover_target = eid }) };
            } else if (vs.combat.?.hover_target == null or vs.combat.?.hover_target.?.index != eid.index) {
                var cs = vs.combat.?;
                cs.hover_target = eid;
                return .{ .vs = vs.withCombat(cs) };
            } else {
                return .{}; // no change
            }
        } else {
            if (vs.combat == null) {
                return .{};
            } else {
                var cs = vs.combat.?;
                cs.hover_target = null;
                return .{ .vs = vs.withCombat(cs) };
            }
        }
        return .{};
    }

    fn handleClick(self: *CombatView, vs: ViewState) InputResult {
        // Hit test cards in hand
        if (self.hitTestHand(vs)) |id| {
            return .{ .command = .{ .play_card = id } };
        } else if (self.hitTestInPlay(vs)) |id| {
            return .{ .command = .{ .cancel_card = id } };
        } else
        // Hit test enemies (for targeting)
        if (self.hitTestEnemies(vs.mouse)) |target_id| {
            std.debug.print("ENEMY HIT: id={d}:{d}\n", .{ target_id.index, target_id.generation });
            return .{ .command = .{ .select_target = .{ .target_id = target_id } } };
        }

        // std.debug.print("CLICK MISS at ({d:.0}, {d:.0})\n", .{ pos.x, pos.y });
        return .{};
    }

    fn handleRelease(self: *CombatView, vs: ViewState) InputResult {
        const cs = vs.combat orelse CombatState{};
        _ = self;

        if (cs.drag) |drag| {
            // TODO: hit test drop zones (enemies, discard, etc.)

            std.debug.print("RELEASE card {d}:{d}\n", .{ drag.id.index, drag.id.generation });

            // For now, just clear drag state (snap back)
            var new_cs = cs;
            new_cs.drag = null;
            return .{ .vs = vs.withCombat(new_cs) };
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

    // fn hitTestHand(self: *CombatView, vs: ViewState) ?DragState {
    //     const pos = vs.mouse;
    //     for (0..self.playerHandLen()) |i| {
    //         const cr = self.cardWithRectByIndex(vs, i);
    //         const id = cr.card.id;
    //         const rect = cr.rect;
    //
    //         if (rect.pointIn(pos)) {
    //             return DragState{
    //                 .id = id,
    //                 .grab_offset = .{ .x = pos.x - rect.x, .y = pos.y - rect.y },
    //                 .original_pos = Point{ .x = rect.x, .y = rect.y },
    //             };
    //         }
    //     }
    //     return null;
    // }

    fn hitTestInPlay(self: *CombatView, vs: ViewState) ?entity.ID {
        for (0..self.playerInPlay().len) |i| {
            const cr = self.cardWithRectByIndex(vs, .in_play, i);
            if (cr.rect.pointIn(vs.mouse)) return cr.card.id;
        }
        return null;
    }

    fn hitTestHand(self: *CombatView, vs: ViewState) ?entity.ID {
        for (0..self.playerHand().len) |i| {
            const cr = self.cardWithRectByIndex(vs, .hand, i);
            if (cr.rect.pointIn(vs.mouse)) return cr.card.id;
        }
        return null;
    }

    const CardWithRect = struct {
        card: cards.Instance,
        rect: Rect,
        state: CardViewState,
    };

    fn cardWithRectByIndex(self: *const CombatView, vs: ViewState, zone: cards.Zone, i: usize) CardWithRect {
        const cs = vs.combat;
        const pile = switch (zone) {
            .hand => self.playerHand(),
            .in_play => self.playerInPlay(),
            else => unreachable,
        };
        const layout = getLayout(zone);
        const card = pile[i];
        const state = cardViewState(cs, card);

        const base_x = layout.start_x + @as(f32, @floatFromInt(i)) * layout.spacing;
        const base_y = layout.y;

        switch (state) {
            .normal => {
                return .{
                    .card = card.*,
                    .rect = .{
                        .x = base_x,
                        .y = base_y,
                        .w = layout.w,
                        .h = layout.h,
                    },
                    .state = .normal,
                };
            },
            .hover => {
                return .{
                    .card = card.*,
                    .rect = .{
                        .x = base_x + 3,
                        .y = base_y - 10,
                        .w = layout.w,
                        .h = layout.h,
                    },
                    .state = .hover,
                };
            },
            .drag => {
                const drag = cs.?.drag.?;
                return .{
                    .card = card.*,
                    .rect = .{
                        .x = vs.mouse.x - drag.grab_offset.x,
                        .y = vs.mouse.y - drag.grab_offset.y,
                        .w = layout.w,
                        .h = layout.h,
                    },
                    .state = .drag,
                };
            },
        }
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

    pub fn renderables(self: *const CombatView, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        var list = try std.ArrayList(Renderable).initCapacity(alloc, 32);

        // Debug: dark background to show combat view is active
        try list.append(alloc, .{
            .filled_rect = .{
                .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 },
                .color = .{ .r = 0, .g = 5, .b = 5, .a = 255 },
            },
        });

        // Player sprite (top area)
        try list.append(alloc, .{
            .sprite = .{
                .asset = AssetId.player_halberdier,
                .dst = .{ .x = 200, .y = 50, .w = 48 * 2, .h = 48 * 2 },
            },
        });

        // Snail sprite - enemy
        try list.append(alloc, .{
            .sprite = .{
                .asset = AssetId.fredrick_snail,
                .dst = .{ .x = 400, .y = 50, .w = 48 * 2, .h = 48 * 2 },
            },
        });

        // Snail sprite - enemy
        try list.append(alloc, .{
            .sprite = .{
                .asset = AssetId.thief,
                .dst = .{ .x = 500, .y = 50, .w = 48 * 2, .h = 48 * 2 },
            },
        });

        // Player Cards

        var last: ?Renderable = null;

        for (0..self.playerHand().len) |i| {
            const cr = self.cardWithRectByIndex(vs, .hand, i);
            const card_vm = CardViewModel.fromInstance(cr.card, .{});

            const item: Renderable = .{ .card = .{ .model = card_vm, .dst = cr.rect } };
            if (cr.state == .normal) {
                try list.append(alloc, item);
            } else {
                last = item;
            }
        }

        for (0..self.playerInPlay().len) |i| {
            const cr = self.cardWithRectByIndex(vs, .in_play, i);
            const card_vm = CardViewModel.fromInstance(cr.card, .{});
            const item: Renderable = .{ .card = .{ .model = card_vm, .dst = cr.rect } };
            if (cr.state == .normal) {
                try list.append(alloc, item);
            } else {
                last = item;
            }
        }

        if (last != null)
            try list.append(alloc, last.?);

        // END TURN button
        var fsm = self.world.fsm;
        if (fsm.currentState() == .player_card_selection) {
            try list.append(alloc, .{
                .sprite = .{
                    .asset = AssetId.end_turn,
                    .dst = .{
                        .x = 50,
                        .y = 550,
                        .w = 289,
                        .h = 97,
                    },
                },
            });
        }

        // TODO: enemies (top area)
        // TODO: engagement info / advantage bars
        // TODO: stamina/time indicators
        // TODO: phase indicator

        return list;
    }
};

fn cardViewState(cs: ?CombatState, card: *const cards.Instance) CardViewState {
    // const cs = vs.combat orelse CombatState{};
    if (cs != null and cs.?.drag != null and cs.?.drag.?.id.index == card.id.index) {
        return .drag;
    } else if (cs != null and cs.?.hover_target != null and cs.?.hover_target.?.index == card.id.index) {
        return .hover;
    } else {
        return .normal;
    }
}
