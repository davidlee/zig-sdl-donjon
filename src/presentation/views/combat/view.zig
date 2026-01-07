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
const query = @import("../../../domain/query/mod.zig");
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
const TimelineView = play_mod.TimelineView;
const PlayerAvatar = combat_mod.Player;
const EnemySprite = combat_mod.Enemy;
const Opposition = combat_mod.Opposition;

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
                    .x = vs.mouse_vp.x - pad - (drag.original_pos.x - base_x),
                    .y = vs.mouse_vp.y - pad - (drag.original_pos.y - base_y),
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

/// Carousel view for hand + known cards at bottom edge.
/// Uses dock-style positioning: cards near mouse spread apart and raise.
const CarouselView = struct {
    hand_cards: []const CardViewData,
    known_cards: []const CardViewData,

    // Layout constants
    const viewport_h: f32 = 992; // logical_h - header - footer
    const viewport_w: f32 = 1420; // logical_w - sidebar_w
    const card_w: f32 = card_renderer.CARD_WIDTH;
    const card_h: f32 = card_renderer.CARD_HEIGHT;
    const base_y: f32 = viewport_h - card_h; // cards sit at bottom
    const base_spacing: f32 = 50; // 30px overlap with 80px cards
    const group_gap: f32 = 30; // extra gap between hand and known

    // Dock effect parameters
    const max_raise: f32 = 20; // max pixels to raise when mouse directly over
    const influence_radius_x: f32 = 100; // horizontal influence for spreading
    const influence_radius_y: f32 = 150; // vertical influence for raising
    const expand_ratio: f32 = 2.5; // how much the hovered gap expands relative to base
    const max_rotation: f32 = 15; // max degrees to tilt at edges

    /// Internal: card position + rotation for layout calculations
    const CardPlacement = struct {
        rect: Rect,
        rotation: f32,
    };

    fn init(hand: []const CardViewData, known: []const CardViewData) CarouselView {
        return .{ .hand_cards = hand, .known_cards = known };
    }

    fn totalCards(self: CarouselView) usize {
        return self.hand_cards.len + self.known_cards.len;
    }

    /// Get card data and zone for a carousel index
    fn cardAt(self: CarouselView, index: usize) struct { card: CardViewData, zone: ViewZone } {
        if (index < self.hand_cards.len) {
            return .{ .card = self.hand_cards[index], .zone = .hand };
        }
        return .{ .card = self.known_cards[index - self.hand_cards.len], .zone = .always_available };
    }

    /// Calculate X influence (0-1) for spreading - sharper falloff
    fn influenceX(dist: f32) f32 {
        if (dist >= influence_radius_x) return 0;
        const t = 1 - dist / influence_radius_x;
        return t * t * t; // cubic falloff for tighter focus
    }

    /// Calculate Y influence (0-1) for raising - based on distance from carousel
    fn influenceY(mouse_y: f32) f32 {
        const carousel_top = base_y;
        const dist = carousel_top - mouse_y; // positive when mouse is above carousel
        if (dist < 0) return 1.0; // mouse is in/below carousel = full influence
        if (dist >= influence_radius_y) return 0;
        const t = 1 - dist / influence_radius_y;
        return t * t;
    }

    /// Calculate base width (uniform spacing) for the carousel
    fn baseWidth(self: CarouselView) f32 {
        const n = self.totalCards();
        if (n == 0) return 0;
        const has_gap = self.hand_cards.len > 0 and self.known_cards.len > 0;
        const gap: f32 = if (has_gap) group_gap else 0;
        return @as(f32, @floatFromInt(n - 1)) * base_spacing + card_w + gap;
    }

    fn cardCentreFromRect(rect: Rect) Point {
        return Point{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 };
    }

    fn cardRectFromCentre(centre: Point) Rect {
        return Rect{ .x = centre.x - card_w / 2, .y = centre.y - card_h / 2, .w = card_w, .h = card_h };
    }

    /// Calculate all card placements with anchored spread algorithm.
    /// Outer cards stay fixed, spacing redistributes based on mouse proximity.
    /// Returns rect + rotation for each card.
    fn cardPlacements(self: CarouselView, mouse_x: f32, mouse_y: f32, alloc: std.mem.Allocator) []CardPlacement {
        const n = self.totalCards();
        if (n == 0) return &.{};

        const placements = alloc.alloc(CardPlacement, n) catch return &.{};
        const points = alloc.alloc(Point, n) catch return &.{};
        defer alloc.free(points);
        const weights = alloc.alloc(f32, n) catch return &.{};
        defer alloc.free(weights);

        // Fixed total width - outer cards anchored
        const total_width = self.baseWidth();
        const start_x = (viewport_w - total_width) / 2;

        const first_x = start_x + card_w / 2;
        const last_x = start_x + total_width - card_w / 2;
        const span = last_x - first_x;

        // Gap between hand and known groups
        const has_gap = self.hand_cards.len > 0 and self.known_cards.len > 0;
        const gap: f32 = if (has_gap) group_gap else 0;

        // Normalize mouse position to [0, 1] range, clamped to carousel bounds
        const m = std.math.clamp((mouse_x - first_x) / span, 0.0, 1.0);

        // How much displacement to apply (pixels)
        const max_displacement: f32 = 120;

        // Virtual margin - cards occupy [margin, 1-margin] so edges still move a bit
        const margin: f32 = 0.15;

        for (0..n) |i| {
            // Calculate base x position with gap between groups
            const base_x = blk: {
                if (n == 1) {
                    break :blk first_x + span / 2;
                }
                const spacing_count = n - 1;
                const spacing_per_card = (span - gap) / @as(f32, @floatFromInt(spacing_count));
                var x = first_x + @as(f32, @floatFromInt(i)) * spacing_per_card;
                // Add gap after hand cards
                if (i >= self.hand_cards.len) {
                    x += gap;
                }
                break :blk x;
            };

            // Normalized position for weight calc: t ∈ [margin, 1-margin]
            const t_raw: f32 = if (n == 1) 0.5 else (base_x - first_x) / span;
            const t: f32 = margin + t_raw * (1.0 - 2.0 * margin);

            // Calculate weight using sine formula
            // Left of mouse: negative (push toward left edge)
            // Right of mouse: positive (push toward right edge)
            const weight: f32 = if (t < m and m > 0.001)
                -@sin(std.math.pi * t / m)
            else if (t > m and m < 0.999)
                @sin(std.math.pi * (t - m) / (1.0 - m))
            else
                0;

            // Apply displacement
            const card_x = base_x + weight * max_displacement;

            // Y position with raise based on proximity to mouse
            const y_inf = influenceY(mouse_y);
            const x_dist = @abs(mouse_x - base_x);
            const x_inf = influenceX(x_dist);
            const raise = max_raise * x_inf * y_inf;

            points[i] = Point{ .x = card_x, .y = base_y - raise };
            weights[i] = weight;
        }

        for (0..n) |i| {
            placements[i] = .{
                .rect = cardRectFromCentre(points[i]),
                .rotation = weights[i] * max_rotation,
            };
        }

        return placements;
    }

    /// Hit test returns HitResult at given point
    fn hitTest(self: CarouselView, vs: ViewState, pt: Point, alloc: std.mem.Allocator) ?HitResult {
        const n = self.totalCards();
        if (n == 0) return null;

        const placements = self.cardPlacements(vs.mouse_vp.x, vs.mouse_vp.y, alloc);
        if (placements.len == 0) return null;

        // Reverse order so topmost (rightmost, last rendered) card is hit first
        var i = n;
        while (i > 0) {
            i -= 1;
            const card_info = self.cardAt(i);
            const ui = vs.combat orelse CombatUIState{};

            // Get rect with drag/hover adjustments
            const rect = self.adjustedRect(placements[i].rect, card_info.card.id, vs, ui);

            if (rect.pointIn(pt)) {
                return .{ .card = .{ .id = card_info.card.id, .zone = card_info.zone, .rect = rect } };
            }
        }
        return null;
    }

    /// Adjust rect for drag/hover state
    fn adjustedRect(self: CarouselView, base_rect: Rect, card_id: entity.ID, vs: ViewState, ui: CombatUIState) Rect {
        _ = self;
        const pad: f32 = 3;

        if (ui.drag) |drag| {
            if (drag.id.eql(card_id)) {
                return .{
                    .x = vs.mouse_vp.x - pad - (drag.original_pos.x - base_rect.x),
                    .y = vs.mouse_vp.y - pad - (drag.original_pos.y - base_rect.y),
                    .w = base_rect.w + pad,
                    .h = base_rect.h + pad,
                };
            }
        }

        // Hover expansion
        switch (ui.hover) {
            .card => |id| if (id.eql(card_id)) {
                return .{
                    .x = base_rect.x - pad,
                    .y = base_rect.y - pad,
                    .w = base_rect.w + pad * 2,
                    .h = base_rect.h + pad * 2,
                };
            },
            else => {},
        }

        return base_rect;
    }

    fn cardInteractionState(card_id: entity.ID, ui: CombatUIState) CardViewState {
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

    /// Render carousel cards
    fn appendRenderables(
        self: CarouselView,
        alloc: std.mem.Allocator,
        vs: ViewState,
        list: *std.ArrayList(Renderable),
        last: *?Renderable,
    ) !void {
        const n = self.totalCards();
        if (n == 0) return;

        const ui = vs.combat orelse CombatUIState{};
        const placements = self.cardPlacements(vs.mouse_vp.x, vs.mouse_vp.y, alloc);
        if (placements.len == 0) return;

        for (0..n) |i| {
            const card_info = self.cardAt(i);
            const card = card_info.card;

            // Skip cards that are being animated
            if (ui.isAnimating(card.id)) continue;

            const placement = placements[i];
            const rect = self.adjustedRect(placement.rect, card.id, vs, ui);
            const state = cardInteractionState(card.id, ui);
            const card_vm = CardViewModel.fromTemplate(card.id, card.template, .{
                .target = state == .target,
                .played = false,
                .disabled = !card.playable,
                .highlighted = state == .hover,
            });
            const item: Renderable = .{ .card = .{
                .model = card_vm,
                .dst = rect,
                .rotation = placement.rotation,
            } };

            if (state == .normal or state == .target) {
                try list.append(alloc, item);
            } else {
                last.* = item; // render last for z-order
            }
        }
    }
};

/// View - view model for representing and interacting with combat
/// requires an active encounter.
pub const View = struct {
    world: *const World,
    arena: std.mem.Allocator,
    player_avatar: PlayerAvatar,
    opposition: Opposition,
    turn_phase: ?domain_combat.TurnPhase,
    snapshot: ?*const query.CombatSnapshot,

    pub fn init(world: *const World, arena: std.mem.Allocator) View {
        return initWithSnapshot(world, arena, null);
    }

    pub fn initWithSnapshot(
        world: *const World,
        arena: std.mem.Allocator,
        snapshot: ?*const query.CombatSnapshot,
    ) View {
        const phase = world.turnPhase();

        return .{
            .world = world,
            .arena = arena,
            .player_avatar = PlayerAvatar.init(),
            .opposition = Opposition.init(world.encounter.?.enemies.items),
            .turn_phase = phase,
            .snapshot = snapshot,
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

    /// Player always known cards (techniques mostly)
    pub fn alwaysCards(self: *const View, alloc: std.mem.Allocator) []const CardViewData {
        const player = self.world.player;
        return self.buildCardList(alloc, .always_available, player.always_available.items);
    }

    /// Player's plays (from timeline - plays exist during both selection and commit phases)
    pub fn playerPlays(self: *const View, alloc: std.mem.Allocator) []const PlayViewData {
        const enc = self.world.encounter orelse return &.{};
        const enc_state = enc.stateForConst(self.world.player.id) orelse return &.{};

        const slots = enc_state.current.slots();
        const result = alloc.alloc(PlayViewData, slots.len) catch return &.{};
        var count: usize = 0;

        for (slots, 0..) |*slot, i| {
            if (self.buildPlayViewData(slot, self.world.player, i)) |pvd| {
                result[count] = pvd;
                count += 1;
            }
        }
        return result[0..count];
    }

    /// Build PlayViewData from domain Play
    fn buildPlayViewData(
        self: *const View,
        slot: *const domain_combat.TimeSlot,
        owner: *const Agent,
        play_index: usize,
    ) ?PlayViewData {
        const play = &slot.play;
        const action_inst = self.world.card_registry.getConst(play.action) orelse return null;

        var pvd = PlayViewData{
            .owner_id = owner.id,
            .owner_is_player = owner.director == .player,
            .action = CardViewData.fromInstance(action_inst, .in_play, true),
            .stakes = play.effectiveStakes(),
            .time_start = slot.time_start,
            .time_end = slot.timeEnd(&self.world.card_registry),
            .channels = domain_combat.getPlayChannels(slot.play, &self.world.card_registry),
        };

        // Add modifiers
        for (play.modifiers()) |entry| {
            const mod_inst = self.world.card_registry.getConst(entry.card_id) orelse continue;
            pvd.modifier_stack_buf[pvd.modifier_stack_len] = CardViewData.fromInstance(mod_inst, .in_play, true);
            pvd.modifier_stack_len += 1;
        }

        // Resolve target if offensive
        if (pvd.isOffensive()) {
            pvd.target_id = self.resolvePlayTarget(owner.id, play_index);
        }

        return pvd;
    }

    /// Resolve play target using snapshot.
    fn resolvePlayTarget(self: *const View, owner_id: entity.ID, play_index: usize) ?entity.ID {
        const snap = self.snapshot orelse return null;
        for (snap.play_statuses.items) |status| {
            if (status.owner_id.eql(owner_id) and status.play_index == play_index) {
                return status.target_id;
            }
        }
        return null;
    }

    /// Get PlayZoneView for commit phase
    fn playerPlayZone(self: *const View, alloc: std.mem.Allocator) PlayZoneView {
        return PlayZoneView.init(getLayout(.player_plays), self.playerPlays(alloc));
    }

    /// Enemy plays for commit phase (action + modifier stacks)
    fn enemyPlays(self: *const View, alloc: std.mem.Allocator, agent: *const Agent) []const PlayViewData {
        const enc = self.world.encounter orelse return &.{};
        const enc_state = enc.stateForConst(agent.id) orelse return &.{};
        const slots = enc_state.current.slots();

        const result = alloc.alloc(PlayViewData, slots.len) catch return &.{};
        var count: usize = 0;
        for (slots, 0..) |*slot, i| {
            if (self.buildPlayViewData(slot, agent, i)) |pvd| {
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

        for (ids) |id| {
            const inst = self.world.card_registry.getConst(id) orelse continue;
            const playable = self.isCardPlayable(id);
            result[count] = CardViewData.fromInstance(inst, source, playable);
            count += 1;
        }

        return result[0..count];
    }

    /// Check if a card is playable using snapshot.
    fn isCardPlayable(self: *const View, card_id: entity.ID) bool {
        const snap = self.snapshot orelse return false;
        return snap.isCardPlayable(card_id);
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
                            .original_pos = vs.mouse_vp,
                            .id = card_id,
                        };
                        return .{ .vs = vs.withCombat(new_cs) };
                    }
                }
                var new_vs = vs;
                new_vs.clicked = vs.mouse_vp;
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
        // Carousel (hand + known cards at bottom)
        if (self.carousel(self.arena).hitTest(vs, vs.mouse_vp, self.arena)) |hit| {
            return hit;
        }
        // Timeline for plays
        if (self.timeline(self.arena).hitTest(vs, vs.mouse_vp)) |hit| {
            return hit;
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

        // Hit test against timeline plays for modifier attachment
        const tl = self.timeline(self.arena);
        if (tl.hitTestPlay(vs, vs.mouse_vp)) |play_index| {
            // Check predicate match via pre-computed snapshot
            const snapshot = self.snapshot orelse return .{ .vs = vs.withCombat(new_cs) };
            if (!snapshot.canModifierAttachToPlay(drag.id, play_index))
                return .{ .vs = vs.withCombat(new_cs) };

            // Check for conflicts (needs actual play)
            const enc = self.world.encounter orelse return .{ .vs = vs.withCombat(new_cs) };
            const enc_state = enc.stateForConst(self.world.player.id) orelse
                return .{ .vs = vs.withCombat(new_cs) };
            const slots = enc_state.current.slots();
            if (play_index >= slots.len)
                return .{ .vs = vs.withCombat(new_cs) };

            const play = &slots[play_index].play;
            if (play.wouldConflict(card.template, &self.world.card_registry))
                return .{ .vs = vs.withCombat(new_cs) };

            // Valid target!
            new_cs.drag.?.target_play_index = play_index;
        }

        return .{ .vs = vs.withCombat(new_cs) };
    }

    fn handleHover(self: *View, vs: ViewState) InputResult {
        var hover: ?view_state.EntityRef = null;
        if (self.hitTestPlayerCards(vs)) |hit| {
            hover = .{ .card = hit.cardId() };
        } else if (self.opposition.hitTest(vs.mouse_vp)) |sprite| {
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

    fn isCardDraggable(self: *const View, id: entity.ID) bool {
        const card = self.world.card_registry.getConst(id) orelse return false;
        if (self.isCardPlayable(id)) {
            return card.template.kind == .modifier;
        }
        return false;
    }

    fn onClick(self: *View, vs: ViewState, pos: Point) InputResult {
        const in_commit = self.inPhase(.commit_phase);
        const cs = vs.combat orelse CombatUIState{};
        const in_targeting = cs.isTargeting();

        // If in targeting mode, only allow enemy selection or cancellation
        if (in_targeting) {
            if (self.opposition.hitTest(pos)) |sprite| {
                // Complete targeting with selected enemy
                // Use a default rect for animation (card is already conceptually "selected")
                const default_rect = Rect{ .x = 400, .y = 300, .w = 100, .h = 140 };
                return self.completeTargeting(vs, sprite.id, default_rect);
            }
            // Click anywhere else cancels targeting
            return self.cancelTargeting(vs);
        }

        // CAROUSEL (hand + always-available cards)
        if (self.carousel(self.arena).hitTest(vs, pos, self.arena)) |hit| {
            const id = hit.cardId();
            if (self.isCardDraggable(id)) {
                var new_cs = cs;
                new_cs.drag = .{ .original_pos = pos, .id = id };
                return .{ .vs = vs.withCombat(new_cs) };
            }
            if (in_commit) {
                return self.commitAddCard(vs, id);
            } else {
                return self.playCard(vs, id, hit.card.rect);
            }
        }

        // PLAYS on timeline
        if (self.timeline(self.arena).hitTest(vs, pos)) |hit| {
            if (in_commit) {
                // Commit phase: withdraw play (1F, refund stamina)
                return .{ .command = .{ .commit_withdraw = hit.cardId() } };
            } else {
                // Selection phase: cancel card
                return .{ .command = .{ .cancel_card = hit.cardId() } };
            }
        }

        // ENEMIES
        if (self.opposition.hitTest(pos)) |sprite| {
            return .{ .command = .{ .select_target = .{ .target_id = sprite.id } } };
        }

        // Note: End Turn button is now handled by chrome layer

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
                const release_res = self.onClick(vs, vs.mouse_vp);
                if (std.meta.eql(click_res, release_res)) return release_res;
            }
        }
        return .{};
    }

    fn handleKey(self: *View, keycode: Keycode, vs: ViewState) InputResult {
        const cs = vs.combat orelse CombatUIState{};

        switch (keycode) {
            .q => std.process.exit(0),
            .escape => {
                if (cs.isTargeting()) {
                    return self.cancelTargeting(vs);
                }
            },
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
    fn startCardAnimation(_: *View, vs: ViewState, card_id: entity.ID, from_rect: Rect, target: ?entity.ID) InputResult {
        var cs = vs.combat orelse CombatUIState{};
        cs.addAnimation(.{
            .card_id = card_id,
            .from_rect = from_rect,
            .to_rect = null, // computed lazily during rendering
            .progress = 0,
        });
        return .{
            .vs = vs.withCombat(cs),
            .command = .{ .play_card = .{ .card_id = card_id, .target = target } },
        };
    }

    /// Find a card's rect in the timeline (for animation destination)
    fn findCardRectInTimeline(self: *const View, card_id: entity.ID, alloc: std.mem.Allocator) ?Rect {
        const plays = self.playerPlays(alloc);
        for (plays) |play| {
            if (play.action.id.eql(card_id)) {
                return play_mod.TimelineView.cardRect(&play);
            }
        }
        return null;
    }

    /// Enter targeting mode - store card_id pending target selection
    fn enterTargetingMode(_: *View, vs: ViewState, card_id: entity.ID, for_commit: bool) InputResult {
        var cs = vs.combat orelse CombatUIState{};
        cs.pending_target_card = card_id;
        cs.targeting_for_commit = for_commit;
        return .{ .vs = vs.withCombat(cs) };
    }

    /// Complete targeting - play the pending card with selected target
    fn completeTargeting(self: *View, vs: ViewState, target_id: entity.ID, from_rect: Rect) InputResult {
        const cs = vs.combat orelse return .{};
        const card_id = cs.pending_target_card orelse return .{};
        const for_commit = cs.targeting_for_commit;

        // Clear targeting state
        var new_cs = cs;
        new_cs.pending_target_card = null;
        new_cs.targeting_for_commit = false;

        if (for_commit) {
            // Commit phase: issue commit_add with target
            return .{
                .vs = vs.withCombat(new_cs),
                .command = .{ .commit_add = .{ .card_id = card_id, .target = target_id } },
            };
        } else {
            // Selection phase: play card with target (animated)
            return self.startCardAnimation(vs.withCombat(new_cs), card_id, from_rect, target_id);
        }
    }

    /// Cancel targeting mode without playing
    fn cancelTargeting(_: *View, vs: ViewState) InputResult {
        var cs = vs.combat orelse return .{};
        cs.pending_target_card = null;
        cs.targeting_for_commit = false;
        return .{ .vs = vs.withCombat(cs) };
    }

    /// Handle playing a card - checks if targeting is required
    fn playCard(self: *View, vs: ViewState, card_id: entity.ID, from_rect: Rect) InputResult {
        const card = self.world.card_registry.getConst(card_id) orelse
            return self.startCardAnimation(vs, card_id, from_rect, null);

        if (card.template.requiresSingleTarget()) {
            const enemy_count = self.opposition.enemies.len;
            if (enemy_count == 1) {
                // Auto-assign single enemy
                const target_id = self.opposition.enemies[0].id;
                return self.startCardAnimation(vs, card_id, from_rect, target_id);
            }
            return self.enterTargetingMode(vs, card_id, false); // selection phase
        }
        return self.startCardAnimation(vs, card_id, from_rect, null);
    }

    /// Commit phase: add a card from hand/available (costs 1 Focus).
    /// Prompts for target selection if card requires single target.
    fn commitAddCard(self: *View, vs: ViewState, card_id: entity.ID) InputResult {
        const card = self.world.card_registry.getConst(card_id) orelse
            return .{ .command = .{ .commit_add = .{ .card_id = card_id } } };

        if (card.template.requiresSingleTarget()) {
            const enemy_count = self.opposition.enemies.len;
            if (enemy_count == 1) {
                // Auto-assign single enemy
                const target_id = self.opposition.enemies[0].id;
                return .{ .command = .{ .commit_add = .{ .card_id = card_id, .target = target_id } } };
            }
            return self.enterTargetingMode(vs, card_id, true); // commit phase
        }
        return .{ .command = .{ .commit_add = .{ .card_id = card_id } } };
    }

    // --- Zone helpers (use CardZoneView with CardViewData) ---

    fn handZone(self: *const View, alloc: std.mem.Allocator) CardZoneView {
        return CardZoneView.init(.hand, self.handCards(alloc));
    }

    fn alwaysZone(self: *const View, alloc: std.mem.Allocator) CardZoneView {
        return CardZoneView.init(.always_available, self.alwaysCards(alloc));
    }

    fn carousel(self: *const View, alloc: std.mem.Allocator) CarouselView {
        return CarouselView.init(self.handCards(alloc), self.alwaysCards(alloc));
    }

    /// Timeline view for commit phase (plays positioned by channel × time)
    fn timeline(self: *const View, alloc: std.mem.Allocator) TimelineView {
        return TimelineView.init(self.playerPlays(alloc));
    }

    // Renderables
    pub fn renderables(self: *const View, alloc: std.mem.Allocator, vs: ViewState) !std.ArrayList(Renderable) {
        const cs = vs.combat orelse CombatUIState{};

        var list = try std.ArrayList(Renderable).initCapacity(alloc, 32);

        // Get encounter and primary target for enemy rendering
        const enc = self.world.encounter;
        const primary_target = if (enc) |e|
            if (e.stateForConst(self.world.player.id)) |enc_state| enc_state.attention.primary else null
        else
            null;

        try list.append(alloc, self.player_avatar.renderable());
        try self.opposition.appendRenderables(alloc, &list, enc, primary_target);

        // Targeting mode: highlight valid targets with red border
        if (cs.isTargeting()) {
            for (self.opposition.enemies, 0..) |enemy, i| {
                const sprite = combat_mod.Enemy.init(enemy.id, i);
                const border: f32 = 3;
                try list.append(alloc, .{
                    .filled_rect = .{
                        .rect = .{
                            .x = sprite.rect.x - border,
                            .y = sprite.rect.y - border,
                            .w = sprite.rect.w + border * 2,
                            .h = sprite.rect.h + border * 2,
                        },
                        .color = .{ .r = 200, .g = 50, .b = 50, .a = 255 },
                    },
                });
            }
            // Re-render enemies on top of highlight boxes
            try self.opposition.appendRenderables(alloc, &list, enc, primary_target);
        }

        // Player cards - timeline for plays, carousel for hand
        var last: ?Renderable = null;

        // Timeline shows committed plays (both selection and commit phases)
        try self.timeline(alloc).appendRenderables(alloc, vs, &list, &last);

        // Carousel: hand + known cards at bottom edge
        try self.carousel(alloc).appendRenderables(alloc, vs, &list, &last);

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
                // Compute destination lazily from timeline if not set
                const to_rect = anim.to_rect orelse self.findCardRectInTimeline(anim.card_id, alloc);
                const current_rect = if (to_rect) |dest|
                    anim.interpolatedRect(dest)
                else
                    anim.from_rect;

                const card_vm = CardViewModel.fromTemplate(anim.card_id, card.template, .{
                    .target = false,
                    .played = false,
                    .disabled = false,
                    .highlighted = false,
                });
                try list.append(alloc, .{ .card = .{ .model = card_vm, .dst = current_rect } });
            }
        }

        // Render hovered/dragged card last (on top)
        if (last) |item| try list.append(alloc, item);

        // Note: End Turn button and status bars are now rendered by chrome layer

        switch (cs.hover) {
            .enemy => |_| {
                const xw = 240;
                const yh = 440;

                // tooltip
                try list.append(alloc, .{
                    .filled_rect = .{
                        .rect = .{ .x = vs.mouse_vp.x - xw / 2, .y = vs.mouse_vp.y + 15, .w = xw, .h = yh },
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

        // TODO: engagement info / advantage bars
        // TODO: phase indicator

        return list;
    }
};
