// Combat View - combat encounter screen
//
// Displays player hand, enemies, engagements, combat phase.
// Handles card selection, targeting, reactions.
// Access as: combat.view.View or combat.View

const std = @import("std");
const views = @import("../view.zig");
const view_state = @import("../../view_state.zig");
const infra = @import("infra");
const w = @import("../../../domain/world.zig");
const World = w.World;
const cards = @import("../../../domain/cards.zig");
const domain_combat = @import("../../../domain/combat.zig");
const s = @import("sdl3");
const entity = infra.entity;
const chrome = @import("../chrome.zig");
const apply = @import("../../../domain/apply.zig");
const card_mod = @import("../card/mod.zig");
const combat_mod = @import("mod.zig");
const hit_mod = combat_mod.hit;
const play_mod = combat_mod.play;

const Renderable = views.Renderable;
const AssetId = views.AssetId;
const Point = views.Point;
const Rect = views.Rect;
const CardViewModel = card_mod.Model;
const CardModelState = card_mod.State;
const ViewState = views.ViewState;
const CombatUIState = views.CombatUIState;
const CardAnimation = view_state.CardAnimation;
const DragState = views.DragState;
const InputResult = views.InputResult;
const Command = infra.commands.Command;
const Agent = domain_combat.Agent;
const ID = infra.commands.ID;
const Keycode = s.keycode.Keycode;
const card_renderer = @import("../../card_renderer.zig");

// Type aliases from card module
const CardViewData = card_mod.Data;
const CardLayout = card_mod.Layout;

// Type aliases from combat module
const ViewZone = hit_mod.Zone;
const HitResult = hit_mod.Hit;
const CardViewState = hit_mod.Interaction;
const PlayViewData = play_mod.Data;
const PlayZoneView = play_mod.Zone;
const EndTurnButton = combat_mod.EndTurn;
const PlayerAvatar = combat_mod.Player;
const EnemySprite = combat_mod.Enemy;
const Opposition = combat_mod.Opposition;
const StatusBarView = combat_mod.StatusBar;

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
                return .{ .card = .{ .id = self.cards[i].id, .zone = self.zone, .rect = rect } };
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
            // Skip cards that are being animated (they're rendered separately)
            if (ui.isAnimating(card.id)) continue;

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

/// View - view model for representing and interacting with combat
/// requires an active encounter.
pub const View = struct {
    world: *const World,
    arena: std.mem.Allocator,
    end_turn_btn: EndTurnButton,
    player_avatar: PlayerAvatar,
    opposition: Opposition,
    turn_phase: ?domain_combat.TurnPhase,

    pub fn init(world: *const World, arena: std.mem.Allocator) View {
        const phase = world.turnPhase();

        return .{
            .world = world,
            .arena = arena,
            .end_turn_btn = EndTurnButton.init(phase),
            .player_avatar = PlayerAvatar.init(),
            .opposition = Opposition.init(world.encounter.?.enemies.items),
            .turn_phase = phase,
        };
    }

    /// Check if currently in a specific turn phase.
    fn inPhase(self: *const View, phase: domain_combat.TurnPhase) bool {
        return self.turn_phase == phase;
    }

    // --- New query methods (use CombatState zones + card_registry) ---

    /// Dealt cards in player's hand
    pub fn handCards(self: *const View, alloc: std.mem.Allocator) []const CardViewData {
        const player = self.world.player;
        const cs = player.combat_state orelse return &.{};
        return self.buildCardList(alloc, .hand, cs.hand.items);
    }

    /// Player cards currently in play (selection phase, before commit)
    pub fn inPlayCards(self: *const View, alloc: std.mem.Allocator) []const CardViewData {
        const player = self.world.player;
        const cs = player.combat_state orelse return &.{};
        return self.buildCardList(alloc, .in_play, cs.in_play.items);
    }

    /// Player always known cards (techniques mostly)
    pub fn alwaysCards(self: *const View, alloc: std.mem.Allocator) []const CardViewData {
        const player = self.world.player;
        return self.buildCardList(alloc, .always_available, player.always_available.items);
    }

    /// Enemy cards in play (shown during commit phase).
    /// Unlike player cards, these are always shown as "playable" (not greyed out).
    fn enemyInPlayCards(self: *const View, alloc: std.mem.Allocator, agent: *const Agent) []const CardViewData {
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
    pub fn playerPlays(self: *const View, alloc: std.mem.Allocator) []const PlayViewData {
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
        self: *const View,
        alloc: std.mem.Allocator,
        play: *const domain_combat.Play,
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
    fn playerPlayZone(self: *const View, alloc: std.mem.Allocator) PlayZoneView {
        return PlayZoneView.init(getLayout(.player_plays), self.playerPlays(alloc));
    }

    /// Enemy plays for commit phase (action + modifier stacks)
    fn enemyPlays(self: *const View, alloc: std.mem.Allocator, agent: *const Agent) []const PlayViewData {
        const enc = self.world.encounter orelse return &.{};
        const enc_state = enc.stateForConst(agent.id) orelse return &.{};
        const plays = enc_state.current.plays();

        const result = alloc.alloc(PlayViewData, plays.len) catch return &.{};
        var count: usize = 0;
        for (plays) |*play| {
            if (self.buildPlayViewData(alloc, play, agent)) |pvd| {
                result[count] = pvd;
                count += 1;
            }
        }
        return result[0..count];
    }

    /// Get PlayZoneView for enemy during commit phase
    fn enemyPlayZone(self: *const View, alloc: std.mem.Allocator, agent: *const Agent, offset: Point) PlayZoneView {
        var layout = getLayout(.enemy_plays);
        layout.start_x += offset.x;
        layout.y += offset.y;
        return .{ .plays = self.enemyPlays(alloc, agent), .layout = layout };
    }

    fn buildCardList(
        self: *const View,
        alloc: std.mem.Allocator,
        source: CardViewData.Source,
        ids: []const entity.ID,
    ) []const CardViewData {
        const result = alloc.alloc(CardViewData, ids.len) catch return &.{};
        var count: usize = 0;

        const player = self.world.player;
        const phase = self.turn_phase orelse return &.{};

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
    pub fn handleInput(self: *View, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
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

    fn hitTestPlayerCards(self: *View, vs: ViewState) ?HitResult {
        if (self.alwaysZone(self.arena).hitTest(vs, vs.mouse)) |hit| {
            return hit;
        } else if (self.handZone(self.arena).hitTest(vs, vs.mouse)) |hit| {
            return hit;
        }
        // During commit phase, hit test plays; during selection, hit test flat in_play
        if (self.inPhase(.commit_phase)) {
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

    fn handleDragging(self: *View, vs: ViewState, drag: DragState) InputResult {
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
        if (self.inPhase(.commit_phase)) {
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

    fn handleHover(self: *View, vs: ViewState) InputResult {
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

    fn isCardDraggable(self: *View, id: entity.ID) bool {
        const phase = self.turn_phase orelse return false;
        var registry = self.world.card_registry;
        if (registry.get(id)) |card| {
            const playable = apply.validateCardSelection(self.world.player, card, phase) catch |err| {
                std.debug.print("Error validating card playability: {s} -- {}", .{ card.template.name, err });
                return false;
            };
            if (playable) return if (card.template.kind == .modifier) true else false;
        }
        return false;
    }

    fn onClick(self: *View, vs: ViewState, pos: Point) InputResult {
        const in_commit = self.inPhase(.commit_phase);

        // ALWAYS AVAILABLE CARD
        if (self.alwaysZone(self.arena).hitTest(vs, pos)) |hit| {
            const id = hit.cardId();
            if (self.isCardDraggable(id)) {
                var cs = vs.combat orelse CombatUIState{};
                cs.drag = .{ .original_pos = pos, .id = id };
                return .{ .vs = vs.withCombat(cs) };
            }
            if (in_commit) {
                return .{ .command = .{ .commit_add = id } };
            } else {
                return self.startCardAnimation(vs, id, hit.card.rect);
            }
        }

        // IN HAND CARD
        if (self.handZone(self.arena).hitTest(vs, pos)) |hit| {
            const id = hit.cardId();
            if (self.isCardDraggable(id)) {
                var cs = vs.combat orelse CombatUIState{};
                cs.drag = .{ .original_pos = pos, .id = id };
                return .{ .vs = vs.withCombat(cs) };
            } else if (in_commit) {
                return .{ .command = .{ .commit_add = id } };
            } else {
                return self.startCardAnimation(vs, id, hit.card.rect);
            }
        }

        // PLAYS (commit phase) or IN PLAY CARDS (selection phase)
        if (in_commit) {
            if (self.playerPlayZone(self.arena).hitTest(vs, pos)) |hit| {
                // Commit phase: withdraw play (1F, refund stamina)
                return .{ .command = .{ .commit_withdraw = hit.cardId() } };
            }
        } else {
            if (self.inPlayZone(self.arena).hitTest(vs, pos)) |hit| {
                // Selection phase: cancel card
                return .{ .command = .{ .cancel_card = hit.cardId() } };
            }
        }

        // ENEMIES
        if (self.opposition.hitTest(pos)) |sprite| {
            return .{ .command = .{ .select_target = .{ .target_id = sprite.id } } };
        }

        // END TURN / COMMIT DONE
        if (self.end_turn_btn.hitTest(pos)) {
            if (self.inPhase(.player_card_selection)) {
                return .{ .command = .{ .end_turn = {} } };
            } else if (in_commit) {
                return .{ .command = .{ .commit_done = {} } };
            }
        }

        return .{};
    }

    fn handleRelease(self: *View, vs: ViewState) InputResult {
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

    fn handleKey(self: *View, keycode: Keycode, vs: ViewState) InputResult {
        _ = vs;
        switch (keycode) {
            .q => std.process.exit(0),
            .space => {
                if (self.inPhase(.commit_phase)) {
                    return .{ .command = .{ .commit_done = {} } };
                } else {
                    return .{ .command = .{ .end_turn = {} } };
                }
            },
            else => {},
        }
        return .{};
    }

    /// Start a card animation and return play_card command with updated viewstate
    fn startCardAnimation(_: *View, vs: ViewState, card_id: entity.ID, from_rect: Rect) InputResult {
        var cs = vs.combat orelse CombatUIState{};
        cs.addAnimation(.{
            .card_id = card_id,
            .from_rect = from_rect,
            .to_rect = null, // filled in by effect processing
            .progress = 0,
        });
        return .{
            .vs = vs.withCombat(cs),
            .command = .{ .play_card = card_id },
        };
    }

    // --- Zone helpers (use CardZoneView with CardViewData) ---

    fn handZone(self: *const View, alloc: std.mem.Allocator) CardZoneView {
        return CardZoneView.init(.hand, self.handCards(alloc));
    }

    fn inPlayZone(self: *const View, alloc: std.mem.Allocator) CardZoneView {
        return CardZoneView.init(.in_play, self.inPlayCards(alloc));
    }

    fn alwaysZone(self: *const View, alloc: std.mem.Allocator) CardZoneView {
        return CardZoneView.init(.always_available, self.alwaysCards(alloc));
    }

    // Renderables
    pub fn renderables(self: *const View, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        const cs = vs.combat orelse CombatUIState{};

        var list = try std.ArrayList(Renderable).initCapacity(alloc, 32);

        try list.append(alloc, self.player_avatar.renderable());
        try self.opposition.appendRenderables(alloc, &list);

        // Player cards - render in_play first (behind), then hand (in front)
        var last: ?Renderable = null;

        // During commit phase, render plays as stacked groups; otherwise flat cards
        if (self.inPhase(.commit_phase)) {
            try self.playerPlayZone(alloc).appendRenderables(alloc, vs, &list, &last);
        } else {
            try self.inPlayZone(alloc).appendRenderables(alloc, vs, &list, &last);
        }
        try self.handZone(alloc).appendRenderables(alloc, vs, &list, &last);
        try self.alwaysZone(alloc).appendRenderables(alloc, vs, &list, &last);

        // enemy plays (commit phase only)
        if (self.inPhase(.commit_phase)) {
            for (self.opposition.enemies, 0..) |enemy_agent, i| {
                const offset = Point{
                    .x = 400 + @as(f32, @floatFromInt(i)) * 200,
                    .y = 0,
                };
                const enemy_zone = self.enemyPlayZone(alloc, enemy_agent, offset);
                try enemy_zone.appendRenderables(alloc, vs, &list, &last);
            }
        }

        // Render animating cards at their current interpolated position
        for (cs.activeAnimations()) |anim| {
            if (self.world.card_registry.getConst(.{ .index = anim.card_id.index, .generation = anim.card_id.generation })) |card| {
                const card_vm = CardViewModel.fromTemplate(anim.card_id, card.template, .{
                    .target = false,
                    .played = false,
                    .disabled = false,
                    .highlighted = false,
                });
                try list.append(alloc, .{ .card = .{ .model = card_vm, .dst = anim.currentRect() } });
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
