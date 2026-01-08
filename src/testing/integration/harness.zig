//! Integration test harness for driving combat flows.
//!
//! Wraps World with convenience methods for test scenarios.
//! Manages lifecycle and provides ergonomic API for:
//! - Adding enemies from templates
//! - Card management (give, play, cancel)
//! - Phase control (transition, commit, resolve)
//! - Event assertions

const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;

// Import via integration_tests.zig root
const root = @import("integration_root");
const domain = root.domain;
const World = domain.World;
const combat = domain.combat;
const cards = domain.cards;
const card_list = domain.card_list;
const query = domain.query;
const personas = root.data.personas;
const fixtures = root.testing_utils.fixtures;

const events = domain.events;
const Event = events.Event;
const EventTag = std.meta.Tag(Event);

const Agent = combat.Agent;
const Encounter = combat.Encounter;
const TurnPhase = combat.TurnPhase;

// ============================================================================
// Harness
// ============================================================================

pub const Harness = struct {
    alloc: std.mem.Allocator,
    world: *World,

    pub fn init(alloc: std.mem.Allocator) !Harness {
        const world = try World.init(alloc);
        errdefer world.deinit();

        // Attach event handlers (initializes commandHandler and eventProcessor)
        world.attachEventHandlers();

        return .{
            .alloc = alloc,
            .world = world,
        };
    }

    pub fn deinit(self: *Harness) void {
        // World owns all entities (player, enemies, weapons)
        self.world.deinit();
    }

    // -------------------------------------------------------------------------
    // Accessors
    // -------------------------------------------------------------------------

    pub fn player(self: *Harness) *Agent {
        return self.world.player;
    }

    pub fn encounter(self: *Harness) *Encounter {
        return self.world.encounter.?;
    }

    pub fn turnPhase(self: *Harness) ?TurnPhase {
        return self.world.turnPhase();
    }

    // -------------------------------------------------------------------------
    // Enemy Management
    // -------------------------------------------------------------------------

    /// Add an enemy from a persona template. Returns the enemy agent.
    /// Creates the agent using world's entity system to avoid ID conflicts.
    pub fn addEnemyFromTemplate(self: *Harness, template: *const personas.AgentTemplate) !*Agent {
        const body_mod = @import("integration_root").domain.body;
        const ai = @import("../../domain/ai.zig");
        const weapon = @import("integration_root").domain.weapon;

        // Build Armament from template (using world's allocator)
        const equipped: combat.Armament.Equipped = switch (template.armament) {
            .unarmed => .unarmed,
            .single => |tmpl| blk: {
                const w = try self.alloc.create(weapon.Instance);
                w.* = .{ .id = try self.world.entities.weapons.insert(w), .template = tmpl };
                break :blk .{ .single = w };
            },
            .dual => |d| blk: {
                const primary = try self.alloc.create(weapon.Instance);
                primary.* = .{ .id = try self.world.entities.weapons.insert(primary), .template = d.primary };

                const secondary = try self.alloc.create(weapon.Instance);
                secondary.* = .{ .id = try self.world.entities.weapons.insert(secondary), .template = d.secondary };

                break :blk .{ .dual = .{ .primary = primary, .secondary = secondary } };
            },
        };
        const armament = combat.Armament{ .equipped = equipped, .natural = &.{} };

        // Convert DirectorKind to combat.Director
        const director: combat.Director = switch (template.director) {
            .player => .player,
            .noop_ai => ai.noop(),
        };

        // Create body from species
        const agent_body = try body_mod.Body.fromPlan(self.alloc, template.species.body_plan);

        // Derive resources from species with default recovery, or use template override
        const stats = @import("integration_root").domain.stats;
        const sp = template.species;
        const stamina_res = template.stamina orelse stats.Resource.init(sp.base_stamina, sp.base_stamina, 2.0);
        const focus_res = template.focus orelse stats.Resource.init(sp.base_focus, sp.base_focus, 1.0);
        const blood_res = template.blood orelse stats.Resource.init(sp.base_blood, sp.base_blood, 0.0);

        // Create agent using world's agents map
        const enemy = try Agent.init(
            self.alloc,
            self.world.entities.agents,
            director,
            template.draw_style,
            template.base_stats,
            agent_body,
            stamina_res,
            focus_res,
            blood_res,
            armament,
        );

        enemy.name = .{ .static = template.name };

        // Add to encounter
        try self.encounter().addEnemy(enemy);

        return enemy;
    }

    // -------------------------------------------------------------------------
    // Card Management
    // -------------------------------------------------------------------------

    /// Give a card to an agent by template name (from card_list).
    /// Creates a new instance and adds to hand.
    pub fn giveCard(self: *Harness, agent: *Agent, comptime template_name: []const u8) !entity.ID {
        const template = card_list.byName(template_name);
        const instance = try self.world.card_registry.create(template);

        // Add to combat state hand
        const cs = agent.combat_state orelse return error.NoCombatState;
        try cs.hand.append(self.alloc, instance.id);

        return instance.id;
    }

    /// Find a card in player's always_available by name.
    pub fn findAlwaysAvailable(self: *Harness, name: []const u8) ?entity.ID {
        for (self.player().always_available.items) |id| {
            if (self.world.card_registry.getConst(id)) |card| {
                if (std.mem.eql(u8, card.template.name, name)) {
                    return id;
                }
            }
        }
        return null;
    }

    // -------------------------------------------------------------------------
    // Phase Control
    // -------------------------------------------------------------------------

    /// Transition to a specific turn phase.
    pub fn transitionTo(self: *Harness, phase: TurnPhase) !void {
        try self.world.transitionTurnTo(phase);
    }

    /// Ensure we're in selection phase (common setup).
    /// Initializes combat state and transitions directly to selection phase
    /// (bypassing draw/shuffle to give tests control over hand contents).
    pub fn beginSelection(self: *Harness) !void {
        // Start encounter if not already
        if (self.world.turnPhase() == null) {
            try self.world.transitionTo(.in_encounter);
        }

        // Initialize combat state for player (normally done by event processor)
        try self.player().initCombatState();

        // Initialize combat state for enemies
        for (self.encounter().enemies.items) |enemy| {
            try enemy.initCombatState();
        }

        // Transition through phases to reach selection
        const current = self.world.turnPhase() orelse return error.NoPhase;
        if (current == .draw_hand) {
            try self.transitionTo(.player_card_selection);
        }
    }

    // -------------------------------------------------------------------------
    // Play Control
    // -------------------------------------------------------------------------

    /// Play a card from hand or always_available. Must be in selection phase.
    pub fn playCard(self: *Harness, card_id: entity.ID, target: ?entity.ID) !void {
        try self.world.commandHandler.playActionCard(card_id, target);
    }

    /// Cancel a card that's currently in play. Must be in selection phase.
    pub fn cancelCard(self: *Harness, card_id: entity.ID) !void {
        try self.world.commandHandler.cancelActionCard(card_id);
    }

    /// Withdraw a card during commit phase. Costs 1 focus.
    pub fn withdrawCard(self: *Harness, card_id: entity.ID) !void {
        try self.world.commandHandler.commitWithdraw(card_id);
    }

    /// Stack a modifier onto a play during commit phase.
    pub fn stackModifier(self: *Harness, modifier_id: entity.ID, play_index: usize) !void {
        try self.world.commandHandler.commitStack(modifier_id, play_index);
    }

    /// Transition to commit phase, triggering commit effects.
    pub fn commitPlays(self: *Harness) !void {
        try self.transitionTo(.commit_phase);
    }

    /// Resolve a single tick (all plays in the current timeline slot).
    pub fn resolveTick(self: *Harness) !void {
        var result = try self.world.processTick();
        result.deinit();
    }

    /// Resolve all remaining ticks until timeline is empty.
    pub fn resolveAllTicks(self: *Harness) !void {
        // Transition to tick resolution if not already there
        const phase = self.turnPhase() orelse return error.NoPhase;
        if (phase == .commit_phase) {
            try self.transitionTo(.tick_resolution);
        }

        // Process ticks until timeline cleared
        while (self.hasActivePlays()) {
            var result = try self.world.processTick();
            result.deinit();
        }
    }

    /// Check if there are active plays in the timeline.
    pub fn hasActivePlays(self: *Harness) bool {
        const player_state = self.encounter().stateFor(self.player().id) orelse return false;
        return player_state.current.timeline.len() > 0;
    }

    // -------------------------------------------------------------------------
    // Inspection
    // -------------------------------------------------------------------------

    /// Get the player's current plays (via timeline slots).
    pub fn getPlays(self: *Harness) []const combat.TimeSlot {
        const player_state = self.encounter().stateFor(self.player().id) orelse return &[_]combat.TimeSlot{};
        return player_state.current.slots();
    }

    /// Get player's stamina (current value).
    pub fn playerStamina(self: *Harness) f32 {
        return self.player().stamina.current;
    }

    /// Get player's available stamina (current minus committed).
    pub fn playerAvailableStamina(self: *Harness) f32 {
        return self.player().stamina.available;
    }

    /// Get player's current focus.
    pub fn playerFocus(self: *Harness) f32 {
        return self.player().focus.current;
    }

    /// Get player's hand card IDs.
    pub fn playerHand(self: *Harness) []const entity.ID {
        const cs = self.player().combat_state orelse return &[_]entity.ID{};
        return cs.hand.items;
    }

    /// Check if a card is in player's hand.
    pub fn isInHand(self: *Harness, card_id: entity.ID) bool {
        for (self.playerHand()) |id| {
            if (id.eql(card_id)) return true;
        }
        return false;
    }

    /// Check if a card ID is on cooldown.
    pub fn isOnCooldown(self: *Harness, card_id: entity.ID) bool {
        const cs = self.player().combat_state orelse return false;
        return cs.cooldowns.contains(card_id);
    }

    // -------------------------------------------------------------------------
    // Engagement Manipulation
    // -------------------------------------------------------------------------

    /// Get the engagement between player and an enemy.
    pub fn getEngagement(self: *Harness, enemy_id: entity.ID) ?*combat.Engagement {
        return self.encounter().getPlayerEngagement(enemy_id);
    }

    /// Set the engagement range between player and an enemy.
    pub fn setRange(self: *Harness, enemy_id: entity.ID, range: combat.Reach) void {
        if (self.getEngagement(enemy_id)) |eng| {
            eng.range = range;
        }
    }

    /// Set the control advantage against an enemy.
    pub fn setControl(self: *Harness, enemy_id: entity.ID, control: f32) void {
        if (self.getEngagement(enemy_id)) |eng| {
            eng.control = control;
        }
    }

    /// Configure the player from an AgentTemplate (persona).
    /// Applies name, stats, resources, and armament from the template.
    /// Does not change body or director.
    pub fn setPlayerFromTemplate(self: *Harness, template: *const personas.AgentTemplate) !void {
        const stats = @import("integration_root").domain.stats;
        const p = self.player();
        p.name = .{ .static = template.name };
        p.stats = template.base_stats;

        // Apply resource overrides from template, or derive from species
        const sp = template.species;
        p.stamina = template.stamina orelse stats.Resource.init(sp.base_stamina, sp.base_stamina, 2.0);
        p.focus = template.focus orelse stats.Resource.init(sp.base_focus, sp.base_focus, 1.0);
        p.blood = template.blood orelse stats.Resource.init(sp.base_blood, sp.base_blood, 0.0);

        // Apply armament (preserves natural weapons from agent's species)
        const equipped: domain.combat.Armament.Equipped = switch (template.armament) {
            .unarmed => .unarmed,
            .single => |tmpl| blk: {
                const instance = try self.alloc.create(domain.weapon.Instance);
                instance.* = .{
                    .id = try self.world.entities.weapons.insert(instance),
                    .template = tmpl,
                };
                break :blk .{ .single = instance };
            },
            .dual => |d| blk: {
                const primary = try self.alloc.create(domain.weapon.Instance);
                primary.* = .{
                    .id = try self.world.entities.weapons.insert(primary),
                    .template = d.primary,
                };
                const secondary = try self.alloc.create(domain.weapon.Instance);
                secondary.* = .{
                    .id = try self.world.entities.weapons.insert(secondary),
                    .template = d.secondary,
                };
                break :blk .{ .dual = .{ .primary = primary, .secondary = secondary } };
            },
        };
        p.weapons = p.weapons.withEquipped(equipped);
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// Get all pending events (newly pushed, not yet processed).
    /// Events are pushed to next_events; this returns that buffer.
    pub fn drainEvents(self: *Harness) []const Event {
        return self.world.events.next_events.items;
    }

    /// Check if an event with the given tag exists in pending events.
    pub fn hasEvent(self: *Harness, tag: EventTag) bool {
        for (self.world.events.next_events.items) |event| {
            if (std.meta.activeTag(event) == tag) {
                return true;
            }
        }
        return false;
    }

    /// Assert that an event with the given tag exists. Fails the test if not found.
    pub fn expectEvent(self: *Harness, tag: EventTag) !void {
        if (!self.hasEvent(tag)) {
            std.debug.print("Expected event with tag {s}, but not found\n", .{@tagName(tag)});
            return error.ExpectedEventNotFound;
        }
    }

    /// Assert that no event with the given tag exists.
    pub fn expectNoEvent(self: *Harness, tag: EventTag) !void {
        if (self.hasEvent(tag)) {
            std.debug.print("Expected no event with tag {s}, but found one\n", .{@tagName(tag)});
            return error.UnexpectedEventFound;
        }
    }

    /// Clear all pending events (useful between test phases).
    pub fn clearEvents(self: *Harness) void {
        self.world.events.next_events.clearRetainingCapacity();
    }

    // ========================================================================
    // Snapshot queries
    // ========================================================================

    /// Get card status from a fresh snapshot. Useful for testing UI state
    /// derivation (playable, has_valid_targets).
    pub fn getCardStatus(self: *Harness, card_id: entity.ID) !?query.CardStatus {
        var snapshot = try query.buildSnapshot(self.alloc, self.world);
        defer snapshot.deinit();
        return snapshot.card_statuses.get(card_id);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Harness init/deinit does not leak" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    // If we get here without leak errors, init/deinit works
    // Just verify we can access player
    _ = harness.player();
}

test "Harness addEnemyFromTemplate adds enemy to encounter" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    const enemy = try harness.addEnemyFromTemplate(&personas.Agents.ser_marcus);

    try testing.expectEqual(@as(usize, 1), harness.encounter().enemies.items.len);
    try testing.expectEqualStrings("Ser Marcus", enemy.name.value());
}

test "Harness findAlwaysAvailable finds thrust" {
    var harness = try Harness.init(testing.allocator);
    defer harness.deinit();

    const thrust_id = harness.findAlwaysAvailable("thrust");
    try testing.expect(thrust_id != null);
}
