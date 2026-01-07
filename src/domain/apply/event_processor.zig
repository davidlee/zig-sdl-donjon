//! Event processor - handles event-driven game state transitions.
//!
//! Processes events to trigger game phase transitions, card draws,
//! combat termination checks, and cleanup operations.

const std = @import("std");
const lib = @import("infra");
const combat = @import("../combat.zig");
const events = @import("../events.zig");
const w = @import("../world.zig");

const entity = lib.entity;

const commit = @import("effects/commit.zig");

const Event = events.Event;
const EventSystem = events.EventSystem;
const World = w.World;
const Agent = combat.Agent;

const log = std.debug.print;

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

    /// Clean up a card based on its source: discard hand cards, destroy pool clones.
    fn cleanupCardBySource(
        self: *EventProcessor,
        cs: *combat.CombatState,
        card_id: entity.ID,
        source: ?combat.PlaySource,
    ) !void {
        if (source) |_| {
            // Pool clone: destroy it (idempotent)
            self.world.card_registry.destroy(card_id);
        } else {
            // Hand card: add to discard if not already there
            if (!cs.isInZone(card_id, .discard) and !cs.isInZone(card_id, .exhaust)) {
                try cs.discard.append(cs.alloc, card_id);
            }
        }
    }

    fn agentEndTurnCleanup(self: *EventProcessor, agent: *Agent, enc: *combat.Encounter) !void {
        const cs = agent.combat_state orelse return;
        const enc_state = enc.stateFor(agent.id) orelse return;

        // Discard remaining hand cards
        while (cs.hand.items.len > 0) {
            const card_id = cs.hand.items[0];
            try cs.moveCard(card_id, .hand, .discard);
        }

        // Clean up remaining timeline plays (e.g. orphaned cards after resolution)
        // Timeline is the source of truth for what's in play
        for (enc_state.current.timeline.slots()) |slot| {
            const play = slot.play;

            // Clean up action card
            try self.cleanupCardBySource(cs, play.action, play.source);

            // Clean up modifier cards
            for (play.modifiers()) |mod| {
                try self.cleanupCardBySource(cs, mod.card_id, mod.source);
            }
        }

        // Refresh resources
        agent.stamina.tick();
        agent.focus.tick();
        agent.time_available = 1.0;

        // Clear turn state (push to history, clear timeline)
        enc_state.endTurn();
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

    /// Ensure all agents have plays built for commit phase.
    /// With the timeline model, plays are created at play time (selection phase for player,
    /// immediately for AI). This is now a no-op safety check.
    fn buildPlaysFromInPlayCards(self: *EventProcessor) !void {
        _ = self;
        // Plays are now created when cards are played:
        // - Player: playActionCard creates Play immediately during selection
        // - AI: directors create Plays via createPlayForInPlayCard
        // No additional bridging needed.
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
                            try commit.executeCommitPhaseRules(self.world, self.world.player);
                            // Execute on_commit rules for mobs
                            if (self.world.encounter) |enc| {
                                for (enc.enemies.items) |mob| {
                                    try commit.executeCommitPhaseRules(self.world, mob);
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

                    // Debug: log cards in play for mobs (via timeline)
                    if (self.world.encounter) |enc| {
                        for (enc.enemies.items) |mob| {
                            if (enc.stateForConst(mob.id)) |enc_state| {
                                for (enc_state.current.timeline.slots()) |slot| {
                                    if (self.world.card_registry.get(slot.play.action)) |instance| {
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
