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
const actions = domain.actions;
const card_list = domain.action_list;
const query = domain.query;
const personas = root.data.personas;
const fixtures = root.testing_utils.fixtures;

const events = domain.events;
const Event = events.Event;
const EventTag = std.meta.Tag(Event);

const Agent = combat.Agent;
const Encounter = combat.Encounter;
const TurnPhase = combat.TurnPhase;
const random = domain.random;

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
        const ai = @import("../../domain/ai.zig");
        const wpn = @import("integration_root").domain.weapon;

        // Convert DirectorKind to combat.Director
        const director: combat.Director = switch (template.director) {
            .player => .player,
            .noop_ai => ai.noop(),
        };

        // Create agent (body, resources, natural weapons derived from species)
        const enemy = try Agent.init(
            self.alloc,
            self.world.entities.agents,
            director,
            template.draw_style,
            template.species,
            template.base_stats,
        );
        enemy.name = .{ .static = template.name };

        // Equip weapons from template
        switch (template.armament) {
            .unarmed => {}, // Agent already starts unarmed with natural weapons
            .single => |tmpl| {
                const w = try self.alloc.create(wpn.Instance);
                w.* = .{ .id = try self.world.entities.weapons.insert(w), .template = tmpl };
                enemy.weapons = enemy.weapons.withEquipped(.{ .single = w });
            },
            .dual => |d| {
                const primary = try self.alloc.create(wpn.Instance);
                primary.* = .{ .id = try self.world.entities.weapons.insert(primary), .template = d.primary };

                const secondary = try self.alloc.create(wpn.Instance);
                secondary.* = .{ .id = try self.world.entities.weapons.insert(secondary), .template = d.secondary };

                enemy.weapons = enemy.weapons.withEquipped(.{ .dual = .{ .primary = primary, .secondary = secondary } });
            },
        }

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
        const instance = try self.world.action_registry.create(template);

        // Add to combat state hand
        const cs = agent.combat_state orelse return error.NoCombatState;
        try cs.hand.append(self.alloc, instance.id);

        return instance.id;
    }

    /// Find a card in player's always_available by name.
    pub fn findAlwaysAvailable(self: *Harness, name: []const u8) ?entity.ID {
        for (self.player().always_available.items) |id| {
            if (self.world.action_registry.getConst(id)) |card| {
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
    /// (bypassing stance selection and draw/shuffle to give tests control).
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

        // Force transition to selection phase (bypasses FSM validation for tests)
        const current = self.world.turnPhase() orelse return error.NoPhase;
        if (current != .player_card_selection) {
            self.encounter().forceTransitionTo(.player_card_selection);
        }
    }

    /// Confirm stance selection with given weights. Must be in stance_selection phase.
    pub fn confirmStance(self: *Harness, attack: f32, defense: f32, movement: f32) !void {
        try self.world.commandHandler.confirmStance(.{
            .attack = attack,
            .defense = defense,
            .movement = movement,
        });
    }

    /// Start encounter and stay in stance_selection phase (don't bypass).
    /// Use this when testing stance phase flow specifically.
    pub fn beginStanceSelection(self: *Harness) !void {
        // Start encounter if not already
        if (self.world.turnPhase() == null) {
            try self.world.transitionTo(.in_encounter);
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
    /// Applies name, stats, and armament from the template.
    /// Resources are derived from template's species.
    /// Does not change body or director.
    pub fn setPlayerFromTemplate(self: *Harness, template: *const personas.AgentTemplate) !void {
        const stats = @import("integration_root").domain.stats;
        const p = self.player();
        p.name = .{ .static = template.name };
        p.stats = template.base_stats;
        p.species = template.species;

        // Derive resources from template's species
        const sp = template.species;
        p.stamina = stats.Resource.init(sp.base_stamina, sp.base_stamina, sp.getStaminaRecovery());
        p.focus = stats.Resource.init(sp.base_focus, sp.base_focus, sp.getFocusRecovery());
        p.blood = stats.Resource.init(sp.base_blood, sp.base_blood, sp.getBloodRecovery());

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

    /// Get weapon name from the most recent resolution event.
    /// Checks both technique_resolved and contested_roll_resolved.
    /// Returns null if no such event exists.
    pub fn getResolvedWeaponName(self: *Harness) ?[]const u8 {
        // Search backwards to find most recent
        const items = self.world.events.next_events.items;
        var i = items.len;
        while (i > 0) {
            i -= 1;
            switch (items[i]) {
                .technique_resolved => |e| return e.weapon_name,
                .contested_roll_resolved => |e| return e.weapon_name,
                else => {},
            }
        }
        return null;
    }

    /// Assert that a resolution event (technique_resolved or contested_roll_resolved) exists.
    pub fn expectResolutionEvent(self: *Harness) !void {
        if (self.hasEvent(.technique_resolved) or self.hasEvent(.contested_roll_resolved)) {
            return;
        }
        std.debug.print("Expected resolution event (technique_resolved or contested_roll_resolved), but not found\n", .{});
        return error.ExpectedEventNotFound;
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
    // -------------------------------------------------------------------------
    // Forced Resolution (Data-Driven Tests)
    // -------------------------------------------------------------------------

    /// Result of a forced attack resolution for data-driven tests.
    pub const ForceResolveResult = struct {
        outcome: resolution.Outcome,
        damage_dealt: f32,
        armour_deflected: bool,
        layers_penetrated: u8,
    };

    /// Directly resolve an attack without the card/timeline system.
    /// Used for data-driven combat tests that verify physics calculations.
    /// Uses ScriptedRandomProvider to force deterministic hits (roll=0.0).
    pub fn forceResolveAttack(
        self: *Harness,
        attacker: *Agent,
        defender: *Agent,
        technique_id_str: []const u8,
        weapon_template: *const weapon.Template,
        stakes_str: []const u8,
        target_part_str: []const u8,
    ) !ForceResolveResult {
        // Parse stakes from string
        const stakes = parseStakes(stakes_str);

        // Look up technique by string ID
        const technique = findTechniqueByName(technique_id_str) orelse
            return error.UnknownTechnique;

        // Get target part index by computing hash at runtime
        const hash = std.hash.Wyhash.hash(0, target_part_str);
        const target_part = defender.body.index_by_hash.get(hash) orelse
            return error.UnknownBodyPart;

        // Get or create engagement
        const engagement = self.getEngagement(defender.id) orelse
            return error.NoEngagement;

        // Build attack context
        const attack_ctx = resolution.context.AttackContext{
            .attacker = attacker,
            .defender = defender,
            .technique = technique,
            .weapon_template = weapon_template,
            .stakes = stakes,
            .engagement = engagement,
            .time_start = 0,
            .time_end = 1.0,
            .attention_penalty = 0,
        };

        // Build defense context (minimal - defender is passive)
        const defense_ctx = resolution.context.DefenseContext{
            .defender = defender,
            .technique = technique,
            .weapon_template = weapon_template,
            .engagement = engagement,
            .computed = .{},
            .time_start = 0,
            .time_end = 1.0,
        };

        // Inject scripted random provider for deterministic results:
        // Contested roll system draws: attack_roll, defense_roll, then gap_roll(s)
        // - 0.8: attack roll (high favors attacker)
        // - 0.2: defense roll (low favors attacker)
        // - 0.99: gap roll (high means no gap, armour blocks)
        // Values cycle for multiple gap checks per resolution
        var scripted = random.ScriptedRandomProvider{ .values = &.{ 0.8, 0.2, 0.99 } };
        const original_provider = self.world.random_provider;
        self.world.random_provider = scripted.provider();
        defer self.world.random_provider = original_provider;

        // Resolve the attack through the real resolution pipeline
        const result = try resolution.outcome.resolveTechniqueVsDefense(
            self.world,
            attack_ctx,
            defense_ctx,
            target_part,
        );

        // Extract damage dealt (post-armour, post-body)
        // Use severity as a proxy for damage - converts severity to 0-10 scale
        var damage_dealt: f32 = 0.0;
        if (result.body_result) |br| {
            const severity = br.wound.worstSeverity();
            damage_dealt = @floatFromInt(@intFromEnum(severity));
        } else if (result.armour_result) |ar| {
            damage_dealt = ar.remaining.amount;
        } else if (result.damage_packet) |pkt| {
            damage_dealt = pkt.amount;
        }

        // Check if armour deflected
        const armour_deflected = if (result.armour_result) |ar| ar.deflected else false;

        // Count layers penetrated
        const layers_penetrated = if (result.armour_result) |ar| ar.layers_hit else 0;

        return ForceResolveResult{
            .outcome = result.outcome,
            .damage_dealt = damage_dealt,
            .armour_deflected = armour_deflected,
            .layers_penetrated = layers_penetrated,
        };
    }
};

// ============================================================================
// Module-level helpers for data-driven tests
// ============================================================================

const resolution = domain.resolution;
const weapon = domain.weapon;
const body = domain.body;
const armour = domain.armour;
const Technique = actions.Technique;
const Stakes = actions.Stakes;

/// Look up a technique by its string ID (e.g., "swing", "thrust").
fn findTechniqueByName(id_str: []const u8) ?*const Technique {
    const entries = &card_list.TechniqueEntries;
    for (entries) |*t| {
        if (std.mem.eql(u8, t.name, id_str)) {
            return t;
        }
    }
    return null;
}

/// Parse stakes string to Stakes enum.
fn parseStakes(s: []const u8) Stakes {
    if (std.mem.eql(u8, s, "probing")) return .probing;
    if (std.mem.eql(u8, s, "guarded")) return .guarded;
    if (std.mem.eql(u8, s, "committed")) return .committed;
    if (std.mem.eql(u8, s, "reckless")) return .reckless;
    return .committed; // default
}

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
