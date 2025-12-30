// CombatView - combat encounter screen
//
// Displays player hand, enemies, engagements, combat phase.
// Handles card selection, targeting, reactions.

const std = @import("std");
const view = @import("view.zig");
const infra = @import("infra");
const w = @import("../../domain/world.zig");
const World = w.World;
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

fn getLayout(zone: cards.Zone) CardLayout {
    return .{
        .w = card_renderer.CARD_WIDTH,
        .h = card_renderer.CARD_HEIGHT,
        .start_x = 10,
        .spacing = card_renderer.CARD_WIDTH + 10,
        .y = switch (zone) {
            .hand => 400,
            .in_play => 200,
            else => unreachable,
        },
    };
}

const EndTurnButton = struct {
    rect: Rect,
    active: bool,
    asset_id: AssetId,

    fn init(game_state: w.GameState) EndTurnButton {
        return EndTurnButton{
            .active = (game_state == .player_card_selection),
            .asset_id = AssetId.end_turn,
            .rect = Rect{
                .x = 50,
                .y = 550,
                .w = 120,
                .h = 40,
            },
        };
    }

    fn hitTest(self: *EndTurnButton, vs: ViewState) bool {
        if (self.active) {
            if (self.rect.pointIn(vs.mouse)) return true;
        }
        return false;
    }

    fn renderable(self: *const EndTurnButton) ?Renderable {
        if (self.active) {
            return Renderable{ .sprite = .{
                .asset = self.asset_id,
                .dst = self.rect,
            } };
        } else return null;
    }
};

/// Lightweight view over a card zone (hand, in_play, etc.)
/// Created on-demand since zone contents are dynamic.
const CardZoneView = struct {
    zone: cards.Zone,
    layout: CardLayout,
    card_list: []const *cards.Instance,

    const CardWithRect = struct {
        card: cards.Instance,
        rect: Rect,
        state: CardViewState,
    };

    fn init(zone: cards.Zone, card_list: []const *cards.Instance) CardZoneView {
        return .{ .zone = zone, .layout = getLayout(zone), .card_list = card_list };
    }

    fn hitTest(self: CardZoneView, vs: ViewState) ?entity.ID {
        // Reverse order so topmost (last rendered) card is hit first
        var i = self.card_list.len;
        while (i > 0) {
            i -= 1;
            const cr = self.cardWithRect(vs, i);
            if (cr.rect.pointIn(vs.mouse)) return cr.card.id;
        }
        return null;
    }

    fn cardWithRect(self: CardZoneView, vs: ViewState, i: usize) CardWithRect {
        const cs = vs.combat;
        const card = self.card_list[i];
        const state = cardViewState(cs, card);

        const base_x = self.layout.start_x + @as(f32, @floatFromInt(i)) * self.layout.spacing;
        const base_y = self.layout.y;

        return switch (state) {
            .normal => .{
                .card = card.*,
                .rect = .{ .x = base_x, .y = base_y, .w = self.layout.w, .h = self.layout.h },
                .state = .normal,
            },
            .hover => .{
                .card = card.*,
                .rect = .{ .x = base_x + 3, .y = base_y - 10, .w = self.layout.w, .h = self.layout.h },
                .state = .hover,
            },
            .drag => .{
                .card = card.*,
                .rect = .{
                    .x = vs.mouse.x - cs.?.drag.?.grab_offset.x,
                    .y = vs.mouse.y - cs.?.drag.?.grab_offset.y,
                    .w = self.layout.w,
                    .h = self.layout.h,
                },
                .state = .drag,
            },
        };
    }

    fn appendRenderables(self: CardZoneView, alloc: std.mem.Allocator, vs: ViewState, list: *std.ArrayList(Renderable), last: *?Renderable) !void {
        for (0..self.card_list.len) |i| {
            const cr = self.cardWithRect(vs, i);
            const card_vm = CardViewModel.fromInstance(cr.card, .{});
            const item: Renderable = .{ .card = .{ .model = card_vm, .dst = cr.rect } };
            if (cr.state == .normal) {
                try list.append(alloc, item);
            } else {
                last.* = item;
            }
        }
    }
};

const MenuBar = struct {};

const PlayerAvatar = struct {
    rect: Rect,
    asset_id: AssetId,

    fn init() PlayerAvatar {
        return PlayerAvatar{
            .rect = Rect{
                .x = 200,
                .y = 50,
                .w = 48,
                .h = 48,
            },
            .asset_id = AssetId.player_halberdier,
        };
    }

    fn hitTest(self: *const PlayerAvatar, vs: ViewState) bool {
        return self.rect.pointIn(vs.mouse);
    }
    fn renderable(self: *const PlayerAvatar) Renderable {
        return .{ .sprite = .{
            .asset = self.asset_id,
            .dst = self.rect,
        } };
    }
};

const EnemySprite = struct {
    index: usize,
    id: entity.ID,

    rect: Rect,
    asset_id: AssetId,

    fn init(id: entity.ID, index: usize) EnemySprite {
        return EnemySprite{
            .rect = Rect{
                .x = 300 + 60 * @as(f32, @floatFromInt(index)),
                .y = 50,
                .w = 48,
                .h = 48,
            },
            .asset_id = AssetId.thief,
            .id = id,
            .index = index,
        };
    }

    fn hitTest(self: *const EnemySprite, vs: ViewState) bool {
        return self.rect.pointIn(vs.mouse);
    }
    fn renderable(self: *const EnemySprite) Renderable {
        return .{ .sprite = .{
            .asset = self.asset_id,
            .dst = self.rect,
        } };
    }
};

const Opposition = struct {
    enemies: []*combat.Agent,

    fn init(agents: []*combat.Agent) Opposition {
        return Opposition{
            .enemies = agents,
        };
    }

    fn hitTest(self: *const Opposition, vs: ViewState) ?EnemySprite {
        for (self.enemies, 0..) |e, i| {
            const sprite = EnemySprite.init(e.id, i);
            if (sprite.hitTest(vs)) {
                return sprite;
            }
        }
        return null;
    }

    fn appendRenderables(self: *const Opposition, alloc: std.mem.Allocator, list: *std.ArrayList(Renderable)) !void {
        for (self.enemies, 0..) |e, i| {
            const sprite = EnemySprite.init(e.id, i);
            try list.append(alloc, sprite.renderable());
        }
    }
};

/// CombatView - view model for representing and interacting with combat
/// requires an active encounter.
pub const CombatView = struct {
    world: *const World,
    end_turn_btn: EndTurnButton,
    player_avatar: PlayerAvatar,
    opposition: Opposition,
    combat_phase: w.GameState,

    pub fn init(world: *const World) CombatView {
        var fsm = world.fsm;
        const phase = fsm.currentState();

        return .{
            .world = world,
            .end_turn_btn = EndTurnButton.init(phase),
            .player_avatar = PlayerAvatar.init(),
            .opposition = Opposition.init(world.encounter.?.enemies.items),
            .combat_phase = phase,
        };
    }

    // Query methods - expose what the view needs from World

    pub fn playerHand(self: *const CombatView) []const *cards.Instance {
        return self.world.player.cards.deck.hand.items;
    }

    pub fn playerInPlay(self: *const CombatView) []const *cards.Instance {
        return self.world.player.cards.deck.in_play.items;
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
                if (cs.drag) |_| {
                    // Drag position derived from mouse in CardZoneView.cardWithRect
                    return .{};
                }
                // TODO: hover state updates
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

    fn handleClick(self: *CombatView, vs: ViewState) InputResult {
        if (self.handZone().hitTest(vs)) |id| {
            return .{ .command = .{ .play_card = id } };
        } else if (self.inPlayZone().hitTest(vs)) |id| {
            return .{ .command = .{ .cancel_card = id } };
        } else if (self.opposition.hitTest(vs)) |sprite| {
            std.debug.print("ENEMY HIT: id={d}:{d}\n", .{ sprite.id.index, sprite.id.generation });
            return .{ .command = .{ .select_target = .{ .target_id = sprite.id } } };
        } else if (self.end_turn_btn.hitTest(vs)) {
            return .{ .command = .{ .end_turn = {} } };
        }
        return .{};
    }

    fn handZone(self: *const CombatView) CardZoneView {
        return CardZoneView.init(.hand, self.playerHand());
    }

    fn inPlayZone(self: *const CombatView) CardZoneView {
        return CardZoneView.init(.in_play, self.playerInPlay());
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

    pub fn renderables(self: *const CombatView, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        var list = try std.ArrayList(Renderable).initCapacity(alloc, 32);

        // Debug: dark background to show combat view is active
        // try list.append(alloc, .{
        //     .filled_rect = .{
        //         .rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 },
        //         .color = .{ .r = 0, .g = 5, .b = 5, .a = 255 },
        //     },
        // });

        try list.append(alloc, self.player_avatar.renderable());
        try self.opposition.appendRenderables(alloc, &list);

        // Player cards - render in_play first (behind), then hand (in front)
        var last: ?Renderable = null;
        try self.inPlayZone().appendRenderables(alloc, vs, &list, &last);
        try self.handZone().appendRenderables(alloc, vs, &list, &last);

        // Render hovered/dragged card last (on top)
        if (last) |item| try list.append(alloc, item);

        if (self.end_turn_btn.renderable()) |btn| {
            try list.append(alloc, btn);
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
