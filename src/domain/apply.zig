const std = @import("std");
const lib = @import("infra");

const damage = @import("damage.zig");
const stats = @import("stats.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const combat = @import("combat.zig");
const events = @import("events.zig");
const w = @import("world.zig");
const random = @import("random.zig");
const entity = lib.entity;
const tick = @import("tick.zig");

const Event = events.Event;
const EventSystem = events.EventSystem;
const EventTag = std.meta.Tag(Event);
const World = w.World;
const Agent = combat.Agent;
const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Expression = cards.Expression;
const Technique = cards.Technique;
const Instance = cards.Instance;

const log = std.debug.print;

// Re-export from apply/ submodules - see doc/decomposition.md for refactor notes
const apply_mod = @import("apply/mod.zig");
pub const validation = apply_mod.validation;
pub const targeting = apply_mod.targeting;

// Re-export commonly used types for backward compatibility
pub const ValidationError = apply_mod.ValidationError;
pub const PredicateContext = apply_mod.PredicateContext;
pub const PlayTarget = apply_mod.PlayTarget;

// Re-export commonly used functions
pub const canPlayerPlayCard = apply_mod.canPlayerPlayCard;
pub const isCardSelectionValid = apply_mod.isCardSelectionValid;
pub const validateCardSelection = apply_mod.validateCardSelection;
pub const rulePredicatesSatisfied = apply_mod.rulePredicatesSatisfied;
pub const canWithdrawPlay = apply_mod.canWithdrawPlay;
pub const evaluatePredicate = apply_mod.evaluatePredicate;
pub const compareReach = apply_mod.compareReach;
pub const compareF32 = apply_mod.compareF32;
pub const expressionAppliesToTarget = apply_mod.expressionAppliesToTarget;
pub const cardHasValidTargets = apply_mod.cardHasValidTargets;
pub const evaluateTargets = apply_mod.evaluateTargets;
pub const evaluatePlayTargets = apply_mod.evaluatePlayTargets;
pub const resolvePlayTargetIDs = apply_mod.resolvePlayTargetIDs;
pub const getModifierTargetPredicate = apply_mod.getModifierTargetPredicate;
pub const canModifierAttachToPlay = apply_mod.canModifierAttachToPlay;

// Internal helpers used by CommandHandler (not part of public validation API)
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

pub const EventSystemError = error{
    InvalidGameState,
};

const EffectContext = struct {
    card: *const Instance,
    effect: *const Effect,
    target: *std.ArrayList(*Agent), // TODO: will need to be polymorphic (player, body part)
    actor: *Agent,
    technique: ?TechniqueContext = null,

    fn applyModifiers(self: *EffectContext, alloc: std.mem.Allocator) void {
        if (self.technique) |tc| {
            var instances = try std.ArrayList(damage.Instances).initCapacity(alloc, tc.base_damage.instances.len);
            defer instances.deinit(alloc);

            // const t = tc.technique;
            // const bd = tc.base_damage;
            const eff = blk: switch (tc.base_damage.scaling.stats) {
                .stat => |accessor| self.actor.stats.getConst(accessor),
                .average => |arr| {
                    const a = self.actor.stats.getConst(arr[0]);
                    const b = self.actor.stats.getConst(arr[1]);
                    break :blk (a + b) / 2.0;
                },
            } * tc.base_damage.scaling.ratio;
            for (tc.base_damage.instances) |inst| {
                const adjusted = damage.Instance{
                    .amount = eff * inst.amount,
                    .types = inst.types, // same slice
                };
                try instances.append(alloc, adjusted);
            }
            tc.calc_damage = try instances.toOwnedSlice(alloc);
        }
    }
};

const TechniqueContext = struct {
    technique: *const Technique,
    base_damage: *const damage.Base,
    calc_damage: ?[]damage.Instance = null,
    calc_difficulty: ?f32 = null,
};

//
// HANDLER
//
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

        if (try validateCardSelection(player, card, turn_phase, self.world.encounter)) {
            // Check channel conflicts with existing plays
            if (wouldConflictWithInPlay(card, cs, &self.world.card_registry))
                return ValidationError.ChannelConflict;

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
        if (!canWithdrawPlay(play))
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
        if (!try validateCardSelection(player, card, .commit_phase, self.world.encounter))
            return CommandError.PredicateFailed;

        // Validate: channel conflicts with existing plays
        const new_channels = getCardChannels(card.template);
        if (enc_state.current.wouldConflictOnChannel(new_channels, &self.world.card_registry))
            return ValidationError.ChannelConflict;

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
            if (!try canModifierAttachToPlay(stack_card.template, target_play, self.world))
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

//
// EventProcessor - responds to events
//
pub const EventProcessor = struct {
    world: *World,
    pub fn init(world: *World) EventProcessor {
        return EventProcessor{
            .world = world,
        };
    }

    /// Initialize combat state for all agents (called once at combat start)
    fn initAllCombatStates(self: *EventProcessor) !void {
        try self.world.player.initCombatState();
        if (self.world.encounter) |enc| {
            for (enc.enemies.items) |mob| {
                try mob.initCombatState();
            }
        }
    }

    /// End-of-turn cleanup: discard hand, refresh resources, clear turn state.
    /// Called when transitioning to draw_hand (start of new turn).
    fn endTurnCleanup(self: *EventProcessor) !void {
        const enc = self.world.encounter orelse return;

        // Cleanup for player
        try self.agentEndTurnCleanup(self.world.player, enc);

        // Cleanup for enemies
        for (enc.enemies.items) |mob| {
            try self.agentEndTurnCleanup(mob, enc);
        }
    }

    fn agentEndTurnCleanup(self: *EventProcessor, agent: *Agent, enc: *combat.Encounter) !void {
        if (agent.combat_state) |cs| {
            // Discard remaining hand cards
            while (cs.hand.items.len > 0) {
                const card_id = cs.hand.items[0];
                try cs.moveCard(card_id, .hand, .discard);
            }

            // Clean up remaining in_play cards (e.g. orphaned modifiers)
            // Uses removeFromInPlay which destroys pool card clones, discards hand cards
            while (cs.in_play.items.len > 0) {
                const card_id = cs.in_play.items[0];
                const master_id = try cs.removeFromInPlay(card_id, &self.world.card_registry);
                // For hand-sourced cards, move to discard
                if (master_id == null) {
                    try cs.discard.append(cs.alloc, card_id);
                }
            }
        }

        // Refresh resources
        agent.stamina.tick();
        agent.focus.tick();
        agent.time_available = 1.0;

        // Clear turn state (push to history)
        if (enc.stateFor(agent.id)) |enc_state| {
            enc_state.endTurn();
        }
    }

    // TODO: fix hardcoded hand limit
    fn allShuffleAndDraw(self: *EventProcessor, count: usize) !void {
        std.debug.print("draw hand: enemies \n", .{});
        if (self.world.encounter) |enc| for (enc.enemies.items) |mob| try self.shuffleAndDraw(mob, count);
        std.debug.print("draw hand: player \n", .{});
        try self.shuffleAndDraw(self.world.player, count);
    }

    /// Shuffle draw pile and draw cards to hands - uses CombatState
    fn shuffleAndDraw(self: *EventProcessor, agent: *Agent, count: usize) !void {
        // Only shuffled_deck draws cards; other styles have always-available techniques
        if (agent.draw_style != .shuffled_deck) return;

        const cs = agent.combat_state orelse return; // No combat state = can't draw

        for (0..count) |_| {
            if (cs.draw.items.len == 0) { // need to shuffle the discard pile
                // Move all cards from discard to draw
                while (cs.discard.items.len > 0) {
                    const id = cs.discard.items[0];
                    try cs.moveCard(id, .discard, .draw);
                }
                var rand = self.world.getRandomSource(.shuffler);
                try cs.shuffleDraw(&rand);
            }
            if (cs.draw.items.len == 0) break; // No cards left
            const card_id = cs.draw.items[0];
            try cs.moveCard(card_id, .draw, .hand);
        }
    }

    fn sink(self: *EventProcessor, event: Event) !void {
        try self.world.events.push(event);
    }

    /// Build Play structs from cards currently in in_play zone.
    /// Called when entering commit_phase to bridge selection and resolution.
    fn buildPlaysFromInPlayCards(self: *EventProcessor) !void {
        const enc = self.world.encounter orelse return;

        // Player
        try self.buildPlaysForAgent(self.world.player, enc);

        // Mobs
        for (enc.enemies.items) |mob| {
            try self.buildPlaysForAgent(mob, enc);
        }
    }

    fn buildPlaysForAgent(self: *EventProcessor, agent: *Agent, enc: *combat.Encounter) !void {
        const enc_state = enc.stateFor(agent.id) orelse return;

        // Read pending targets before clearing (they're stored per-card)
        const cs = agent.combat_state orelse return;
        for (cs.in_play.items) |card_id| {
            const pending_target = enc_state.current.getPendingTarget(card_id);
            try enc_state.current.addPlay(.{
                .action = card_id,
                .target = pending_target,
            }, &self.world.card_registry);
        }
    }

    /// Check if combat should end. Returns outcome if terminated, null if combat continues.
    fn checkCombatTermination(self: *EventProcessor) !?combat.CombatOutcome {
        const player = self.world.player;
        const enc = self.world.encounter orelse return null;

        // Player incapacitated = defeat
        if (player.isIncapacitated()) {
            return .defeat;
        }

        // All enemies incapacitated = victory
        var all_enemies_down = true;
        for (enc.enemies.items) |enemy| {
            if (!enemy.isIncapacitated()) {
                all_enemies_down = false;
                break;
            }
        }
        if (all_enemies_down) {
            return .victory;
        }

        return null; // Combat continues
    }

    /// Clean up encounter after loot collected. Called when entering world_map state.
    fn cleanupEncounter(self: *EventProcessor) !void {
        // Clean up combat state for player
        self.world.player.cleanupCombatState();

        // Clean up and destroy encounter
        if (self.world.encounter) |enc| {
            // Combat state for enemies cleaned up in Agent.deinit via Encounter.deinit
            enc.deinit(self.world.entities.agents);
            self.world.encounter = null;
        }
    }

    pub fn dispatchEvent(self: *EventProcessor, event_system: *EventSystem) !bool {
        const result = event_system.pop();
        if (result) |event| {
            std.debug.print("             -> dispatchEvent: {}\n", .{event});
            switch (event) {
                // High-level game state transitions
                .game_state_transitioned_to => |state| {
                    std.debug.print("\nGAME STATE ==> {}\n\n", .{state});

                    switch (state) {
                        .in_encounter => {
                            // Encounter starting - begin draw phase
                            // (Encounter FSM starts in draw_hand state)
                            std.debug.print("Starting encounter - triggering draw_hand\n", .{});
                            // End-of-turn cleanup (no-op on first turn when combat_state is null)
                            try self.endTurnCleanup();
                            // Initialize combat_state for all agents if not already done
                            try self.initAllCombatStates();
                            try self.allShuffleAndDraw(5);
                            try self.world.transitionTurnTo(.player_card_selection);
                        },
                        .encounter_summary => {
                            // Post-combat - nothing to do here, handled by summary view
                        },
                        .world_map => {
                            // Cleanup encounter after loot collected
                            try self.cleanupEncounter();
                        },
                        .splash => {
                            // Back to title screen (e.g., after defeat)
                        },
                    }
                },

                // Turn phase transitions (within an encounter)
                .turn_phase_transitioned_to => |phase| {
                    std.debug.print("\nTURN PHASE ==> {}\n\n", .{phase});

                    switch (phase) {
                        .player_card_selection => {
                            // AI plays cards when player enters selection phase
                            for (self.world.encounter.?.enemies.items) |agent| {
                                switch (agent.director) {
                                    .ai => |*director| {
                                        try director.playCards(agent, self.world);
                                    },
                                    else => unreachable,
                                }
                            }
                        },
                        .draw_hand => {
                            // Draw phase entered (after animating)
                            std.debug.print("draw hand\n", .{});
                            try self.endTurnCleanup();
                            try self.initAllCombatStates();
                            try self.allShuffleAndDraw(5);
                            try self.world.transitionTurnTo(.player_card_selection);
                        },
                        .commit_phase => {
                            try self.buildPlaysFromInPlayCards();
                            // Execute on_commit rules for player
                            try executeCommitPhaseRules(self.world, self.world.player);
                            // Execute on_commit rules for mobs
                            if (self.world.encounter) |enc| {
                                for (enc.enemies.items) |mob| {
                                    try executeCommitPhaseRules(self.world, mob);
                                }
                            }
                            // Player must explicitly call commit_done to transition
                        },
                        .tick_resolution => {
                            const res = try self.world.processTick();
                            std.debug.print("Tick Resolution: {any}\n", .{res});
                            try self.world.transitionTurnTo(.animating);
                        },
                        .animating => {
                            if (try self.checkCombatTermination()) |outcome| {
                                // Combat ended - set outcome and transition appropriately
                                self.world.encounter.?.outcome = outcome;
                                try self.world.events.push(.{ .combat_ended = outcome });
                                switch (outcome) {
                                    .victory => try self.world.transitionTo(.encounter_summary),
                                    .defeat => try self.world.transitionTo(.splash),
                                    .flee, .surrender => try self.world.transitionTo(.encounter_summary),
                                }
                            } else {
                                // Combat continues - next turn
                                try self.world.transitionTurnTo(.draw_hand);
                            }
                        },
                        .player_reaction => {
                            // Future: reaction windows
                        },
                    }

                    // Debug: log cards in play for mobs
                    if (self.world.encounter) |enc| {
                        for (enc.enemies.items) |mob| {
                            if (mob.combat_state) |cs| {
                                for (cs.in_play.items) |card_id| {
                                    if (self.world.card_registry.get(card_id)) |instance| {
                                        log("cards in play (mob): {s}\n", .{instance.template.name});
                                    }
                                }
                            }
                        }
                    }
                },
                .draw_random => {},
                else => |data| std.debug.print("event processed: {}\n", .{data}),
            }
            return true;
        } else return false;
    }
};

// ============================================================================
// High level interfaces - play cards (validation moved to apply/validation.zig)
// ============================================================================

/// Doesn't perform validation. Just moves card, reserves costs, emits events.
/// For pool cards (always_available, spells_known), creates ephemeral clone and sets cooldown.
/// Returns the ID that ends up in in_play (clone ID for pool cards, original for hand cards).
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

// ============================================================================
// Commit Phase Effect Execution
// ============================================================================

/// Apply a commit phase effect to a play target
pub fn applyCommitPhaseEffect(
    effect: cards.Effect,
    play_target: PlayTarget,
    world: *World,
) void {
    const enc = world.encounter orelse return;
    const enc_state = enc.stateFor(play_target.agent.id) orelse return;

    switch (effect) {
        .modify_play => |mod| {
            if (play_target.play_index >= enc_state.current.slots().len) return;
            var play = &enc_state.current.slotsMut()[play_target.play_index].play;
            if (mod.cost_mult) |m| play.cost_mult *= m;
            if (mod.damage_mult) |m| play.damage_mult *= m;
            if (mod.replace_advantage) |adv| play.advantage_override = adv;
        },
        .cancel_play => {
            enc_state.current.removePlay(play_target.play_index);
        },
        else => {}, // Other effects not handled here
    }
}

/// Execute all on_commit rules for cards already in play.
/// Note: This is for cards with rules that TRIGGER during commit phase
/// (e.g., "when you commit, if you have an offensive play, gain control").
/// This is NOT for cards that are PLAYABLE during commit phase (use .phase_commit tag).
/// Cards here already had costs validated when played during selection.
pub fn executeCommitPhaseRules(world: *World, actor: *Agent) !void {
    const cs = actor.combat_state orelse return;

    // Iterate over card IDs in play, look up instances via registry
    for (cs.in_play.items) |card_id| {
        const card = world.card_registry.get(card_id) orelse continue;

        for (card.template.rules) |rule| {
            if (rule.trigger != .on_commit) continue;

            // Check rule validity predicate (weapon requirements, range, etc.)
            if (!rulePredicatesSatisfied(card.template, actor, world.encounter)) continue;

            // Execute expressions
            for (rule.expressions) |expr| {
                // Check if this is a play-targeting expression
                switch (expr.target) {
                    .my_play, .opponent_play => {
                        var targets = try evaluatePlayTargets(world.alloc, expr.target, actor, world);
                        defer targets.deinit(world.alloc);

                        for (targets.items) |target| {
                            applyCommitPhaseEffect(expr.effect, target, world);
                        }
                    },
                    else => {
                        // Non-play targets handled elsewhere
                    },
                }
            }
        }
    }
}

// ============================================================================
// Resolution Phase Effect Execution
// ============================================================================

/// Execute all on_resolve rules for cards in play.
/// Called during tick resolution for non-technique effects (e.g., stamina/focus recovery).
/// Cards with on_resolve rules that have cost.exhausts=true are moved to exhaust zone.
pub fn executeResolvePhaseRules(world: *World, actor: *Agent) !void {
    const cs = actor.combat_state orelse return;
    const is_player = switch (actor.director) {
        .player => true,
        else => false,
    };
    const actor_meta: events.AgentMeta = .{ .id = actor.id, .player = is_player };

    // Track cards that resolved on_resolve rules and should exhaust
    var to_exhaust = try std.ArrayList(entity.ID).initCapacity(world.alloc, 4);
    defer to_exhaust.deinit(world.alloc);

    for (cs.in_play.items) |card_id| {
        const card = world.card_registry.get(card_id) orelse continue;

        var rule_fired = false;
        for (card.template.rules) |rule| {
            if (rule.trigger != .on_resolve) continue;

            // Check rule validity predicate (weapon requirements, range, etc.)
            if (!rulePredicatesSatisfied(card.template, actor, world.encounter)) continue;

            rule_fired = true;

            // Execute expressions
            for (rule.expressions) |expr| {
                switch (expr.target) {
                    .self => {
                        try applyResolveEffect(expr.effect, actor, is_player, world);
                    },
                    .all_enemies => {
                        // Get enemy targets
                        var targets = try evaluateTargets(world.alloc, .all_enemies, actor, world, null);
                        defer targets.deinit(world.alloc);

                        for (targets.items) |target| {
                            const target_is_player = switch (target.director) {
                                .player => true,
                                else => false,
                            };
                            try applyResolveEffect(expr.effect, target, target_is_player, world);
                        }
                    },
                    else => {
                        // Other targets not yet implemented for resolve effects
                    },
                }
            }
        }

        // Track exhausting cards that had on_resolve rules fire
        if (rule_fired and card.template.cost.exhausts) {
            try to_exhaust.append(world.alloc, card_id);
        }
    }

    // Move exhausting cards to exhaust zone
    for (to_exhaust.items) |card_id| {
        cs.moveCard(card_id, .in_play, .exhaust) catch continue;
        try world.events.push(.{
            .card_moved = .{
                .instance = card_id,
                .from = .in_play,
                .to = .exhaust,
                .actor = actor_meta,
            },
        });
    }
}

/// Apply a resolution phase effect to an agent.
fn applyResolveEffect(
    effect: cards.Effect,
    agent: *Agent,
    is_player: bool,
    world: *World,
) !void {
    const actor_meta: events.AgentMeta = .{ .id = agent.id, .player = is_player };

    switch (effect) {
        .modify_stamina => |mod| {
            const old_value = agent.stamina.current;
            const delta: f32 = @as(f32, @floatFromInt(mod.amount)) + (agent.stamina.max * mod.ratio);
            agent.stamina.current = @min(agent.stamina.current + delta, agent.stamina.max);
            agent.stamina.available = @min(agent.stamina.available + delta, agent.stamina.current);

            try world.events.push(.{ .stamina_recovered = .{
                .agent_id = agent.id,
                .amount = agent.stamina.current - old_value,
                .new_value = agent.stamina.current,
                .actor = actor_meta,
            } });
        },
        .modify_focus => |mod| {
            const old_value = agent.focus.current;
            const delta: f32 = @as(f32, @floatFromInt(mod.amount)) + (agent.focus.max * mod.ratio);
            agent.focus.current = @min(agent.focus.current + delta, agent.focus.max);
            agent.focus.available = @min(agent.focus.available + delta, agent.focus.current);

            try world.events.push(.{ .focus_recovered = .{
                .agent_id = agent.id,
                .amount = agent.focus.current - old_value,
                .new_value = agent.focus.current,
                .actor = actor_meta,
            } });
        },
        .add_condition => |active_cond| {
            try agent.conditions.append(world.alloc, active_cond);

            try world.events.push(.{ .condition_applied = .{
                .agent_id = agent.id,
                .condition = active_cond.condition,
                .actor = actor_meta,
            } });
        },
        else => {}, // Other effects not handled during resolution
    }
}

// ============================================================================
// Manoeuvre Effect Execution
// ============================================================================

/// Execute manoeuvre effects (range modification) before combat resolution.
/// Called after actions are committed but before they resolve.
pub fn executeManoeuvreEffects(world: *World) !void {
    const enc = world.encounter orelse return;

    // Process player manoeuvres
    try executeAgentManoeuvres(world, world.player, enc);

    // Process enemy manoeuvres
    for (enc.enemies.items) |mob| {
        try executeAgentManoeuvres(world, mob, enc);
    }
}

/// Execute manoeuvre effects for a single agent.
fn executeAgentManoeuvres(world: *World, actor: *Agent, enc: *combat.Encounter) !void {
    const enc_state = enc.stateFor(actor.id) orelse return;

    for (enc_state.current.slots()) |slot| {
        const card = world.card_registry.get(slot.play.action) orelse continue;

        // Only process manoeuvre cards
        if (!card.template.tags.manoeuvre) continue;

        // Find modify_range effects in the card's rules
        for (card.template.rules) |rule| {
            if (rule.trigger != .on_resolve) continue;

            for (rule.expressions) |expr| {
                switch (expr.effect) {
                    .modify_range => |range_mod| {
                        // Get the focal target for this manoeuvre
                        const focal_target = slot.play.target orelse continue;

                        // Apply range modification to the focal engagement
                        try applyRangeModification(
                            world,
                            enc,
                            actor.id,
                            focal_target,
                            range_mod.steps,
                            range_mod.propagate,
                        );
                    },
                    else => {},
                }
            }
        }
    }
}

/// Apply range modification to an engagement.
/// Clamps result to valid Reach values.
fn applyRangeModification(
    world: *World,
    enc: *combat.Encounter,
    actor_id: entity.ID,
    target_id: entity.ID,
    steps: i8,
    propagate: bool,
) !void {
    // Get the engagement to modify
    const engagement = enc.getEngagement(actor_id, target_id) orelse return;

    const old_range = engagement.range;
    engagement.range = adjustRange(engagement.range, steps);

    // Emit event if range changed
    if (engagement.range != old_range) {
        try world.events.push(.{ .range_changed = .{
            .actor_id = actor_id,
            .target_id = target_id,
            .old_range = old_range,
            .new_range = engagement.range,
        } });
    }

    // Propagation: apply n-1 steps to other engagements (Phase 5 multi-opponent)
    // Currently a no-op for single engagement encounters
    _ = propagate; // TODO (Phase 5): Iterate other engagements and apply reduced steps
}

/// Adjust a Reach value by a number of steps, clamping to valid range.
/// Negative steps = closer, positive steps = farther.
fn adjustRange(current: combat.Reach, steps: i8) combat.Reach {
    const current_int: i16 = @intFromEnum(current);
    const new_int = current_int + steps;

    // Clamp to valid enum range
    const min_reach: i16 = @intFromEnum(combat.Reach.clinch);
    const max_reach: i16 = @intFromEnum(combat.Reach.far);
    const clamped = @min(max_reach, @max(min_reach, new_int));

    return @enumFromInt(@as(u4, @intCast(clamped)));
}

// ============================================================================
// Condition Expiration
// ============================================================================

/// Tick down and remove expired conditions for an agent.
/// Called at end of tick after all effects have resolved.
pub fn tickConditions(agent: *Agent, event_system: *EventSystem) !void {
    const is_player = switch (agent.director) {
        .player => true,
        else => false,
    };
    const actor_meta: events.AgentMeta = .{ .id = agent.id, .player = is_player };

    // Iterate backwards so we can remove while iterating
    var i: usize = agent.conditions.items.len;
    while (i > 0) {
        i -= 1;
        const cond = &agent.conditions.items[i];

        var should_remove = false;
        switch (cond.expiration) {
            .ticks => |*remaining| {
                remaining.* -= 1.0;
                if (remaining.* <= 0) {
                    should_remove = true;
                }
            },
            .end_of_tick => {
                should_remove = true;
            },
            .dynamic, .permanent, .end_of_action, .end_of_combat => {},
        }

        if (should_remove) {
            const removed_condition = cond.condition;
            _ = agent.conditions.orderedRemove(i);

            try event_system.push(.{ .condition_expired = .{
                .agent_id = agent.id,
                .condition = removed_condition,
                .actor = actor_meta,
            } });
        }
    }
}

// ============================================================================
// Tick Cleanup (cost enforcement, card zone transitions, cooldowns)
// ============================================================================

const DEFAULT_COOLDOWN_TICKS: u8 = 2;

/// Apply costs and cleanup after tick resolution.
/// This is the authority for stamina deduction, card movement, and cooldowns.
pub fn applyCommittedCosts(
    committed: []const tick.CommittedAction,
    event_system: *EventSystem,
) !void {
    for (committed) |action| {
        const card = action.card orelse continue;
        const agent = action.actor;
        const is_player = switch (agent.director) {
            .player => true,
            else => false,
        };
        const actor_meta: events.AgentMeta = .{ .id = agent.id, .player = is_player };

        // Finalize stamina commitment (current catches down to available)
        const stamina_cost = card.template.cost.stamina;
        agent.stamina.finalize();

        try event_system.push(.{
            .stamina_deducted = .{
                .agent_id = agent.id,
                .amount = stamina_cost,
                .new_value = agent.stamina.current,
            },
        });

        // Move card to appropriate zone after use
        const cs = agent.combat_state orelse continue;
        switch (agent.draw_style) {
            .shuffled_deck => {
                // Deck-based: move to discard or exhaust
                const dest_zone: combat.CombatZone = if (card.template.cost.exhausts)
                    .exhaust
                else
                    .discard;

                cs.moveCard(card.id, .in_play, dest_zone) catch continue;
                try event_system.push(.{
                    .card_moved = .{
                        .instance = card.id,
                        .from = .in_play,
                        .to = if (card.template.cost.exhausts) .exhaust else .discard,
                        .actor = actor_meta,
                    },
                });
            },
            .always_available, .scripted => {
                // TODO: implement cooldown tracking on CombatState
                // always_available cards don't move zones, just reset cooldown (stub)
                cs.moveCard(card.id, .in_play, .discard) catch continue;
            },
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const weapon_list = @import("weapon_list.zig");
const weapon = @import("weapon.zig");
const ai = @import("ai.zig");

fn testId(index: u32) entity.ID {
    return .{ .index = index, .generation = 0 };
}

fn makeTestAgent(armament: combat.Armament) Agent {
    return Agent{
        .id = testId(99),
        .alloc = undefined,
        .director = ai.noop(),
        .draw_style = .shuffled_deck,
        .stats = undefined,
        .body = undefined,
        .armour = undefined,
        .weapons = armament,
        .stamina = stats.Resource.init(10.0, 10.0, 2.0),
        .focus = stats.Resource.init(3.0, 5.0, 3.0),
        .conditions = undefined,
        .immunities = undefined,
        .resistances = undefined,
        .vulnerabilities = undefined,
    };
}

test "rulePredicatesSatisfied allows card with always predicate" {
    const thrust_template = card_list.byName("thrust");
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const agent = makeTestAgent(.{ .single = &sword_instance });

    try testing.expect(rulePredicatesSatisfied(thrust_template, &agent, null));
}

test "rulePredicatesSatisfied allows shield block with shield equipped" {
    const shield_block = card_list.byName("shield block");
    var buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    const agent = makeTestAgent(.{ .single = &buckler_instance });

    try testing.expect(rulePredicatesSatisfied(shield_block, &agent, null));
}

test "rulePredicatesSatisfied denies shield block without shield" {
    const shield_block = card_list.byName("shield block");
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const agent = makeTestAgent(.{ .single = &sword_instance });

    try testing.expect(!rulePredicatesSatisfied(shield_block, &agent, null));
}

test "rulePredicatesSatisfied allows shield block with sword and shield dual wield" {
    const shield_block = card_list.byName("shield block");
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    var buckler_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.buckler };
    const agent = makeTestAgent(.{ .dual = .{
        .primary = &sword_instance,
        .secondary = &buckler_instance,
    } });

    try testing.expect(rulePredicatesSatisfied(shield_block, &agent, null));
}

// ============================================================================
// Expression Filter Tests
// ============================================================================

fn makeTestCardInstance(template: *const cards.Template) cards.Instance {
    return cards.Instance{
        .id = testId(0),
        .template = template,
    };
}

test "expressionAppliesToTarget returns true when no filter" {
    const thrust = card_list.byName("thrust");
    const expr = &thrust.rules[0].expressions[0];
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = &sword_instance });
    const target = makeTestAgent(.{ .single = &sword_instance });
    const card = makeTestCardInstance(thrust);

    try testing.expect(expressionAppliesToTarget(expr, &card, &actor, &target, null));
}

test "expressionAppliesToTarget with advantage_threshold filter passes when control high" {
    const riposte = card_list.byName("riposte");
    const expr = &riposte.rules[0].expressions[0];
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = &sword_instance });
    const target = makeTestAgent(.{ .single = &sword_instance });
    const card = makeTestCardInstance(riposte);

    // High control engagement (0.7 >= 0.6 threshold)
    var engagement = combat.Engagement{ .control = 0.7 };

    try testing.expect(expressionAppliesToTarget(expr, &card, &actor, &target, &engagement));
}

test "expressionAppliesToTarget with advantage_threshold filter fails when control low" {
    const riposte = card_list.byName("riposte");
    const expr = &riposte.rules[0].expressions[0];
    var sword_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.knights_sword };
    const actor = makeTestAgent(.{ .single = &sword_instance });
    const target = makeTestAgent(.{ .single = &sword_instance });
    const card = makeTestCardInstance(riposte);

    // Low control engagement (0.4 < 0.6 threshold)
    var engagement = combat.Engagement{ .control = 0.4 };

    try testing.expect(!expressionAppliesToTarget(expr, &card, &actor, &target, &engagement));
}

test "compareF32 operators" {
    try testing.expect(compareF32(0.5, .lt, 0.6));
    try testing.expect(!compareF32(0.6, .lt, 0.5));
    try testing.expect(compareF32(0.5, .lte, 0.5));
    try testing.expect(compareF32(0.5, .eq, 0.5));
    try testing.expect(compareF32(0.6, .gte, 0.5));
    try testing.expect(compareF32(0.6, .gt, 0.5));
}

test "compareReach operators" {
    try testing.expect(compareReach(.far, .eq, .far));
    try testing.expect(compareReach(.near, .lt, .far));
    try testing.expect(!compareReach(.far, .lt, .near));
}

// ============================================================================
// Modifier Attachment Tests
// ============================================================================

test "getModifierTargetPredicate extracts predicate from modifier template" {
    const high = card_list.byName("high");
    const predicate = try getModifierTargetPredicate(high);

    try testing.expect(predicate != null);
    // Modifier targets offensive plays
    try testing.expectEqual(cards.Predicate{ .has_tag = .{ .offensive = true } }, predicate.?);
}

test "getModifierTargetPredicate returns null for non-modifier" {
    const thrust = card_list.byName("thrust");
    const predicate = try getModifierTargetPredicate(thrust);

    try testing.expect(predicate == null);
}

test "canModifierAttachToPlay validates offensive tag match" {
    // Setup: need a World with card_registry containing an offensive play
    const alloc = testing.allocator;

    var wrld = try w.World.init(alloc);
    defer wrld.deinit();

    // Create a play with an offensive action card (thrust)
    const thrust_template = card_list.byName("thrust");
    const thrust_card = try wrld.card_registry.create(thrust_template);
    var play = combat.Play{ .action = thrust_card.id };

    // High modifier targets offensive plays
    const high = card_list.byName("high");
    const can_attach = try canModifierAttachToPlay(high, &play, wrld);

    try testing.expect(can_attach);
}

test "canModifierAttachToPlay rejects non-offensive play" {
    const alloc = testing.allocator;

    var wrld = try w.World.init(alloc);
    defer wrld.deinit();

    // Create a play with a non-offensive action card (parry is defensive)
    const parry_template = card_list.byName("parry");
    const parry_card = try wrld.card_registry.create(parry_template);
    var play = combat.Play{ .action = parry_card.id };

    // High modifier targets offensive plays - should reject defensive
    const high = card_list.byName("high");
    const can_attach = try canModifierAttachToPlay(high, &play, wrld);

    try testing.expect(!can_attach);
}

// ============================================================================
// Commit Phase Withdraw Tests
// ============================================================================

test "canWithdrawPlay returns true for play with no modifiers" {
    var play = combat.Play{ .action = testId(0) };
    try testing.expect(canWithdrawPlay(&play));
}

test "canWithdrawPlay returns false for play with modifiers attached" {
    var play = combat.Play{ .action = testId(0) };
    try play.addModifier(testId(1));

    try testing.expect(!canWithdrawPlay(&play));
}

// ============================================================================
// Melee Reach Validation Tests
// ============================================================================

fn makeTestEncounterWithEnemy(alloc: std.mem.Allocator, player_id: entity.ID, enemy: *Agent, range: combat.Reach) !*combat.Encounter {
    const enc = try combat.Encounter.init(alloc, player_id);
    try enc.enemies.append(alloc, enemy);
    try enc.setEngagement(player_id, enemy.id, combat.Engagement{ .range = range });
    try enc.agent_state.put(enemy.id, .{});
    return enc;
}

// Tests for validateMeleeReach, evaluateTargetIDsConst, getTargetsForQuery
// have been moved to apply/validation.zig and apply/targeting.zig
