/// World state, entity registries, and turn FSM.
///
/// Owns the authoritative game state (entities, encounters, events, RNG streams)
/// and exposes APIs for transitioning phases. Presentation interacts via higher
/// layers; no SDL or rendering here.
const std = @import("std");
const lib = @import("infra");
const zigfsm = @import("zigfsm");
const player = @import("player.zig");
const random = @import("random.zig");
const events = @import("events.zig");
const apply = @import("apply.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const species = @import("species.zig");
const stats = @import("stats.zig");
const combat = @import("combat.zig");
const tick = @import("tick.zig");
const weapon = @import("weapon.zig");

const EventSystem = events.EventSystem;
const CommandHandler = apply.CommandHandler;
const EventProcessor = apply.EventProcessor;
const Event = events.Event;
const SlotMap = @import("slot_map.zig").SlotMap;
const BeginnerDeck = card_list.BeginnerDeck;
const BaseTechniques = card_list.BaseAlwaysAvailableTemplates;
const TickResolver = tick.TickResolver;

const WorldError = error{
    InvalidStateTransition,
};

/// Central registry for all card instances. Containers (Agent, Encounter) hold IDs.
pub const CardRegistry = struct {
    alloc: std.mem.Allocator,
    entities: SlotMap(*cards.Instance),
    // Tracks indices whose memory was freed via destroy() (not just removed)
    destroyed_indices: std.AutoHashMap(u32, void),

    pub fn init(alloc: std.mem.Allocator) !CardRegistry {
        return .{
            .alloc = alloc,
            .entities = try SlotMap(*cards.Instance).init(alloc),
            .destroyed_indices = std.AutoHashMap(u32, void).init(alloc),
        };
    }

    pub fn deinit(self: *CardRegistry) void {
        // Free only instances that weren't already destroyed via destroy()
        for (self.entities.items.items, 0..) |instance, i| {
            if (!self.destroyed_indices.contains(@intCast(i))) {
                self.alloc.destroy(instance);
            }
        }
        self.destroyed_indices.deinit();
        self.entities.deinit();
    }

    /// Create a new card instance from a template
    pub fn create(self: *CardRegistry, template: *const cards.Template) !*cards.Instance {
        const instance = try self.alloc.create(cards.Instance);
        const id = try self.entities.insert(instance);
        instance.* = .{ .id = id, .template = template };
        return instance;
    }

    /// Look up a card instance by ID (mutable)
    pub fn get(self: *CardRegistry, id: lib.entity.ID) ?*cards.Instance {
        const ptr = self.entities.get(id) orelse return null;
        return ptr.*;
    }

    /// Look up a card instance by ID (const)
    pub fn getConst(self: *const CardRegistry, id: lib.entity.ID) ?*const cards.Instance {
        const ptr = self.entities.getConst(id) orelse return null;
        return ptr.*;
    }

    /// Invalidate a card ID without freeing memory.
    /// Memory is reclaimed when the registry is deinitialized.
    ///
    /// NOTE: This means mob cards from encounters accumulate until session end.
    /// For long sessions, consider either:
    /// - Pooling/reusing mob card instances
    /// - Implementing proper destroy with generation-aware cleanup
    /// - Periodic compaction during loading screens
    ///
    /// TODO: If memory becomes an issue, implement destroyAndFree with
    /// tracking to avoid double-free in deinit.
    pub fn remove(self: *CardRegistry, id: lib.entity.ID) void {
        self.entities.remove(id);
    }

    /// Clone an existing card instance, returning a new instance with fresh ID.
    /// Used for ephemeral copies when playing pool cards (always_available, spells_known).
    pub fn clone(self: *CardRegistry, id: lib.entity.ID) !*cards.Instance {
        const original = self.get(id) orelse return error.CardNotFound;
        return self.create(original.template);
    }

    /// Remove and free a card instance immediately.
    /// Used for ephemeral copies after resolution.
    pub fn destroy(self: *CardRegistry, id: lib.entity.ID) void {
        if (self.entities.get(id)) |ptr| {
            const instance = ptr.*;
            self.entities.remove(id);
            self.destroyed_indices.put(id.index, {}) catch {};
            self.alloc.destroy(instance);
        }
    }

    /// Create cards from templates and return their IDs.
    /// Used to populate Agent.deck_cards.
    pub fn createFromTemplates(
        self: *CardRegistry,
        templates: []const cards.Template,
        copies_per_template: usize,
    ) !std.ArrayList(lib.entity.ID) {
        var ids = try std.ArrayList(lib.entity.ID).initCapacity(
            self.alloc,
            templates.len * copies_per_template,
        );
        errdefer ids.deinit(self.alloc);

        for (templates) |*template| {
            for (0..copies_per_template) |_| {
                const instance = try self.create(template);
                try ids.append(self.alloc, instance.id);
            }
        }
        return ids;
    }

    /// Create cards from template pointers and return their IDs.
    /// Used for arrays of template pointers.
    pub fn createFromTemplatePtrs(
        self: *CardRegistry,
        templates: []const *const cards.Template,
        copies_per_template: usize,
    ) !std.ArrayList(lib.entity.ID) {
        var ids = try std.ArrayList(lib.entity.ID).initCapacity(
            self.alloc,
            templates.len * copies_per_template,
        );
        errdefer ids.deinit(self.alloc);

        for (templates) |template| {
            for (0..copies_per_template) |_| {
                const instance = try self.create(template);
                try ids.append(self.alloc, instance.id);
            }
        }
        return ids;
    }
};

pub const EntityMap = struct {
    agents: *SlotMap(*combat.Agent),
    weapons: *SlotMap(*weapon.Instance),
    // ... etc

    pub fn init(alloc: std.mem.Allocator) !EntityMap {
        const agents = try alloc.create(SlotMap(*combat.Agent));
        agents.* = try SlotMap(*combat.Agent).init(alloc);

        const weapons = try alloc.create(SlotMap(*weapon.Instance));
        weapons.* = try SlotMap(*weapon.Instance).init(alloc);

        return .{ .agents = agents, .weapons = weapons };
    }

    /// Frees containers only - callers must explicitly deinit items before calling this
    pub fn deinit(self: *EntityMap, alloc: std.mem.Allocator) void {
        self.agents.deinit();
        alloc.destroy(self.agents);

        for (self.weapons.items.items) |x| alloc.destroy(x);
        self.weapons.deinit();
        alloc.destroy(self.weapons);
    }
};

/// Events that trigger game state transitions (high-level app/context).
/// Turn phase transitions are handled by Encounter's turn_fsm.
pub const GameEvent = enum {
    start_encounter, // splash -> in_encounter
    end_encounter, // in_encounter -> encounter_summary (victory/flee/surrender)
    player_died, // in_encounter -> splash (defeat)
    loot_collected, // encounter_summary -> world_map
};

/// High-level game state (app/context level).
/// Turn phases within combat are managed by Encounter.turn_fsm.
pub const GameState = enum {
    splash, // title screen / game over
    in_encounter, // active combat (turn phase via Encounter.turnPhase())
    encounter_summary, // post-combat loot/summary
    world_map, // between encounters (stub)
};

pub const World = struct {
    alloc: std.mem.Allocator,
    events: EventSystem,
    encounter: ?*combat.Encounter,
    random_impl: random.StreamRandomProvider,
    random_provider: random.RandomProvider,
    entities: EntityMap,
    card_registry: CardRegistry,
    player: *combat.Agent,
    fsm: zigfsm.StateMachine(GameState, GameEvent, .splash),
    tickResolver: TickResolver,
    commandHandler: CommandHandler,
    eventProcessor: EventProcessor,

    pub fn init(alloc: std.mem.Allocator) !*World {
        const FSM = zigfsm.StateMachine(GameState, GameEvent, .splash);

        var fsm = FSM.init();

        // High-level game state transitions
        try fsm.addEventAndTransition(.start_encounter, .splash, .in_encounter);
        try fsm.addEventAndTransition(.end_encounter, .in_encounter, .encounter_summary);
        try fsm.addEventAndTransition(.player_died, .in_encounter, .splash);
        try fsm.addEventAndTransition(.loot_collected, .encounter_summary, .world_map);

        const playerStats = stats.Block.splat(5);

        const self = try alloc.create(World);

        self.* = .{
            .alloc = alloc,
            .events = try EventSystem.init(alloc),
            .encounter = null, // created after player
            .random_impl = random.StreamRandomProvider.init(),
            .random_provider = undefined, // set after struct init
            .entities = try EntityMap.init(alloc),
            .card_registry = try CardRegistry.init(alloc),
            .player = undefined, // set after entities exist
            .fsm = fsm,
            .tickResolver = try TickResolver.init(alloc),
            .eventProcessor = undefined,
            .commandHandler = undefined,
        };

        // Wire up random provider (must be after struct init for stable pointer)
        self.random_provider = self.random_impl.provider();

        // Create player (body, resources, natural weapons derived from species)
        self.player = try player.newPlayer(alloc, self, &species.DWARF, playerStats);

        // Populate always_available with techniques (1 copy each)
        var technique_ids = try self.card_registry.createFromTemplatePtrs(&BaseTechniques, 1);
        defer technique_ids.deinit(alloc);
        for (technique_ids.items) |id| {
            try self.player.always_available.append(alloc, id);
        }

        // Populate deck_cards from BeginnerDeck
        var modifier_ids = try self.card_registry.createFromTemplatePtrs(&BeginnerDeck, 1);
        defer modifier_ids.deinit(alloc);
        for (modifier_ids.items) |id| {
            try self.player.deck_cards.append(alloc, id);
        }

        self.encounter = try combat.Encounter.init(alloc, self.player.id);
        self.encounter.?.initAttentionFor(self.player.id, self.player.stats.acuity);
        return self;
    }

    pub fn attachEventHandlers(self: *World) void {
        self.eventProcessor = EventProcessor.init(self);
        self.commandHandler = CommandHandler.init(self);
    }

    pub fn deinit(self: *World) void {
        self.events.deinit();
        self.tickResolver.deinit();

        // Deinit encounter enemies (removes from entities.agents)
        if (self.encounter) |encounter| {
            encounter.deinit(self.entities.agents);
        }

        // Deinit player explicitly
        self.player.deinit();

        // Deinit card registry (frees all card instances)
        self.card_registry.deinit();

        // Deinit entity containers (items already freed above)
        self.entities.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn step(self: *World) !void {
        while (try self.eventProcessor.dispatchEvent(&self.events)) {
            // std.debug.print("processed events:\n", .{});
        }
    }

    pub fn transitionTo(self: *World, target_state: GameState) !void {
        if (self.fsm.canTransitionTo(target_state)) {
            try self.fsm.transitionTo(target_state);
            try self.events.push(Event{ .game_state_transitioned_to = target_state });
        } else return WorldError.InvalidStateTransition;
    }

    // =========================================================================
    // Turn phase facade (delegates to Encounter)
    // =========================================================================

    /// Current turn phase, or null if not in an encounter.
    pub fn turnPhase(self: *const World) ?combat.TurnPhase {
        if (self.encounter) |enc| return enc.turnPhase();
        return null;
    }

    /// Check if currently in a specific turn phase.
    pub fn inTurnPhase(self: *const World, phase: combat.TurnPhase) bool {
        return self.turnPhase() == phase;
    }

    /// Transition to a new turn phase (delegates to encounter).
    pub fn transitionTurnTo(self: *World, target: combat.TurnPhase) !void {
        if (self.encounter) |enc| {
            try enc.transitionTurnTo(target);
            try self.events.push(Event{ .turn_phase_transitioned_to = target });
        } else return WorldError.InvalidStateTransition;
    }

    /// Process a complete tick: commit actions, resolve, cleanup
    pub fn processTick(self: *World) !tick.TickResult {
        // Reset resolver for new tick
        self.tickResolver.reset();

        // Commit player cards (using plays from AgentEncounterState)
        try self.tickResolver.commitPlayerCards(self.player, self);

        // Commit mob actions
        if (self.encounter) |enc| {
            try self.tickResolver.commitMobActions(enc.enemies.items, self);
        }

        // Execute manoeuvre effects (range modification) before combat resolution
        try apply.executeManoeuvreEffects(self);

        // Resolve positioning contests (bonus step for winner, weapon reach floor)
        try apply.resolvePositioningContests(self);

        // Resolve all actions
        const result = try self.tickResolver.resolve(self);

        // Execute on_resolve effects (stamina/focus recovery, etc.)
        try apply.executeResolvePhaseRules(self, self.player);
        if (self.encounter) |enc| {
            for (enc.enemies.items) |mob| {
                try apply.executeResolvePhaseRules(self, mob);
            }
        }

        // Cleanup: apply costs, move cards
        try apply.applyCommittedCosts(self.tickResolver.committed.items, &self.events, &self.card_registry);

        // Tick down and expire conditions
        try apply.tickConditions(self.player, &self.events);
        if (self.encounter) |enc| {
            for (enc.enemies.items) |mob| {
                try apply.tickConditions(mob, &self.events);
            }
        }

        // Emit tick ended event
        try self.events.push(.{ .tick_ended = {} });

        return result;
    }

    pub fn drawRandom(self: *World, id: random.RandomStreamID) !f32 {
        const r = self.random_provider.draw(id);
        try self.events.push(.{ .draw_random = .{ .stream = id, .result = r } });
        return r;
    }

    pub fn getRandomSource(self: *World, id: random.RandomStreamID) random.RandomSource {
        return .{
            .events = &self.events,
            .stream = self.random_impl.getStream(id),
            .stream_id = id,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CardRegistry: create and lookup" {
    const alloc = std.testing.allocator;
    var registry = try CardRegistry.init(alloc);
    defer registry.deinit();

    // Use a test template
    const template = card_list.BeginnerDeck[0];

    // Create instance
    const instance = try registry.create(template);
    try std.testing.expectEqual(template, instance.template);

    // Lookup by ID
    const found = registry.get(instance.id);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(instance, found.?);
}

test "CardRegistry: remove invalidates ID" {
    const alloc = std.testing.allocator;
    var registry = try CardRegistry.init(alloc);
    defer registry.deinit();

    const template = card_list.BeginnerDeck[0];
    const instance = try registry.create(template);
    const id = instance.id;

    // Remove (invalidates ID, memory freed on deinit)
    registry.remove(id);

    // Should not be found via get
    try std.testing.expect(registry.get(id) == null);
}
