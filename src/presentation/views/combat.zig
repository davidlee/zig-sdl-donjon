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
const combat = @import("../../domain/combat.zig");
const s = @import("sdl3");
const entity = infra.entity;
const chrome = @import("chrome.zig");
const apply = @import("../../domain/apply.zig");
const StatusBarView = @import("status_bar_view.zig").StatusBarView;

const Renderable = view.Renderable;
const AssetId = view.AssetId;
const Point = view.Point;
const Rect = view.Rect;
const CardViewModel = view.CardViewModel;
const CardState = view.CardState;
const ViewState = view.ViewState;
const CombatUIState = view.CombatUIState;
const DragState = view.DragState;
const InputResult = view.InputResult;
const Command = infra.commands.Command;
const Agent = combat.Agent;
const ID = infra.commands.ID;
const Keycode = s.keycode.Keycode;
const card_renderer = @import("../card_renderer.zig");

/// View-specific zone enum for layout purposes.
/// Distinct from cards.Zone and combat.CombatZone (domain types).
const ViewZone = enum {
    hand,
    in_play,
    always_available,
    spells, // future
    player_plays, // commit phase
    enemy_plays, // commit phase
};

/// Minimal card data for view rendering.
/// Decouples view layer from Instance pointers.
const CardViewData = struct {
    id: entity.ID,
    template: *const cards.Template,
    playable: bool,
    source: Source,

    /// Card sources - where the card originated from.
    /// Currently used: hand, in_play. Others stubbed for future card systems.
    const Source = enum {
        hand,
        in_play,
        always_available,
        spells, // future
        equipped, // future
        inventory, // future
        environment, // future
    };

    fn fromInstance(inst: *const cards.Instance, source: Source, playable: bool) CardViewData {
        return .{
            .id = inst.id,
            .template = inst.template,
            .playable = playable,
            .source = source,
        };
    }
};

/// Committed play with context (for commit phase and resolution).
const PlayViewData = struct {
    const max_modifiers = combat.Play.max_modifiers;

    // Ownership
    owner_id: entity.ID,
    owner_is_player: bool,

    // Cards in the play
    action: CardViewData,
    modifier_stack_buf: [max_modifiers]CardViewData = undefined,
    modifier_stack_len: u4 = 0,
    stakes: cards.Stakes,

    // Targeting (if offensive)
    target_id: ?entity.ID = null,

    // TODO: Resolution context (for tick_resolution animation)
    // timing: f32,
    // matchup: ?*const PlayViewData,
    // outcome: Outcome,

    fn modifiers(self: *const PlayViewData) []const CardViewData {
        return self.modifier_stack_buf[0..self.modifier_stack_len];
    }

    /// Total cards in play (action + modifiers)
    fn cardCount(self: *const PlayViewData) usize {
        return 1 + self.modifier_stack_len;
    }

    /// Is this an offensive play?
    fn isOffensive(self: *const PlayViewData) bool {
        return self.action.template.tags.offensive;
    }
};

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

fn getLayout(zone: ViewZone) CardLayout {
    return .{
        .w = card_renderer.CARD_WIDTH,
        .h = card_renderer.CARD_HEIGHT,
        .start_x = 10,
        .spacing = card_renderer.CARD_WIDTH + 10,
        .y = switch (zone) {
            .hand => 400,
            .in_play => 200,
            .always_available => 540, // same row as hand, different x
            .spells => 400,
            .player_plays => 200,
            .enemy_plays => 50,
        },
    };
}

fn getLayoutOffset(zone: ViewZone, offset: Point) CardLayout {
    var layout = getLayout(zone);
    layout.start_x += offset.x;
    layout.y += offset.y;
    return layout;
}

const EndTurnButton = struct {
    rect: Rect,
    active: bool,
    asset_id: AssetId,

    fn init(game_state: w.GameState) EndTurnButton {
        return EndTurnButton{
            .active = (game_state == .player_card_selection or game_state == .commit_phase),
            .asset_id = AssetId.end_turn,
            .rect = Rect{
                .x = 50,
                .y = 650,
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
/// Now uses CardViewData (decoupled from Instance pointers).
const CardZoneView = struct {
    zone: ViewZone,
    layout: CardLayout,
    cards: []const CardViewData,

    fn init(zone: ViewZone, card_data: []const CardViewData) CardZoneView {
        return .{ .zone = zone, .layout = getLayout(zone), .cards = card_data };
    }

    fn initWithLayout(zone: ViewZone, card_data: []const CardViewData, layout: CardLayout) CardZoneView {
        return .{ .zone = zone, .layout = layout, .cards = card_data };
    }

    /// Hit test returns card ID (uses mouse from ViewState)
    fn hitTest(self: CardZoneView, vs: ViewState) ?entity.ID {
        // Reverse order so topmost (last rendered) card is hit first
        var i = self.cards.len;
        while (i > 0) {
            i -= 1;
            const rect = self.cardRect(i, self.cards[i].id, vs);
            if (rect.pointIn(vs.mouse)) return self.cards[i].id;
        }
        return null;
    }

    /// Rendering takes ViewState for drag/hover effects
    fn appendRenderables(
        self: CardZoneView,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        last: *?Renderable,
    ) !void {
        const ui = vs.combat orelse CombatUIState{};

        for (self.cards, 0..) |card, i| {
            const rect = self.cardRect(i, card.id, vs);
            const state = self.cardInteractionState(card.id, ui);

            const card_vm = CardViewModel.fromTemplate(card.id, card.template, .{
                .disabled = !card.playable,
                .highlighted = state == .hover,
            });

            const item: Renderable = .{ .card = .{ .model = card_vm, .dst = rect } };
            if (state == .normal) {
                try list.append(alloc, item);
            } else {
                last.* = item; // render last for z-order
            }
        }
    }

    /// Card rect with drag offset applied if this card is being dragged
    fn cardRect(self: CardZoneView, index: usize, card_id: entity.ID, vs: ViewState) Rect {
        const base_x = self.layout.start_x + @as(f32, @floatFromInt(index)) * self.layout.spacing;
        const base_y = self.layout.y;

        const ui = vs.combat orelse return .{
            .x = base_x,
            .y = base_y,
            .w = self.layout.w,
            .h = self.layout.h,
        };

        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) {
                return .{
                    .x = vs.mouse.x - drag.grab_offset.x,
                    .y = vs.mouse.y - drag.grab_offset.y,
                    .w = self.layout.w,
                    .h = self.layout.h,
                };
            }
        }

        // Check for hover state (slight expansion)
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) {
                return .{
                    .x = base_x - 3,
                    .y = base_y - 3,
                    .w = self.layout.w + 6,
                    .h = self.layout.h + 6,
                };
            },
            else => {},
        }

        return .{ .x = base_x, .y = base_y, .w = self.layout.w, .h = self.layout.h };
    }

    fn cardInteractionState(self: CardZoneView, card_id: entity.ID, ui: CombatUIState) CardViewState {
        _ = self;
        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) return .drag;
        }
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) return .hover,
            else => {},
        }
        return .normal;
    }
};

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
///
///
///
pub const CombatView = struct {
    world: *const World,
    arena: std.mem.Allocator,
    end_turn_btn: EndTurnButton,
    player_avatar: PlayerAvatar,
    opposition: Opposition,
    combat_phase: w.GameState,

    pub fn init(world: *const World, arena: std.mem.Allocator) CombatView {
        var fsm = world.fsm;
        const phase = fsm.currentState();

        return .{
            .world = world,
            .arena = arena,
            .end_turn_btn = EndTurnButton.init(phase),
            .player_avatar = PlayerAvatar.init(),
            .opposition = Opposition.init(world.encounter.?.enemies.items),
            .combat_phase = phase,
        };
    }

    // --- New query methods (use CombatState zones + card_registry) ---

    /// Dealt cards in player's hand
    pub fn handCards(self: *const CombatView, alloc: std.mem.Allocator) []const CardViewData {
        const player = self.world.player;
        const cs = player.combat_state orelse return &.{};
        return self.buildCardList(alloc, .hand, cs.hand.items);
    }

    /// Player cards currently in play (selection phase, before commit)
    pub fn inPlayCards(self: *const CombatView, alloc: std.mem.Allocator) []const CardViewData {
        const player = self.world.player;
        const cs = player.combat_state orelse return &.{};
        return self.buildCardList(alloc, .in_play, cs.in_play.items);
    }

    /// Player always known cards (techniques mostly)
    pub fn alwaysCards(self: *const CombatView, alloc: std.mem.Allocator) []const CardViewData {
        const player = self.world.player;
        return self.buildCardList(alloc, .always_available, player.always_available.items);
    }

    /// Enemy cards in play (shown during commit phase).
    /// Unlike player cards, these are always shown as "playable" (not greyed out).
    fn enemyInPlayCards(self: *const CombatView, alloc: std.mem.Allocator, agent: *const Agent) []const CardViewData {
        const cs = agent.combat_state orelse return &.{};
        const ids = cs.in_play.items;

        const result = alloc.alloc(CardViewData, ids.len) catch return &.{};
        var count: usize = 0;

        for (ids) |id| {
            const inst = self.world.card_registry.getConst(id) orelse continue;
            result[count] = CardViewData.fromInstance(inst, .in_play, true);
            count += 1;
        }

        return result[0..count];
    }

    fn buildCardList(
        self: *const CombatView,
        alloc: std.mem.Allocator,
        source: CardViewData.Source,
        ids: []const entity.ID,
    ) []const CardViewData {
        const result = alloc.alloc(CardViewData, ids.len) catch return &.{};
        var count: usize = 0;

        const player = self.world.player;
        const phase = self.combat_phase;

        for (ids) |id| {
            const inst = self.world.card_registry.getConst(id) orelse continue;
            const playable = apply.validateCardSelection(player, inst, phase) catch false;
            result[count] = CardViewData.fromInstance(inst, source, playable);
            count += 1;
        }

        return result[0..count];
    }

    // Input handling - returns command + optional view state update
    pub fn handleInput(self: *CombatView, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = world;
        const cs = vs.combat orelse CombatUIState{};

        switch (event) {
            .mouse_button_down => {
                return self.handleClick(vs);
            },
            .mouse_button_up => {
                return self.handleRelease(vs);
            },
            .mouse_motion => {
                if (cs.drag) |_| {
                    return .{};
                } else {
                    // check for hover on hand cards
                    if (self.handZone(self.arena).hitTest(vs)) |x| {
                        var new_cs = cs;
                        new_cs.hover = .{ .card = x };
                        return .{ .vs = vs.withCombat(new_cs) };
                        // hover for player cards in play zone
                    } else if (self.inPlayZone(self.arena).hitTest(vs)) |x| {
                        var new_cs = cs;
                        new_cs.hover = .{ .card = x };
                        return .{ .vs = vs.withCombat(new_cs) };
                        // hover for enemies
                    } else if (self.opposition.hitTest(vs)) |sprite| {
                        const id = sprite.id;
                        var new_cs = cs;
                        new_cs.hover = .{ .enemy = id };
                        return .{ .vs = vs.withCombat(new_cs) };
                        // reset hover state when no hit detected
                    } else if (cs.hover != .none) {
                        var new_cs = cs;
                        new_cs.hover = .none;
                        return .{ .vs = vs.withCombat(new_cs) };
                    }
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

    fn handleClick(self: *CombatView, vs: ViewState) InputResult {
        if (self.handZone(self.arena).hitTest(vs)) |id| {
            return .{ .command = .{ .play_card = id } };
        } else if (self.inPlayZone(self.arena).hitTest(vs)) |id| {
            return .{ .command = .{ .cancel_card = id } };
        } else if (self.opposition.hitTest(vs)) |sprite| {
            // std.debug.print("ENEMY HIT: id={d}:{d}\n", .{ sprite.id.index, sprite.id.generation });
            return .{ .command = .{ .select_target = .{ .target_id = sprite.id } } };
        } else if (self.end_turn_btn.hitTest(vs)) {
            if (self.combat_phase == .player_card_selection) {
                return .{ .command = .{ .end_turn = {} } };
            } else if (self.combat_phase == .commit_phase) {
                return .{ .command = .{ .commit_turn = {} } };
            }
        }
        return .{};
    }

    // --- Zone helpers (use CardZoneView with CardViewData) ---

    fn handZone(self: *const CombatView, alloc: std.mem.Allocator) CardZoneView {
        return CardZoneView.init(.hand, self.handCards(alloc));
    }

    fn inPlayZone(self: *const CombatView, alloc: std.mem.Allocator) CardZoneView {
        return CardZoneView.init(.in_play, self.inPlayCards(alloc));
    }

    fn alwaysZone(self: *const CombatView, alloc: std.mem.Allocator) CardZoneView {
        return CardZoneView.init(.always_available, self.alwaysCards(alloc));
    }

    fn handleRelease(self: *CombatView, vs: ViewState) InputResult {
        const cs = vs.combat orelse CombatUIState{};
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
        const cs = vs.combat orelse CombatUIState{};

        var list = try std.ArrayList(Renderable).initCapacity(alloc, 32);

        try list.append(alloc, self.player_avatar.renderable());
        try self.opposition.appendRenderables(alloc, &list);

        // Player cards - render in_play first (behind), then hand (in front)
        var last: ?Renderable = null;
        try self.inPlayZone(alloc).appendRenderables(alloc, vs, &list, &last);
        try self.handZone(alloc).appendRenderables(alloc, vs, &list, &last);
        try self.alwaysZone(alloc).appendRenderables(alloc, vs, &list, &last);

        // enemy cards (commit phase only)
        if (self.combat_phase == .commit_phase) {
            for (self.opposition.enemies, 0..) |enemy_agent, i| {
                const layout = getLayoutOffset(.in_play, Point{
                    .x = 400 + @as(f32, @floatFromInt(i)) * 200,
                    .y = 0,
                });
                const enemy_zone = CardZoneView.initWithLayout(
                    .in_play,
                    self.enemyInPlayCards(alloc, enemy_agent),
                    layout,
                );
                try enemy_zone.appendRenderables(alloc, vs, &list, &last);
            }
        }

        // Render hovered/dragged card last (on top)
        if (last) |item| try list.append(alloc, item);

        if (self.end_turn_btn.renderable()) |btn| {
            try list.append(alloc, btn);
        }

        switch (cs.hover) {
            .enemy => |_| {
                const xw = 240;
                const yh = 440;

                // tooltip
                try list.append(alloc, .{
                    .filled_rect = .{
                        .rect = .{ .x = vs.mouse.x - xw / 2, .y = vs.mouse.y + 15, .w = xw, .h = yh },
                        .color = .{
                            .r = 100,
                            .g = 100,
                            .b = 100,
                            .a = 255,
                        },
                    },
                });
            },
            else => {},
        }
        if (cs.hover != .none) {}

        var sb = StatusBarView.init(self.world.player);
        try sb.render(alloc, vs, &list);

        // TODO: engagement info / advantage bars
        // TODO: phase indicator

        return list;
    }
};
