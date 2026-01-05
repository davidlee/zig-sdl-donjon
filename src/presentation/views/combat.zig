// CombatView - combat encounter screen
//
// Displays player hand, enemies, engagements, combat phase.
// Handles card selection, targeting, reactions.

const std = @import("std");
const view = @import("view.zig");
const view_state = @import("../view_state.zig");
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
    target,
};

/// Unified hit test result for cards and plays.
/// Enables consistent interaction handling across zones.
const HitResult = union(enum) {
    /// Hit on a standalone card (hand, always_available, in_play during selection)
    card: CardHit,
    /// Hit on a card within a committed play stack
    play: PlayHit,

    const CardHit = struct {
        id: entity.ID,
        zone: ViewZone,
    };

    const PlayHit = struct {
        play_index: usize,
        card_id: entity.ID,
        slot: Slot,

        const Slot = union(enum) {
            action,
            modifier: u4, // index into modifier stack
        };
    };

    /// Extract card ID regardless of hit type
    pub fn cardId(self: HitResult) entity.ID {
        return switch (self) {
            .card => |c| c.id,
            .play => |p| p.card_id,
        };
    }
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
                .y = 690,
                .w = 120,
                .h = 40,
            },
        };
    }

    fn hitTest(self: *EndTurnButton, pt: Point) bool {
        if (self.active) {
            if (self.rect.pointIn(pt)) return true;
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

    /// Hit test returns HitResult at given point
    fn hitTest(self: CardZoneView, vs: ViewState, pt: Point) ?HitResult {
        // Reverse order so topmost (last rendered) card is hit first
        var i = self.cards.len;
        while (i > 0) {
            i -= 1;
            const rect = self.cardRect(i, self.cards[i].id, vs);
            if (rect.pointIn(pt)) {
                return .{ .card = .{ .id = self.cards[i].id, .zone = self.zone } };
            }
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
                .target = state == .target,
                .played = (self.zone == .in_play),
                .disabled = (!card.playable and self.zone != .in_play),
                .highlighted = state == .hover,
            });
            const item: Renderable = .{ .card = .{ .model = card_vm, .dst = rect } };
            if (state == .normal or state == .target) {
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

        const pad: f32 = 3;

        const normal: Rect = .{
            .x = base_x,
            .y = base_y,
            .w = self.layout.w,
            .h = self.layout.h,
        };

        const ui = vs.combat orelse return normal;

        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) {
                return .{
                    .x = vs.mouse.x - pad - (drag.original_pos.x - base_x),
                    .y = vs.mouse.y - pad - (drag.original_pos.y - base_y),
                    .w = self.layout.w + pad,
                    .h = self.layout.h + pad,
                };
            }
        }

        // Check for hover state (slight expansion)
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) {
                return .{
                    .x = base_x - pad,
                    .y = base_y - pad,
                    .w = self.layout.w + pad * 2,
                    .h = self.layout.h + pad * 2,
                };
            },
            else => {},
        }

        return normal;
    }

    fn cardInteractionState(self: CardZoneView, card_id: entity.ID, ui: CombatUIState) CardViewState {
        _ = self;
        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) return .drag;
            if (drag.target) |id| if (id.eql(card_id)) return .target;
        }
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) return .hover,
            else => {},
        }
        return .normal;
    }
};

/// View over plays during commit phase (action + modifier stacks).
/// Renders plays as solitaire-style vertical stacks.
const PlayZoneView = struct {
    const modifier_y_offset: f32 = 25; // vertical offset per stacked modifier

    plays: []const PlayViewData,
    layout: CardLayout,

    fn init(zone: ViewZone, play_data: []const PlayViewData) PlayZoneView {
        return .{ .plays = play_data, .layout = getLayout(zone) };
    }

    /// Hit test returns HitResult with card-level detail
    fn hitTest(self: PlayZoneView, vs: ViewState, pt: Point) ?HitResult {
        _ = vs;
        // Reverse order so rightmost (last rendered) play is hit first
        var i = self.plays.len;
        while (i > 0) {
            i -= 1;
            const play = self.plays[i];

            // Check modifiers first (topmost in z-order, stacked above action)
            // Check from highest modifier down
            var m: usize = play.modifier_stack_len;
            while (m > 0) {
                m -= 1;
                const mod_rect = self.modifierRect(i, m);
                if (mod_rect.pointIn(pt)) {
                    return .{ .play = .{
                        .play_index = i,
                        .card_id = play.modifier_stack_buf[m].id,
                        .slot = .{ .modifier = @intCast(m) },
                    } };
                }
            }

            // Check action card (at base position)
            const action_rect = self.actionRect(i);
            if (action_rect.pointIn(pt)) {
                return .{ .play = .{
                    .play_index = i,
                    .card_id = play.action.id,
                    .slot = .action,
                } };
            }
        }
        return null;
    }

    /// Hit test returning only play index (for drop targeting where card slot doesn't matter)
    fn hitTestPlay(self: PlayZoneView, vs: ViewState, pt: Point) ?usize {
        if (self.hitTest(vs, pt)) |result| {
            return switch (result) {
                .play => |p| p.play_index,
                .card => null,
            };
        }
        return null;
    }

    /// Compute rect for entire play stack (action + modifiers)
    fn playRect(self: PlayZoneView, index: usize) Rect {
        const play = self.plays[index];
        const base_x = self.layout.start_x + @as(f32, @floatFromInt(index)) * self.layout.spacing;
        // Stack grows upward: modifiers above action
        const stack_height = self.layout.h + @as(f32, @floatFromInt(play.modifier_stack_len)) * modifier_y_offset;
        const top_y = self.layout.y - @as(f32, @floatFromInt(play.modifier_stack_len)) * modifier_y_offset;
        return Rect{
            .x = base_x,
            .y = top_y,
            .w = self.layout.w,
            .h = stack_height,
        };
    }

    /// Compute rect for the action card within a play
    fn actionRect(self: PlayZoneView, index: usize) Rect {
        const base_x = self.layout.start_x + @as(f32, @floatFromInt(index)) * self.layout.spacing;
        return Rect{
            .x = base_x,
            .y = self.layout.y,
            .w = self.layout.w,
            .h = self.layout.h,
        };
    }

    /// Compute rect for a modifier card within a play (stacked above action)
    fn modifierRect(self: PlayZoneView, play_index: usize, mod_index: usize) Rect {
        const base_x = self.layout.start_x + @as(f32, @floatFromInt(play_index)) * self.layout.spacing;
        const offset_y = @as(f32, @floatFromInt(mod_index + 1)) * modifier_y_offset;
        return Rect{
            .x = base_x,
            .y = self.layout.y - offset_y,
            .w = self.layout.w,
            .h = self.layout.h,
        };
    }

    /// Generate renderables for all plays (hovered card rendered last via `last` out param)
    fn appendRenderables(
        self: PlayZoneView,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        last: *?Renderable,
    ) !void {
        for (self.plays, 0..) |play, i| {
            try self.appendPlayRenderables(alloc, vs, list, play, i, last);
        }
    }

    fn appendPlayRenderables(
        self: PlayZoneView,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        play: PlayViewData,
        play_index: usize,
        last: *?Renderable,
    ) !void {
        const ui = vs.combat orelse CombatUIState{};

        const is_drop_target = if (ui.drag) |drag|
            drag.target_play_index == play_index
        else
            false;

        // Get hovered card ID (if any)
        const hover_id: ?entity.ID = switch (ui.hover) {
            .card => |id| id,
            else => null,
        };

        // Render modifiers first (behind, top to bottom)
        var j: usize = play.modifier_stack_len;
        while (j > 0) {
            j -= 1;
            const mod = play.modifier_stack_buf[j];
            const is_hovered = if (hover_id) |hid| hid.eql(mod.id) else false;
            const rect = self.cardRectWithHover(self.modifierRect(play_index, j), is_hovered);
            const mod_vm = CardViewModel.fromTemplate(mod.id, mod.template, .{
                .target = is_drop_target,
                .played = true,
                .highlighted = is_hovered,
            });
            const item: Renderable = .{ .card = .{ .model = mod_vm, .dst = rect } };
            if (is_hovered) {
                last.* = item;
            } else {
                try list.append(alloc, item);
            }
        }

        // Render action card (in front, at base position)
        const is_action_hovered = if (hover_id) |hid| hid.eql(play.action.id) else false;
        const action_rect = self.cardRectWithHover(self.actionRect(play_index), is_action_hovered);
        const action_vm = CardViewModel.fromTemplate(play.action.id, play.action.template, .{
            .target = is_drop_target,
            .played = true,
            .highlighted = is_action_hovered,
        });
        const action_item: Renderable = .{ .card = .{ .model = action_vm, .dst = action_rect } };
        if (is_action_hovered) {
            last.* = action_item;
        } else {
            try list.append(alloc, action_item);
        }
    }

    /// Apply hover expansion to a rect
    fn cardRectWithHover(self: PlayZoneView, base: Rect, is_hovered: bool) Rect {
        _ = self;
        if (!is_hovered) return base;
        const pad: f32 = 3;
        return .{
            .x = base.x - pad,
            .y = base.y - pad,
            .w = base.w + pad * 2,
            .h = base.h + pad * 2,
        };
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

    fn hitTest(self: *const PlayerAvatar, pt: Point) bool {
        return self.rect.pointIn(pt);
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

    fn hitTest(self: *const EnemySprite, pt: Point) bool {
        return self.rect.pointIn(pt);
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

    fn hitTest(self: *const Opposition, pt: Point) ?EnemySprite {
        for (self.enemies, 0..) |e, i| {
            const sprite = EnemySprite.init(e.id, i);
            if (sprite.hitTest(pt)) {
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

    /// Player's plays for commit phase (action + modifier stacks)
    pub fn playerPlays(self: *const CombatView, alloc: std.mem.Allocator) []const PlayViewData {
        const enc = &(self.world.encounter orelse return &.{});
        const enc_state = enc.stateForConst(self.world.player.id) orelse return &.{};

        const result = alloc.alloc(PlayViewData, enc_state.current.plays_len) catch return &.{};
        var count: usize = 0;

        for (enc_state.current.plays()) |*play| {
            if (self.buildPlayViewData(alloc, play, self.world.player)) |pvd| {
                result[count] = pvd;
                count += 1;
            }
        }

        return result[0..count];
    }

    /// Build PlayViewData from domain Play
    fn buildPlayViewData(
        self: *const CombatView,
        alloc: std.mem.Allocator,
        play: *const combat.Play,
        owner: *const Agent,
    ) ?PlayViewData {
        const action_inst = self.world.card_registry.getConst(play.action) orelse return null;

        var pvd = PlayViewData{
            .owner_id = owner.id,
            .owner_is_player = owner.director == .player,
            .action = CardViewData.fromInstance(action_inst, .in_play, true),
            .stakes = play.effectiveStakes(),
        };

        // Add modifiers
        for (play.modifiers()) |mod_id| {
            const mod_inst = self.world.card_registry.getConst(mod_id) orelse continue;
            pvd.modifier_stack_buf[pvd.modifier_stack_len] = CardViewData.fromInstance(mod_inst, .in_play, true);
            pvd.modifier_stack_len += 1;
        }

        // Resolve target if offensive
        if (pvd.isOffensive()) {
            if (apply.resolvePlayTargetIDs(alloc, play, owner, self.world) catch null) |ids| {
                if (ids.len > 0) pvd.target_id = ids[0];
            }
        }

        return pvd;
    }

    /// Get PlayZoneView for commit phase
    fn playerPlayZone(self: *const CombatView, alloc: std.mem.Allocator) PlayZoneView {
        return PlayZoneView.init(.player_plays, self.playerPlays(alloc));
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

    // Input handling - returns optional command and/or view state update
    //
    //
    pub fn handleInput(self: *CombatView, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = world;
        const cs = vs.combat orelse CombatUIState{};

        switch (event) {
            .mouse_button_down => {
                if (self.hitTestPlayerCards(vs)) |hit| {
                    const card_id = hit.cardId();
                    if (self.isCardDraggable(card_id)) {
                        var new_cs = cs;
                        new_cs.drag = .{
                            .original_pos = vs.mouse,
                            .id = card_id,
                        };
                        return .{ .vs = vs.withCombat(new_cs) };
                    }
                }
                var new_vs = vs;
                new_vs.clicked = vs.mouse;
                return .{ .vs = new_vs };
            },
            .mouse_button_up => {
                return self.handleRelease(vs);
            },
            .mouse_motion => {
                if (cs.drag) |drag| {
                    return self.handleDragging(vs, drag);
                } else return self.handleHover(vs);
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

    fn hitTestPlayerCards(self: *CombatView, vs: ViewState) ?HitResult {
        if (self.alwaysZone(self.arena).hitTest(vs, vs.mouse)) |hit| {
            return hit;
        } else if (self.handZone(self.arena).hitTest(vs, vs.mouse)) |hit| {
            return hit;
        }
        // During commit phase, hit test plays; during selection, hit test flat in_play
        if (self.combat_phase == .commit_phase) {
            if (self.playerPlayZone(self.arena).hitTest(vs, vs.mouse)) |hit| {
                return hit;
            }
        } else {
            if (self.inPlayZone(self.arena).hitTest(vs, vs.mouse)) |hit| {
                return hit;
            }
        }
        return null;
    }

    fn handleDragging(self: *CombatView, vs: ViewState, drag: DragState) InputResult {
        const cs = vs.combat orelse CombatUIState{};
        var new_cs = cs;

        // Clear any previous target
        new_cs.drag.?.target = null;
        new_cs.drag.?.target_play_index = null;

        // Get the dragged card
        const card = self.world.card_registry.getConst(drag.id) orelse
            return .{ .vs = vs.withCombat(new_cs) };

        // Only modifiers can be dropped on plays
        if (card.template.kind != .modifier)
            return .{ .vs = vs.withCombat(new_cs) };

        // During commit phase, hit test against plays for modifier attachment
        if (self.combat_phase == .commit_phase) {
            const play_zone = self.playerPlayZone(self.arena);
            if (play_zone.hitTestPlay(vs, vs.mouse)) |play_index| {
                // Validate the attachment
                const enc = &(self.world.encounter orelse return .{ .vs = vs.withCombat(new_cs) });
                const enc_state = enc.stateForConst(self.world.player.id) orelse
                    return .{ .vs = vs.withCombat(new_cs) };
                const plays = enc_state.current.plays();
                if (play_index >= plays.len)
                    return .{ .vs = vs.withCombat(new_cs) };

                const play = &plays[play_index];

                // Check predicate match
                const can_attach = apply.canModifierAttachToPlay(card.template, play, self.world) catch false;
                if (!can_attach)
                    return .{ .vs = vs.withCombat(new_cs) };

                // Check for conflicts
                if (play.wouldConflict(card.template, &self.world.card_registry))
                    return .{ .vs = vs.withCombat(new_cs) };

                // Valid target!
                new_cs.drag.?.target_play_index = play_index;
            }
        } else {
            // Selection phase - original card-to-card hit test
            if (self.inPlayZone(self.arena).hitTest(vs, vs.mouse)) |hit| {
                new_cs.drag.?.target = hit.cardId();
            }
        }

        return .{ .vs = vs.withCombat(new_cs) };
    }

    fn handleHover(self: *CombatView, vs: ViewState) InputResult {
        var hover: ?view_state.EntityRef = null;
        if (self.hitTestPlayerCards(vs)) |hit| {
            hover = .{ .card = hit.cardId() };
        } else if (self.opposition.hitTest(vs.mouse)) |sprite| {
            // hover for enemies
            const id = sprite.id;
            hover = .{ .enemy = id };
        } else if (vs.combat) |cs| {
            // reset hover state when no hit detected
            if (cs.hover != .none) hover = .none;
        }

        if (hover) |ref| {
            var new_cs = vs.combat orelse CombatUIState{};
            new_cs.hover = ref;
            return .{ .vs = vs.withCombat(new_cs) };
        } else return .{};
    }

    fn isCardDraggable(self: *CombatView, id: entity.ID) bool {
        var registry = self.world.card_registry;
        if (registry.get(id)) |card| {
            const playable = apply.validateCardSelection(self.world.player, card, self.combat_phase) catch |err| {
                std.debug.print("Error validating card playability: {s} -- {}", .{ card.template.name, err });
                return false;
            };
            if (playable) return if (card.template.kind == .modifier) true else false;
        }
        return false;
    }

    fn onClick(self: *CombatView, vs: ViewState, pos: Point) InputResult {
        // ALWAYS AVAILABLE CARD
        if (self.alwaysZone(self.arena).hitTest(vs, pos)) |hit| {
            const id = hit.cardId();
            if (self.isCardDraggable(id)) {
                std.debug.print("yes is drag\n", .{});
                var cs = vs.combat orelse CombatUIState{};
                cs.drag = .{ .original_pos = pos, .id = id };
                return .{ .vs = vs.withCombat(cs) };
            } else {
                return .{ .command = .{ .play_card = id } };
            }
            // IN HAND CARD
        } else if (self.handZone(self.arena).hitTest(vs, pos)) |hit| {
            const id = hit.cardId();
            if (self.isCardDraggable(id)) {
                var cs = vs.combat orelse CombatUIState{};
                cs.drag = .{ .original_pos = pos, .id = id };
                return .{ .vs = vs.withCombat(cs) };
            } else {
                return .{ .command = .{ .play_card = id } };
            }
            // IN PLAY CARD
        } else if (self.inPlayZone(self.arena).hitTest(vs, pos)) |hit| {
            return .{ .command = .{ .cancel_card = hit.cardId() } };
            // ENEMIES
        } else if (self.opposition.hitTest(pos)) |sprite| {
            return .{ .command = .{ .select_target = .{ .target_id = sprite.id } } };
            // END TURN
        } else if (self.end_turn_btn.hitTest(pos)) {
            if (self.combat_phase == .player_card_selection) {
                return .{ .command = .{ .end_turn = {} } };
            } else if (self.combat_phase == .commit_phase) {
                return .{ .command = .{ .commit_turn = {} } };
            }
        }
        return .{};
    }

    fn handleRelease(self: *CombatView, vs: ViewState) InputResult {
        const cs = vs.combat orelse CombatUIState{};
        if (cs.drag) |drag| {
            // Clear drag state
            var new_cs = cs;
            new_cs.drag = null;

            // If valid play target, dispatch commit_stack command
            if (drag.target_play_index) |target_index| {
                return .{
                    .vs = vs.withCombat(new_cs),
                    .command = .{ .commit_stack = .{
                        .card_id = drag.id,
                        .target_play_index = target_index,
                    } },
                };
            }

            return .{ .vs = vs.withCombat(new_cs) };
        } else {
            // Mouse released: fire event, unless rolled off target since click
            if (vs.clicked) |pos| {
                const click_res = self.onClick(vs, pos);
                const release_res = self.onClick(vs, vs.mouse);
                if (std.meta.eql(click_res, release_res)) return release_res;
            }
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

    // Renderables
    pub fn renderables(self: *const CombatView, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        const cs = vs.combat orelse CombatUIState{};

        var list = try std.ArrayList(Renderable).initCapacity(alloc, 32);

        try list.append(alloc, self.player_avatar.renderable());
        try self.opposition.appendRenderables(alloc, &list);

        // Player cards - render in_play first (behind), then hand (in front)
        var last: ?Renderable = null;

        // During commit phase, render plays as stacked groups; otherwise flat cards
        if (self.combat_phase == .commit_phase) {
            try self.playerPlayZone(alloc).appendRenderables(alloc, vs, &list, &last);
        } else {
            try self.inPlayZone(alloc).appendRenderables(alloc, vs, &list, &last);
        }
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
