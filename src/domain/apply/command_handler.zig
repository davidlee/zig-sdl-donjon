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

fn wouldConflictWithInPlay(
    new_card: *const Instance,
    cs: *const combat.CombatState,
    registry: *const w.CardRegistry,
) bool {
    const new_channels = getCardChannels(new_card.template);
    if (new_channels.isEmpty()) return false;

    for (cs.in_play.items) |in_play_id| {
        const in_play_card = registry.getConst(in_play_id) orelse continue;
        const existing_channels = getCardChannels(in_play_card.template);
        if (new_channels.conflicts(existing_channels)) return true;
    }
    return false;
}

fn getCardChannels(template: *const cards.Template) cards.ChannelSet {
    if (template.getTechnique()) |technique| {
        return technique.channels;
    }
    return .{};
}

/// Move a card to in_play, reserving its costs.
/// For pool cards (always_available, spells_known), creates a clone.
/// Returns the ID of the card in in_play (clone for pool cards, original otherwise).
pub fn playValidCardReservingCosts(
    evs: *EventSystem,
    actor: *Agent,
    card: *Instance,
    registry: *w.CardRegistry,
    target: ?entity.ID,
) !entity.ID {
    const cs = actor.combat_state orelse return error.InvalidGameState;
    const is_player = switch (actor.director) {
        .player => true,
        else => false,
    };

    const actor_meta: events.AgentMeta = .{ .id = actor.id, .player = is_player };

    // Track the ID that ends up in in_play (may be clone for pool cards)
    var in_play_id: entity.ID = card.id;

    if (actor.inAlwaysAvailable(card.id)) {
        in_play_id = try cs.addToInPlayFrom(card.id, .always_available, registry);
        try evs.push(Event{
            .card_cloned = .{ .clone_id = in_play_id, .master_id = card.id, .actor = actor_meta },
        });
        // Set cooldown immediately if template has one
        if (card.template.cooldown) |cd| {
            try cs.setCooldown(card.id, cd);
        }
    } else if (actor.inSpellsKnown(card.id)) {
        in_play_id = try cs.addToInPlayFrom(card.id, .spells_known, registry);
        try evs.push(Event{
            .card_cloned = .{ .clone_id = in_play_id, .master_id = card.id, .actor = actor_meta },
        });
        if (card.template.cooldown) |cd| {
            try cs.setCooldown(card.id, cd);
        }
    } else {
        try cs.moveCard(card.id, .hand, .in_play);
        try evs.push(Event{
            .card_moved = .{ .instance = card.id, .from = .hand, .to = .in_play, .actor = actor_meta },
        });
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

    return in_play_id;
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
                // Encounter starts in draw_hand phase (initial FSM state)
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

    pub fn cancelActionCard(self: *CommandHandler, id: entity.ID) !void {
        const player = self.world.player;
        if (!self.world.inTurnPhase(.player_card_selection)) {
            return CommandError.InvalidGameState;
        }
        const cs = player.combat_state orelse return CommandError.BadInvariant;

        if (!cs.isInZone(id, .in_play)) {
            return CommandError.CardNotInPlay;
        }

        const card = self.world.card_registry.get(id) orelse return CommandError.BadInvariant;

        // Check if this is a pool card clone (has master_id in in_play_sources)
        const info = cs.in_play_sources.get(id);
        if (info) |i| {
            if (i.master_id) |master_id| {
                // Pool card clone - destroy it and clear cooldown
                _ = try cs.removeFromInPlay(id, &self.world.card_registry);
                // Refund cooldown on cancel
                _ = cs.cooldowns.remove(master_id);
                // Event uses master_id since clone is destroyed
                try self.sink(Event{
                    .card_cancelled = .{ .instance = master_id, .actor = .{ .id = player.id, .player = true } },
                });
            } else {
                // Non-pool card - move back to hand
                cs.moveCard(id, .in_play, .hand) catch return CommandError.CardNotInPlay;
                try self.sink(Event{
                    .card_moved = .{ .instance = card.id, .from = .in_play, .to = .hand, .actor = .{ .id = player.id, .player = true } },
                });
            }
        } else {
            // No source info (shouldn't happen) - try move to hand
            cs.moveCard(id, .in_play, .hand) catch return CommandError.CardNotInPlay;
            try self.sink(Event{
                .card_moved = .{ .instance = card.id, .from = .in_play, .to = .hand, .actor = .{ .id = player.id, .player = true } },
            });
        }

        player.stamina.uncommit(card.template.cost.stamina);
        player.time_available += card.template.cost.time;

        // Clear any pending target for this card
        if (self.world.encounter) |enc| {
            if (enc.stateFor(player.id)) |enc_state| {
                enc_state.current.clearPendingTarget(id);
            }
        }

        try self.sink(
            Event{ .card_cost_returned = .{ .stamina = card.template.cost.stamina, .time = card.template.cost.time, .actor = .{ .id = player.id, .player = true } } },
        );
    }

    /// Handles playing a card EITHER from hand, or from player.always_known
    pub fn playActionCard(self: *CommandHandler, id: entity.ID, target: ?entity.ID) !void {
        const player = self.world.player;
        const turn_phase = self.world.turnPhase() orelse return CommandError.InvalidGameState;
        const cs = player.combat_state orelse return CommandError.BadInvariant;

        // Look up card instance
        const card = self.world.card_registry.get(id) orelse return CommandError.BadInvariant;

        // Check card is in hand or available
        if (!cs.isInZone(id, .hand) and !player.poolContains(id))
            return CommandError.CardNotInHand;

        if (turn_phase != .player_card_selection)
            return CommandError.InvalidGameState;

        if (try validation.validateCardSelection(player, card, turn_phase, self.world.encounter)) {
            // Check channel conflicts with existing plays
            if (wouldConflictWithInPlay(card, cs, &self.world.card_registry))
                return validation.ValidationError.ChannelConflict;

            const in_play_id = try playValidCardReservingCosts(&self.world.events, player, card, &self.world.card_registry, target);

            // Store pending target if provided (for .single targeting cards)
            if (target) |target_id| {
                const enc = self.world.encounter orelse return CommandError.BadInvariant;
                const enc_state = enc.stateFor(player.id) orelse return CommandError.BadInvariant;
                enc_state.current.setPendingTarget(in_play_id, target_id);
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

        // Validate: play has no modifiers
        const play = &enc_state.current.slots()[play_index].play;
        if (!validation.canWithdrawPlay(play))
            return CommandError.CommandInvalid;

        // Validate: sufficient focus
        if (player.focus.available < FOCUS_COST)
            return CommandError.InsufficientFocus;

        // All validation passed - apply changes
        _ = player.focus.spend(FOCUS_COST);

        const card = self.world.card_registry.get(card_id) orelse return CommandError.BadInvariant;
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
    /// Card is marked as added_in_commit (cannot be stacked).
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
        const card = self.world.card_registry.get(card_id) orelse
            return CommandError.BadInvariant;

        // Validate: card selection rules (phase, costs, predicates)
        if (!try validation.validateCardSelection(player, card, .commit_phase, self.world.encounter))
            return CommandError.PredicateFailed;

        // Validate: channel conflicts with existing plays
        const new_channels = getCardChannels(card.template);
        if (enc_state.current.wouldConflictOnChannel(new_channels, &self.world.card_registry))
            return validation.ValidationError.ChannelConflict;

        // Validate: sufficient focus
        if (player.focus.available < FOCUS_COST)
            return CommandError.InsufficientFocus;

        // All validation passed - apply changes
        _ = player.focus.spend(FOCUS_COST);

        // Play card (move to in_play, commit stamina)
        const in_play_id = try playValidCardReservingCosts(&self.world.events, player, card, &self.world.card_registry, target);

        // Store pending target if provided (for .single targeting cards)
        if (target) |target_id| {
            enc_state.current.setPendingTarget(in_play_id, target_id);
        }

        // Add to plays with added_in_commit flag
        try enc_state.current.addPlay(.{
            .action = in_play_id,
            .added_in_commit = true, // Cannot be stacked this turn
        }, &self.world.card_registry);

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
        const stack_card = self.world.card_registry.get(card_id) orelse
            return CommandError.BadInvariant;

        // Look up action card
        const action_card = self.world.card_registry.getConst(target_play.action) orelse
            return CommandError.BadInvariant;

        // Validate compatibility
        const same_template = stack_card.template.id == action_card.template.id;
        const is_modifier = stack_card.template.kind == .modifier;

        if (same_template) {
            // Same template stacking - always OK
        } else if (is_modifier) {
            // Modifier attachment - check predicate and conflicts
            if (!try targeting.canModifierAttachToPlay(stack_card.template, target_play, self.world))
                return CommandError.PredicateFailed;

            if (target_play.wouldConflict(stack_card.template, &self.world.card_registry))
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
        // Returns the ID that ends up in in_play (clone for pool cards, original for hand)
        // Modifiers don't target enemies
        const in_play_id = try playValidCardReservingCosts(&self.world.events, player, stack_validation.stack_card, &self.world.card_registry, null);

        // Add the in_play ID (clone if pool card) to modifier stack
        try target_play.addModifier(in_play_id);

        // Update focus tracking
        if (paid_base_focus) {
            enc_state.current.stack_focus_paid = true;
        }
        if (total_focus > 0) {
            enc_state.current.focus_spent += total_focus;
        }
    }
};
