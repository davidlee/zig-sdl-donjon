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
const conditions_mod = @import("conditions.zig");

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
const EnemyTimelineStrip = play_mod.EnemyTimelineStrip;
const PlayerAvatar = combat_mod.Player;
const EnemySprite = combat_mod.Enemy;
const Opposition = combat_mod.Opposition;
const StanceView = combat_mod.StanceView;
const CardZoneView = combat_mod.CardZoneView;
const CarouselView = combat_mod.CarouselView;
const getLayout = combat_mod.getLayout;
const getLayoutOffset = combat_mod.getLayoutOffset;

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
        // Prefer snapshot's turn_phase (DTO pattern) over direct world query
        const phase = if (snapshot) |snap| snap.turn_phase else world.turnPhase();

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

    // --- New query methods (use CombatState zones + action_registry) ---

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
        const action_inst = self.world.action_registry.getConst(play.action) orelse return null;

        var pvd = PlayViewData{
            .owner_id = owner.id,
            .owner_is_player = owner.director == .player,
            .action = CardViewData.fromInstance(action_inst, .in_play, true, true),
            .stakes = play.effectiveStakes(),
            .time_start = slot.time_start,
            .time_end = slot.timeEnd(&self.world.action_registry),
            .channels = domain_combat.getPlayChannels(slot.play, &self.world.action_registry),
        };

        // Add modifiers
        for (play.modifiers()) |entry| {
            const mod_inst = self.world.action_registry.getConst(entry.card_id) orelse continue;
            pvd.modifier_stack_buf[pvd.modifier_stack_len] = CardViewData.fromInstance(mod_inst, .in_play, true, true);
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

    // -------------------------------------------------------------------------
    // Enemy Interaction
    // -------------------------------------------------------------------------

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

    const FocusedEnemy = struct {
        agent: *const Agent,
        index: usize,
    };

    /// Cycle focused enemy by direction (-1 = left, 1 = right), returns updated CombatUIState
    fn cycleFocusedEnemy(self: *const View, cs: CombatUIState, dir: i8) ?CombatUIState {
        const enemy_count = self.opposition.enemies.len;
        if (enemy_count <= 1) return null;

        const focused = self.getFocusedEnemy(cs) orelse return null;

        var new_cs = cs;
        if (dir < 0) {
            // Left - go to previous (or wrap to end)
            new_cs.focused_enemy = if (focused.index == 0)
                self.opposition.enemies[enemy_count - 1].id
            else
                self.opposition.enemies[focused.index - 1].id;
        } else {
            // Right - go to next (or wrap to start)
            new_cs.focused_enemy = if (focused.index >= enemy_count - 1)
                self.opposition.enemies[0].id
            else
                self.opposition.enemies[focused.index + 1].id;
        }
        return new_cs;
    }

    /// Hit test enemy timeline nav arrows, returns updated CombatUIState if hit
    fn hitTestEnemyNav(self: *const View, cs: CombatUIState, pos: Point) ?CombatUIState {
        const enemy_count = self.opposition.enemies.len;
        if (enemy_count <= 1) return null;

        const focused = self.getFocusedEnemy(cs) orelse return null;

        // Create strip just for hit testing (plays data not needed)
        const strip = EnemyTimelineStrip.init(&.{}, "", focused.index, enemy_count);

        if (strip.hitTestNav(pos)) |dir| {
            return self.cycleFocusedEnemy(cs, dir);
        }
        return null;
    }

    /// Get the currently focused enemy (for timeline display and default targeting).
    /// Priority: UI focused_enemy > attention.primary > first enemy
    fn getFocusedEnemy(self: *const View, ui: CombatUIState) ?FocusedEnemy {
        if (self.opposition.enemies.len == 0) return null;

        // Check explicit UI focus
        if (ui.focused_enemy) |focused_id| {
            for (self.opposition.enemies, 0..) |e, i| {
                if (e.id.eql(focused_id)) {
                    return .{ .agent = e, .index = i };
                }
            }
        }

        // Fall back to attention primary
        if (self.world.encounter) |enc| {
            if (enc.stateForConst(self.world.player.id)) |enc_state| {
                if (enc_state.attention.primary) |primary_id| {
                    for (self.opposition.enemies, 0..) |e, i| {
                        if (e.id.eql(primary_id)) {
                            return .{ .agent = e, .index = i };
                        }
                    }
                }
            }
        }

        // Default to first enemy
        return .{ .agent = self.opposition.enemies[0], .index = 0 };
    }

    /// Render tooltip showing enemy conditions on hover
    fn appendEnemyTooltip(
        self: *const View,
        alloc: std.mem.Allocator,
        list: *std.ArrayList(Renderable),
        enemy_id: entity.ID,
        mouse_pos: Point,
    ) !void {
        // Find the enemy agent
        var enemy_agent: ?*const Agent = null;
        for (self.opposition.enemies) |e| {
            if (e.id.eql(enemy_id)) {
                enemy_agent = e;
                break;
            }
        }

        const agent = enemy_agent orelse return;

        // Get conditions for display
        const engagement = if (self.world.encounter) |encounter|
            encounter.getPlayerEngagementConst(enemy_id)
        else
            null;
        const conds = conditions_mod.getDisplayConditions(agent, engagement);

        // Calculate tooltip size based on conditions
        const line_height: f32 = 18;
        const padding: f32 = 8;
        const tooltip_w: f32 = 160;
        const tooltip_h: f32 = padding * 2 + @as(f32, @floatFromInt(@max(conds.len, 1))) * line_height;

        const tooltip_x = mouse_pos.x - tooltip_w / 2;
        const tooltip_y = mouse_pos.y + 15;

        // Tooltip background
        try list.append(alloc, .{
            .filled_rect = .{
                .rect = .{ .x = tooltip_x, .y = tooltip_y, .w = tooltip_w, .h = tooltip_h },
                .color = .{ .r = 40, .g = 40, .b = 40, .a = 230 },
            },
        });

        // Render conditions
        if (conds.len == 0) {
            try list.append(alloc, .{ .text = .{
                .content = "(no conditions)",
                .pos = .{ .x = tooltip_x + padding, .y = tooltip_y + padding },
                .font_size = .small,
                .color = .{ .r = 120, .g = 120, .b = 120, .a = 255 },
            } });
        } else {
            for (conds.constSlice(), 0..) |cond, i| {
                try list.append(alloc, .{ .text = .{
                    .content = cond.label,
                    .pos = .{
                        .x = tooltip_x + padding,
                        .y = tooltip_y + padding + @as(f32, @floatFromInt(i)) * line_height,
                    },
                    .font_size = .small,
                    .color = cond.color,
                } });
            }
        }
    }

    // -------------------------------------------------------------------------
    // Card Data
    // -------------------------------------------------------------------------

    fn buildCardList(
        self: *const View,
        alloc: std.mem.Allocator,
        source: CardViewData.Source,
        ids: []const entity.ID,
    ) []const CardViewData {
        const result = alloc.alloc(CardViewData, ids.len) catch return &.{};
        var count: usize = 0;

        for (ids) |id| {
            const inst = self.world.action_registry.getConst(id) orelse continue;
            const playable = self.isCardPlayable(id);
            const has_targets = self.cardHasValidTargets(id);
            result[count] = CardViewData.fromInstance(inst, source, playable, has_targets);
            count += 1;
        }

        return result[0..count];
    }

    /// Check if a card is playable using snapshot.
    fn isCardPlayable(self: *const View, card_id: entity.ID) bool {
        const snap = self.snapshot orelse
            std.debug.panic("isCardPlayable called without snapshot - coordinator must provide snapshot for combat view", .{});
        return snap.isCardPlayable(card_id);
    }

    /// Check if a card has valid targets using snapshot.
    fn cardHasValidTargets(self: *const View, card_id: entity.ID) bool {
        const snap = self.snapshot orelse return true;
        return snap.cardHasValidTargets(card_id);
    }

    // Input handling - returns optional command and/or view state update
    //
    //
    pub fn handleInput(self: *View, event: s.events.Event, world: *const World, vs: ViewState) InputResult {
        _ = world;
        const cs = vs.combat orelse CombatUIState{};

        // Stance selection phase uses dedicated view
        if (self.inPhase(.stance_selection)) {
            const center = Point{ .x = vs.viewport.w / 2, .y = vs.viewport.h / 2 };
            var stance_view = StanceView.init(center, 240);
            return stance_view.handleInput(event, vs);
        }

        switch (event) {
            .mouse_button_down => |data| {
                if (self.hitTestPlayerCards(vs)) |hit| {
                    // Only start immediate drag for drag-only cards (modifiers in commit phase)
                    if (self.shouldStartImmediateDrag(hit)) {
                        const source: DragState.DragSource = switch (hit) {
                            .card => .hand,
                            .play => .timeline,
                        };
                        var new_cs = cs;
                        new_cs.drag = .{
                            .original_pos = vs.mouse_vp,
                            .id = hit.cardId(),
                            .start_time = data.common.timestamp,
                            .source = source,
                        };
                        return .{ .vs = vs.withCombat(new_cs) };
                    }
                }
                // For all other cards: record click, timing determines click vs drag later
                var new_vs = vs;
                new_vs.clicked = vs.mouse_vp;
                new_vs.click_time = data.common.timestamp;
                return .{ .vs = new_vs };
            },
            .mouse_button_up => |data| {
                return self.handleRelease(vs, data.common.timestamp);
            },
            .mouse_motion => |data| {
                if (cs.drag) |drag| {
                    return self.handleDragging(vs, drag);
                }
                // Check if we should start a delayed drag (held > 250ms without drag state)
                if (vs.clicked != null and vs.click_time != null) {
                    const hold_duration = data.common.timestamp -| vs.click_time.?;
                    if (hold_duration >= click_threshold_ns) {
                        // Held long enough - start drag if card is draggable
                        if (self.hitTestPlayerCards(vs)) |hit| {
                            if (self.isCardDraggable(hit)) {
                                const source: DragState.DragSource = switch (hit) {
                                    .card => .hand,
                                    .play => .timeline,
                                };
                                var new_cs = cs;
                                new_cs.drag = .{
                                    .original_pos = vs.clicked.?,
                                    .id = hit.cardId(),
                                    .start_time = vs.click_time.?,
                                    .source = source,
                                };
                                var new_vs = vs;
                                new_vs.clicked = null;
                                new_vs.click_time = null;
                                return .{ .vs = new_vs.withCombat(new_cs) };
                            }
                        }
                    }
                }
                return self.handleHover(vs);
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

        // Clear any previous targets
        new_cs.drag.?.target = null;
        new_cs.drag.?.target_play_index = null;
        new_cs.drag.?.target_time = null;
        new_cs.drag.?.target_channel = null;
        new_cs.drag.?.is_valid_drop = false;

        // Get the dragged card
        const card = self.world.action_registry.getConst(drag.id) orelse
            return .{ .vs = vs.withCombat(new_cs) };

        if (self.inPhase(.commit_phase)) {
            // Commit phase: modifier attachment to plays
            if (card.template.kind != .modifier)
                return .{ .vs = vs.withCombat(new_cs) };

            const tl = self.timeline(self.arena);
            if (tl.hitTestPlay(vs, vs.mouse_vp)) |play_index| {
                const snapshot = self.snapshot orelse return .{ .vs = vs.withCombat(new_cs) };
                if (!snapshot.canModifierAttachToPlay(drag.id, play_index))
                    return .{ .vs = vs.withCombat(new_cs) };

                const enc = self.world.encounter orelse return .{ .vs = vs.withCombat(new_cs) };
                const enc_state = enc.stateForConst(self.world.player.id) orelse
                    return .{ .vs = vs.withCombat(new_cs) };
                const slots = enc_state.current.slots();
                if (play_index >= slots.len)
                    return .{ .vs = vs.withCombat(new_cs) };

                const play = &slots[play_index].play;
                if (play.wouldConflict(card.template, &self.world.action_registry))
                    return .{ .vs = vs.withCombat(new_cs) };

                new_cs.drag.?.target_play_index = play_index;
            }
        } else if (self.inPhase(.player_card_selection)) {
            // Selection phase: track timeline drop position
            if (play_mod.TimelineView.hitTestDrop(vs.mouse_vp)) |drop| {
                new_cs.drag.?.target_time = drop.time;
                new_cs.drag.?.target_channel = drop.channel;
                new_cs.drag.?.is_valid_drop = true; // TODO: validate conflicts
            }
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

    /// Returns true if card should start drag immediately on mouse_down.
    /// Only for cards that can ONLY be dragged (no click action) - i.e. modifiers in commit phase.
    /// Selection phase cards use click-or-drag timing instead.
    fn shouldStartImmediateDrag(self: *const View, hit: HitResult) bool {
        const id = hit.cardId();
        const card = self.world.action_registry.getConst(id) orelse return false;

        // Only commit phase modifiers start drag immediately
        if (self.inPhase(.commit_phase)) {
            return self.isCardPlayable(id) and card.template.kind == .modifier;
        }
        return false;
    }

    /// Returns true if card can be dragged (used for visual feedback, not drag initiation).
    fn isCardDraggable(self: *const View, hit: HitResult) bool {
        const id = hit.cardId();
        const card = self.world.action_registry.getConst(id) orelse return false;
        _ = card;

        if (self.inPhase(.commit_phase)) {
            // Commit phase: only modifiers
            return self.isCardPlayable(id) and self.world.action_registry.getConst(id).?.template.kind == .modifier;
        } else if (self.inPhase(.player_card_selection)) {
            // Selection phase: playable hand cards or timeline cards
            return switch (hit) {
                .card => self.isCardPlayable(id),
                .play => true,
            };
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

        // ENEMY TIMELINE NAV ARROWS (both phases)
        if (self.hitTestEnemyNav(cs, pos)) |new_cs| {
            return .{ .vs = vs.withCombat(new_cs) };
        }

        // CAROUSEL (hand + always-available cards)
        if (self.carousel(self.arena).hitTest(vs, pos, self.arena)) |hit| {
            const id = hit.cardId();
            // Click on card: play (selection) or add (commit)
            // Note: drag is initiated on mouse_down in handleInput, not here
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

        // ENEMIES - click to focus (and select target)
        if (self.opposition.hitTest(pos)) |sprite| {
            var new_cs = cs;
            new_cs.focused_enemy = sprite.id;
            return .{
                .command = .{ .select_target = .{ .target_id = sprite.id } },
                .vs = vs.withCombat(new_cs),
            };
        }

        // Note: End Turn button is now handled by chrome layer

        return .{};
    }

    const click_threshold_ns: u64 = 250_000_000; // 250ms in nanoseconds

    fn handleRelease(self: *View, vs: ViewState, release_time: u64) InputResult {
        const cs = vs.combat orelse CombatUIState{};

        // Clear click state for next interaction
        var new_vs = vs;
        new_vs.clicked = null;
        new_vs.click_time = null;

        if (cs.drag) |drag| {
            // Clear drag state
            var new_cs = cs;
            new_cs.drag = null;

            // Check if this was a quick drag (< 250ms) - treat as click
            const drag_duration = release_time -| drag.start_time;
            const is_quick = drag_duration < click_threshold_ns;

            if (is_quick) {
                // Quick drag = click: delegate to onClick at original position
                var result = self.onClick(new_vs.withCombat(new_cs), drag.original_pos);
                if (result.vs == null) result.vs = new_vs.withCombat(new_cs);
                return result;
            }

            // Commit phase: modifier stacking (existing behavior)
            if (drag.target_play_index) |target_index| {
                return .{
                    .vs = new_vs.withCombat(new_cs),
                    .command = .{ .commit_stack = .{
                        .card_id = drag.id,
                        .target_play_index = target_index,
                    } },
                };
            }

            // Selection phase: reorder within timeline (time repositioning only for now)
            // Lane switching requires more validation - cards can only switch weapon ↔ off_hand
            if (drag.source == .timeline and drag.is_valid_drop) {
                if (drag.target_time) |time| {
                    return .{
                        .vs = new_vs.withCombat(new_cs),
                        .command = .{
                            .move_play = .{
                                .card_id = drag.id,
                                .new_time_start = time,
                                .new_channel = null, // keep current channel for now
                            },
                        },
                    };
                }
            }

            // No valid drop target - just clear drag
            return .{ .vs = new_vs.withCombat(new_cs) };
        } else {
            // Non-drag release: check if quick click (<250ms)
            if (vs.clicked) |pos| {
                const is_click = if (vs.click_time) |start_time|
                    (release_time -| start_time) < click_threshold_ns
                else
                    // Fallback: position-based (same pos = click)
                    std.meta.eql(pos, vs.mouse_vp);

                if (is_click) {
                    var result = self.onClick(new_vs, pos);
                    if (result.vs == null) result.vs = new_vs;
                    return result;
                }
            }
        }
        return .{ .vs = new_vs };
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
            .left => {
                if (self.cycleFocusedEnemy(cs, -1)) |new_cs| {
                    return .{ .vs = vs.withCombat(new_cs) };
                }
            },
            .right => {
                if (self.cycleFocusedEnemy(cs, 1)) |new_cs| {
                    return .{ .vs = vs.withCombat(new_cs) };
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
        const card = self.world.action_registry.getConst(card_id) orelse
            return self.startCardAnimation(vs, card_id, from_rect, null);

        if (card.template.requiresSingleTarget()) {
            const cs = vs.combat orelse CombatUIState{};
            // Use focused enemy as default target (skips targeting mode)
            if (self.getFocusedEnemy(cs)) |focused| {
                return self.startCardAnimation(vs, card_id, from_rect, focused.agent.id);
            }
            // Fallback: single enemy auto-target or targeting mode
            const enemy_count = self.opposition.enemies.len;
            if (enemy_count == 1) {
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
        const card = self.world.action_registry.getConst(card_id) orelse
            return .{ .command = .{ .commit_add = .{ .card_id = card_id } } };

        if (card.template.requiresSingleTarget()) {
            const cs = vs.combat orelse CombatUIState{};
            // Use focused enemy as default target (skips targeting mode)
            if (self.getFocusedEnemy(cs)) |focused| {
                return .{ .command = .{ .commit_add = .{ .card_id = card_id, .target = focused.agent.id } } };
            }
            // Fallback: single enemy auto-target or targeting mode
            const enemy_count = self.opposition.enemies.len;
            if (enemy_count == 1) {
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

        // Stance selection phase uses dedicated view + enemy sprites for context
        if (self.inPhase(.stance_selection)) {
            // Render enemies (engagement distance is important context for stance choice)
            try self.opposition.appendRenderables(alloc, &list, self.world.encounter, null, null);

            const center = Point{ .x = vs.viewport.w / 2, .y = vs.viewport.h / 2 };
            const stance_view = StanceView.init(center, 240);
            try stance_view.appendRenderables(alloc, &list, vs);
            return list;
        }

        // Get encounter and primary target for enemy rendering
        const enc = self.world.encounter;
        const primary_target = if (enc) |e|
            if (e.stateForConst(self.world.player.id)) |enc_state| enc_state.attention.primary else null
        else
            null;

        // Get focused enemy for border highlight
        const focused_enemy_id = if (self.getFocusedEnemy(cs)) |f| f.agent.id else null;

        try list.append(alloc, self.player_avatar.renderable());
        try self.opposition.appendRenderables(alloc, &list, enc, primary_target, focused_enemy_id);

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
            try self.opposition.appendRenderables(alloc, &list, enc, primary_target, focused_enemy_id);
        }

        // Player cards - timeline for plays, carousel for hand
        var last: ?Renderable = null;

        // Timeline shows committed plays (both selection and commit phases)
        try self.timeline(alloc).appendRenderables(alloc, vs, &list, &last);

        // Carousel: hand + known cards at bottom edge
        try self.carousel(alloc).appendRenderables(alloc, vs, &list, &last);

        // Enemy timeline strip - shows name/arrows always, plays only in commit phase
        if (self.getFocusedEnemy(cs)) |focused| {
            const plays = if (self.inPhase(.commit_phase))
                self.enemyPlays(alloc, focused.agent)
            else
                &[_]PlayViewData{}; // empty during selection phase
            const strip = EnemyTimelineStrip.init(
                plays,
                focused.agent.name.value(),
                focused.index,
                self.opposition.enemies.len,
            );
            try strip.appendRenderables(alloc, &list);
        }

        // Render animating cards at their current interpolated position
        for (cs.activeAnimations()) |anim| {
            if (self.world.action_registry.getConst(anim.card_id)) |card| {
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
                    .warning = false,
                });
                try list.append(alloc, .{ .card = .{ .model = card_vm, .dst = current_rect } });
            }
        }

        // Render hovered/dragged card last (on top)
        if (last) |item| try list.append(alloc, item);

        // Render dragged card following cursor
        if (cs.drag) |drag| {
            if (self.world.action_registry.getConst(drag.id)) |card| {
                const dims = card_mod.Layout.defaultDimensions();
                // Center card on cursor
                const card_rect = Rect{
                    .x = vs.mouse_vp.x - dims.w / 2,
                    .y = vs.mouse_vp.y - dims.h / 2,
                    .w = dims.w,
                    .h = dims.h,
                };
                const card_vm = CardViewModel.fromTemplate(drag.id, card.template, .{
                    .target = false,
                    .played = true,
                    .disabled = false,
                    .highlighted = true,
                    .warning = false,
                });
                try list.append(alloc, .{ .card = .{ .model = card_vm, .dst = card_rect } });
            }
        }

        // Note: End Turn button and status bars are now rendered by chrome layer

        // Enemy hover tooltip
        if (cs.hover == .enemy) {
            try self.appendEnemyTooltip(alloc, &list, cs.hover.enemy, vs.mouse_vp);
        }

        // TODO: engagement info / advantage bars
        // TODO: phase indicator

        return list;
    }
};
