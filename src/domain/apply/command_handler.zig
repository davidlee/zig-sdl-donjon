//! Command handler - processes player commands to modify world state.
//!
//! Handles card playing, cancellation, and commit-phase operations
//! (withdraw, add, stack).

const std = @import("std");
const lib = @import("infra");
const cards = @import("../cards.zig");
const combat = @import("../combat.zig");
const events = @import("../events.zig");
const w = @import("../world.zig");
const entity = lib.entity;

const validation = @import("validation.zig");
const targeting = @import("targeting.zig");

const Event = events.Event;
const EventSystem = events.EventSystem;
const World = w.World;
const Agent = combat.Agent;
const Instance = cards.Instance;

pub const CommandError = error{
    CommandInvalid,
    InsufficientStamina,
    InsufficientTime,
    InsufficientFocus,
    InvalidGameState,
    WrongPhase,
    BadInvariant,
    CardNotInHand,
    CardNotInPlay,
    CardOnCooldown,
    TemplatesMismatch,
    PredicateFailed,
    ModifierConflict,
    NotImplemented,
};

// Internal helpers

/// Result of playing a card - contains the in-play ID and source info.
pub const PlayResult = struct {
    in_play_id: entity.ID,
    source: ?combat.PlaySource,
};

/// Move a card to in_play, reserving its costs.
/// For pool cards (always_available, spells_known), creates a clone.
/// Returns the ID of the card in play and its source info.
pub fn playValidCardReservingCosts(
    evs: *EventSystem,
    actor: *Agent,
    card: *Instance,
    registry: *w.ActionRegistry,
    target: ?entity.ID,
) !PlayResult {
    const cs = actor.combat_state orelse return error.InvalidGameState;
    const is_player = switch (actor.director) {
        .player => true,
        else => false,
    };

    const actor_meta: events.AgentMeta = .{ .id = actor.id, .player = is_player };

    // Track the ID that ends up in play and its source
    var in_play_id: entity.ID = card.id;
    var source: ?combat.PlaySource = null;

    if (actor.inAlwaysAvailable(card.id)) {
        const clone_result = try cs.createPoolClone(card.id, .always_available, registry);
        in_play_id = clone_result.clone_id;
        source = clone_result.source;
        try evs.push(Event{
            .card_cloned = .{ .clone_id = in_play_id, .master_id = card.id, .actor = actor_meta },
        });
        // Set cooldown immediately if template has one
        if (card.template.cooldown) |cd| {
            try cs.setCooldown(card.id, cd);
        }
    } else if (actor.inSpellsKnown(card.id)) {
        const clone_result = try cs.createPoolClone(card.id, .spells_known, registry);
        in_play_id = clone_result.clone_id;
        source = clone_result.source;
        try evs.push(Event{
            .card_cloned = .{ .clone_id = in_play_id, .master_id = card.id, .actor = actor_meta },
        });
        if (card.template.cooldown) |cd| {
            try cs.setCooldown(card.id, cd);
        }
    } else {
        // Hand card - remove from hand (timeline tracks it now)
        try cs.moveCard(card.id, .hand, .in_play);
        try evs.push(Event{
            .card_moved = .{ .instance = card.id, .from = .hand, .to = .in_play, .actor = actor_meta },
        });
        // source stays null for hand cards
    }

    // sink an event for the card being played (use in_play_id for the clone)
    try evs.push(Event{
        .played_action_card = .{ .instance = in_play_id, .template = card.template.id, .actor = actor_meta, .target = target },
    });

    // put a hold on the time & stamina costs for the UI to display / player state
    _ = actor.stamina.commit(card.template.cost.stamina);
    actor.time_available -= card.template.cost.time;

    try evs.push(Event{
        .card_cost_reserved = .{ .stamina = card.template.cost.stamina, .time = card.template.cost.time, .actor = actor_meta },
    });

    return .{ .in_play_id = in_play_id, .source = source };
}

pub const CommandHandler = struct {
    world: *World,

    fn sink(self: *CommandHandler, event: Event) !void {
        try self.world.events.push(event);
    }

    pub fn init(world: *World) CommandHandler {
        return CommandHandler{
            .world = world,
        };
    }

    pub fn handle(self: *CommandHandler, cmd: lib.Command) !void {
        switch (cmd) {
            .start_game => {
                try self.world.transitionTo(.in_encounter);
                // Encounter starts in stance_selection phase (initial FSM state)
            },
            .confirm_stance => |stance| {
                try self.confirmStance(stance);
            },
            .play_card => |data| {
                try self.playActionCard(data.card_id, data.target);
            },
            .cancel_card => |id| {
                try self.cancelActionCard(id);
            },
            .end_turn => {
                try self.world.transitionTurnTo(.commit_phase);
            },
            .commit_turn => {},
            .commit_withdraw => |id| {
                try self.commitWithdraw(id);
            },
            .commit_add => |data| {
                try self.commitAdd(data.card_id, data.target);
            },
            .commit_stack => |data| {
                try self.commitStack(data.card_id, data.target_play_index);
            },
            .move_play => |data| {
                // Convert command ChannelSet to domain ChannelSet
                const domain_channel: ?cards.ChannelSet = if (data.new_channel) |nc|
                    .{ .weapon = nc.weapon, .off_hand = nc.off_hand, .footwork = nc.footwork, .concentration = nc.concentration }
                else
                    null;
                try self.movePlay(data.card_id, data.new_time_start, domain_channel);
            },
            .commit_done => {
                try self.world.transitionTurnTo(.tick_resolution);
            },
            .collect_loot => {
                try self.world.transitionTo(.world_map);
            },
            else => {
                std.debug.print("UNHANDLED COMMAND: -- {any}", .{cmd});
            },
        }
    }

    /// Confirm player's stance selection and transition to draw phase.
    pub fn confirmStance(self: *CommandHandler, stance: lib.commands.Stance) !void {
        if (!self.world.inTurnPhase(.stance_selection)) {
            return CommandError.InvalidGameState;
        }
        const enc = self.world.encounter orelse return CommandError.BadInvariant;
        const enc_state = enc.stateFor(self.world.player.id) orelse return CommandError.BadInvariant;

        // Store stance in player's turn state
        enc_state.current.stance = .{
            .attack = stance.attack,
            .defense = stance.defense,
            .movement = stance.movement,
        };

        // Transition to draw phase
        try self.world.transitionTurnTo(.draw_hand);
    }

    pub fn cancelActionCard(self: *CommandHandler, id: entity.ID) !void {
        const player = self.world.player;
        if (!self.world.inTurnPhase(.player_card_selection)) {
            return CommandError.InvalidGameState;
        }
        const cs = player.combat_state orelse return CommandError.BadInvariant;
        const enc = self.world.encounter orelse return CommandError.BadInvariant;
        const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;

        // Find the play for this card
        const play_index = enc_state.current.findPlayByCard(id) orelse
            return CommandError.CardNotInPlay;
        const play = enc_state.current.slots()[play_index].play;

        const card = self.world.action_registry.get(id) orelse return CommandError.BadInvariant;

        // Check play.source to determine lifecycle handling
        if (play.source) |source| {
            // Pool card clone - destroy it and clear cooldown
            self.world.action_registry.destroy(id);
            // Refund cooldown on cancel
            _ = cs.cooldowns.remove(source.master_id);
            // Event uses master_id since clone is destroyed
            try self.sink(Event{
                .card_cancelled = .{ .instance = source.master_id, .actor = .{ .id = player.id, .player = true } },
            });
        } else {
            // Hand card - move back to hand (adds to hand, timeline tracks removal)
            try cs.moveCard(id, .in_play, .hand);
            try self.sink(Event{
                .card_moved = .{ .instance = card.id, .from = .in_play, .to = .hand, .actor = .{ .id = player.id, .player = true } },
            });
        }

        // Remove the play from timeline
        enc_state.current.removePlay(play_index);

        player.stamina.uncommit(card.template.cost.stamina);
        player.time_available += card.template.cost.time;

        try self.sink(
            Event{ .card_cost_returned = .{ .stamina = card.template.cost.stamina, .time = card.template.cost.time, .actor = .{ .id = player.id, .player = true } } },
        );
    }

    /// Handles playing a card EITHER from hand, or from player.always_known
    pub fn playActionCard(self: *CommandHandler, id: entity.ID, target: ?entity.ID) !void {
        const player = self.world.player;
        const turn_phase = self.world.turnPhase() orelse return CommandError.InvalidGameState;
        const cs = player.combat_state orelse return CommandError.BadInvariant;
        const enc = self.world.encounter orelse return CommandError.BadInvariant;
        const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;

        // Look up card instance
        const card = self.world.action_registry.get(id) orelse return CommandError.BadInvariant;

        // Check card is in hand or available
        if (!cs.isInZone(id, .hand) and !player.poolContains(id))
            return CommandError.CardNotInHand;

        if (turn_phase != .player_card_selection)
            return CommandError.InvalidGameState;

        if (try validation.validateCardSelection(player, card, turn_phase, self.world.encounter)) {
            const play_result = try playValidCardReservingCosts(&self.world.events, player, card, &self.world.action_registry, target);

            try enc_state.current.addPlay(.{
                .action = play_result.in_play_id,
                .target = target,
                .source = play_result.source,
                .added_in_phase = .selection,
            }, &self.world.action_registry);

            // Auto-set primary target for player when playing a targeted card
            // (asymmetric mechanic - enemies don't use attention system)
            if (target) |t| {
                enc_state.attention.primary = t;
            }
        } else {
            return CommandError.CommandInvalid;
        }
    }

    const FOCUS_COST: f32 = 1.0;

    /// Commit phase: Withdraw a card from play (costs 1 Focus).
    /// Returns card to hand, uncommits stamina, removes from plays.
    /// Fails if the play has modifiers attached.
    pub fn commitWithdraw(self: *CommandHandler, card_id: entity.ID) !void {
        const player = self.world.player;
        if (!self.world.inTurnPhase(.commit_phase))
            return CommandError.InvalidGameState;

        const enc = self.world.encounter orelse return CommandError.BadInvariant;
        const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;
        const cs = player.combat_state orelse return CommandError.BadInvariant;

        // Validate: find the play
        const play_index = enc_state.current.findPlayByCard(card_id) orelse
            return CommandError.CardNotInPlay;

        // Validate: play can be withdrawn (no modifiers, not involuntary)
        const play = &enc_state.current.slots()[play_index].play;
        if (!validation.canWithdrawPlay(play, &self.world.action_registry))
            return CommandError.CommandInvalid;

        // Validate: sufficient focus
        if (player.focus.available < FOCUS_COST)
            return CommandError.InsufficientFocus;

        // All validation passed - apply changes
        _ = player.focus.spend(FOCUS_COST);

        const card = self.world.action_registry.get(card_id) orelse return CommandError.BadInvariant;
        player.stamina.uncommit(card.template.cost.stamina);
        player.time_available += card.template.cost.time;

        cs.moveCard(card_id, .in_play, .hand) catch return CommandError.CardNotInPlay;
        try self.sink(Event{
            .card_moved = .{ .instance = card.id, .from = .in_play, .to = .hand, .actor = .{ .id = player.id, .player = true } },
        });

        enc_state.current.removePlay(play_index);
        enc_state.current.focus_spent += FOCUS_COST;
    }

    /// Commit phase: Add a new card from hand (costs 1 Focus).
    /// Card is marked as added in commit phase (cannot be stacked).
    pub fn commitAdd(self: *CommandHandler, card_id: entity.ID, target: ?entity.ID) !void {
        const player = self.world.player;
        if (!self.world.inTurnPhase(.commit_phase))
            return CommandError.InvalidGameState;

        const cs = player.combat_state orelse return CommandError.BadInvariant;
        const enc = self.world.encounter orelse return CommandError.BadInvariant;
        const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;

        // Validate: card is in hand or available
        if (!cs.isInZone(card_id, .hand) and !player.poolContains(card_id))
            return CommandError.CardNotInHand;

        // Validate: card exists
        const card = self.world.action_registry.get(card_id) orelse
            return CommandError.BadInvariant;

        // Validate: card selection rules (phase, costs, predicates)
        if (!try validation.validateCardSelection(player, card, .commit_phase, self.world.encounter))
            return CommandError.PredicateFailed;

        // Validate: sufficient focus
        if (player.focus.available < FOCUS_COST)
            return CommandError.InsufficientFocus;

        // All validation passed - apply changes
        _ = player.focus.spend(FOCUS_COST);

        // Play card (move to in_play, commit stamina)
        const play_result = try playValidCardReservingCosts(&self.world.events, player, card, &self.world.action_registry, target);

        // Add to plays (commit phase plays cannot be stacked)
        try enc_state.current.addPlay(.{
            .action = play_result.in_play_id,
            .target = target,
            .added_in_phase = .commit,
            .source = play_result.source,
        }, &self.world.action_registry);

        // Auto-set primary target for player when playing a targeted card
        // (asymmetric mechanic - enemies don't use attention system)
        if (target) |t| {
            enc_state.attention.primary = t;
        }

        enc_state.current.focus_spent += FOCUS_COST;
    }

    /// Stack a card onto an existing play (same-template reinforcement or modifier attachment).
    /// Focus cost: base 1 (first stack only) + card's own focus cost.
    /// Accepts cards from hand or always_available zones.
    pub fn commitStack(self: *CommandHandler, card_id: entity.ID, target_play_index: usize) !void {
        const player = self.world.player;
        const enc = self.world.encounter orelse return CommandError.BadInvariant;
        const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;

        // Validate and compute costs
        const stack_result = try self.validateStack(card_id, target_play_index);

        // Calculate total focus cost
        const base_focus: f32 = if (enc_state.current.stack_focus_paid) 0 else FOCUS_COST;
        const total_focus = base_focus + stack_result.card_focus_cost;

        // Spend focus
        if (total_focus > 0) {
            if (!player.focus.spend(total_focus))
                return CommandError.InsufficientFocus;
        }

        // Apply the stack (all validation passed, focus spent)
        self.applyStack(stack_result, target_play_index, enc_state, player, base_focus > 0, total_focus) catch |err| {
            // Refund focus on unexpected error
            if (total_focus > 0) {
                player.focus.current += total_focus;
                player.focus.available += total_focus;
            }
            return err;
        };
    }

    /// Validated stack operation ready to apply.
    const StackValidation = struct {
        stack_card: *Instance,
        card_focus_cost: f32,
    };

    /// Validate a stack operation without spending resources.
    fn validateStack(self: *CommandHandler, card_id: entity.ID, target_play_index: usize) !StackValidation {
        const player = self.world.player;
        if (!self.world.inTurnPhase(.commit_phase))
            return CommandError.InvalidGameState;

        const enc = self.world.encounter orelse return CommandError.BadInvariant;
        const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;
        const cs = player.combat_state orelse return CommandError.BadInvariant;

        // Validate target play exists
        if (target_play_index >= enc_state.current.slots().len)
            return CommandError.CommandInvalid;

        const target_play = &enc_state.current.slots()[target_play_index].play;

        // Cannot stack on plays added this commit phase
        if (!target_play.canStack())
            return CommandError.CommandInvalid;

        // Check card is available (hand or always_available)
        const in_hand = cs.isInZone(card_id, .hand);
        const in_always_available = player.poolContains(card_id);
        if (!in_hand and !in_always_available)
            return CommandError.CardNotInHand;

        // Check cooldown for always_available cards
        if (in_always_available and !player.isPoolCardAvailable(card_id))
            return CommandError.CardOnCooldown;

        // Look up stack card
        const stack_card = self.world.action_registry.get(card_id) orelse
            return CommandError.BadInvariant;

        // Look up action card
        const action_card = self.world.action_registry.getConst(target_play.action) orelse
            return CommandError.BadInvariant;

        // Validate compatibility
        const same_template = stack_card.template.id == action_card.template.id;
        const is_modifier = stack_card.template.tags.modifier;

        if (same_template) {
            // Same template stacking - always OK
        } else if (is_modifier) {
            // Modifier attachment - check predicate and conflicts
            if (!try targeting.canModifierAttachToPlay(stack_card.template, target_play, self.world))
                return CommandError.PredicateFailed;

            if (target_play.wouldConflict(stack_card.template, &self.world.action_registry))
                return CommandError.ModifierConflict;
        } else {
            // Different template, not a modifier - invalid
            return CommandError.TemplatesMismatch;
        }

        // Check modifier stack not full
        if (target_play.modifier_stack_len >= combat.Play.max_modifiers)
            return CommandError.CommandInvalid;

        return .{
            .stack_card = stack_card,
            .card_focus_cost = stack_card.template.cost.focus,
        };
    }

    /// Apply a validated stack operation (assumes validation passed and focus spent).
    fn applyStack(
        self: *CommandHandler,
        stack_validation: StackValidation,
        target_play_index: usize,
        enc_state: *combat.AgentEncounterState,
        player: *Agent,
        paid_base_focus: bool,
        total_focus: f32,
    ) !void {
        const target_play = &enc_state.current.slotsMut()[target_play_index].play;

        // Move card to in_play first - this creates a clone for pool cards
        // Returns the ID that ends up in play and source info
        // Modifiers don't target enemies
        const play_result = try playValidCardReservingCosts(&self.world.events, player, stack_validation.stack_card, &self.world.action_registry, null);

        // Add the in_play ID (clone if pool card) to modifier stack with source
        try target_play.addModifier(play_result.in_play_id, play_result.source);

        // Update focus tracking
        if (paid_base_focus) {
            enc_state.current.stack_focus_paid = true;
        }
        if (total_focus > 0) {
            enc_state.current.focus_spent += total_focus;
        }
    }

    /// Move a play to a new time position and/or channel.
    /// Valid during selection and commit phases.
    /// Channel switch only allowed between weapon-type channels (weapon ↔ off_hand).
    pub fn movePlay(
        self: *CommandHandler,
        card_id: entity.ID,
        new_time_start: f32,
        new_channel: ?cards.ChannelSet,
    ) !void {
        const player = self.world.player;

        // Valid in selection or commit phase
        if (!self.world.inTurnPhase(.player_card_selection) and
            !self.world.inTurnPhase(.commit_phase))
        {
            return CommandError.InvalidGameState;
        }

        const enc = self.world.encounter orelse return CommandError.BadInvariant;
        const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;

        // Find the play
        const play_index = enc_state.current.findPlayByCard(card_id) orelse
            return CommandError.CardNotInPlay;

        // Get the play data and current channels
        var play = enc_state.current.slots()[play_index].play;
        const current_channels = combat.getPlayChannels(play, &self.world.action_registry);

        // Validate and apply channel override
        const target_channels = if (new_channel) |nc| blk: {
            // Validate channel switch: only weapon ↔ off_hand allowed
            if (!isValidChannelSwitch(current_channels, nc)) {
                return CommandError.CommandInvalid;
            }
            play.channel_override = nc;
            break :blk nc;
        } else current_channels;

        // Get duration and original time BEFORE removing
        const duration = combat.getPlayDuration(play, &self.world.action_registry);
        const old_time_start = enc_state.current.slots()[play_index].time_start;

        // Remove from current position
        enc_state.current.removePlay(play_index);

        // Try to insert at new position
        enc_state.current.timeline.insert(
            new_time_start,
            new_time_start + duration,
            play,
            target_channels,
            &self.world.action_registry,
        ) catch |err| {
            // Restore play at original position on failure
            // Reset channel_override if we changed it
            if (new_channel != null) {
                play.channel_override = null;
            }
            enc_state.current.timeline.insert(
                old_time_start,
                old_time_start + duration,
                play,
                current_channels,
                &self.world.action_registry,
            ) catch {
                // This shouldn't fail since we just removed it from there
                return CommandError.BadInvariant;
            };
            return switch (err) {
                error.Conflict => CommandError.InsufficientTime,
                error.Overflow => CommandError.CommandInvalid,
            };
        };

        try self.sink(.{ .play_moved = .{
            .card_id = card_id,
            .new_time_start = new_time_start,
            .new_channel = new_channel,
        } });
    }
};

/// Validate channel switch: only weapon ↔ off_hand allowed.
/// Returns true if the switch is valid.
fn isValidChannelSwitch(from: cards.ChannelSet, to: cards.ChannelSet) bool {
    // Both must be weapon-type channels (weapon or off_hand only)
    const from_is_weapon_type = (from.weapon or from.off_hand) and
        !from.footwork and !from.concentration;
    const to_is_weapon_type = (to.weapon or to.off_hand) and
        !to.footwork and !to.concentration;

    return from_is_weapon_type and to_is_weapon_type;
}

// ============================================================================
// Tests
// ============================================================================

test "isValidChannelSwitch allows weapon to off_hand" {
    const from = cards.ChannelSet{ .weapon = true };
    const to = cards.ChannelSet{ .off_hand = true };
    try std.testing.expect(isValidChannelSwitch(from, to));
}

test "isValidChannelSwitch allows off_hand to weapon" {
    const from = cards.ChannelSet{ .off_hand = true };
    const to = cards.ChannelSet{ .weapon = true };
    try std.testing.expect(isValidChannelSwitch(from, to));
}

test "isValidChannelSwitch rejects footwork to weapon" {
    const from = cards.ChannelSet{ .footwork = true };
    const to = cards.ChannelSet{ .weapon = true };
    try std.testing.expect(!isValidChannelSwitch(from, to));
}

test "isValidChannelSwitch rejects weapon to footwork" {
    const from = cards.ChannelSet{ .weapon = true };
    const to = cards.ChannelSet{ .footwork = true };
    try std.testing.expect(!isValidChannelSwitch(from, to));
}

test "isValidChannelSwitch rejects concentration to off_hand" {
    const from = cards.ChannelSet{ .concentration = true };
    const to = cards.ChannelSet{ .off_hand = true };
    try std.testing.expect(!isValidChannelSwitch(from, to));
}

test "isValidChannelSwitch rejects mixed channels" {
    // If source has multiple channel types including non-weapon, reject
    const from = cards.ChannelSet{ .weapon = true, .footwork = true };
    const to = cards.ChannelSet{ .off_hand = true };
    try std.testing.expect(!isValidChannelSwitch(from, to));
}
