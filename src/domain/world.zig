const std = @import("std");
const lib = @import("infra");
const zigfsm = @import("zigfsm");
const player = @import("player.zig");
const random = @import("random.zig");
const events = @import("events.zig");
const apply = @import("apply.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const stats = @import("stats.zig");
const combat = @import("combat.zig");
const body = @import("body.zig");
const tick = @import("tick.zig");
const weapon = @import("weapon.zig");

const EventSystem = events.EventSystem;
const CommandHandler = apply.CommandHandler;
const EventProcessor = apply.EventProcessor;
const Event = events.Event;
const SlotMap = @import("slot_map.zig").SlotMap;
const Deck = @import("deck.zig").Deck;
const BeginnerDeck = card_list.BeginnerDeck;
const TickResolver = tick.TickResolver;

const WorldError = error{
    InvalidStateTransition,
};

/// Central registry for all card instances. Containers (Agent, Encounter) hold IDs.
pub const CardRegistry = struct {
    alloc: std.mem.Allocator,
    entities: SlotMap(*cards.Instance),

    pub fn init(alloc: std.mem.Allocator) !CardRegistry {
        return .{
            .alloc = alloc,
            .entities = try SlotMap(*cards.Instance).init(alloc),
        };
    }

    pub fn deinit(self: *CardRegistry) void {
        // Free all instances
        for (self.entities.items.items) |instance| {
            self.alloc.destroy(instance);
        }
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

pub const GameEvent = enum {
    start_encounter,
    begin_player_card_selection,
    begin_commit_phase,
    begin_tick_resolution,
    // continue_tick_resolution,
    animate_resolution,
    redraw,
    show_loot,
    player_died,
};

// TODO move the encounter-specific bits into an encounter fsm ...
pub const GameState = enum {
    splash,
    draw_hand,
    player_card_selection, // choose cards in secret
    commit_phase, // reveal; vary or reinforce selections
    tick_resolution, //: resolve committed actions
    player_reaction,
    encounter_summary,
    animating,
};

pub const World = struct {
    alloc: std.mem.Allocator,
    events: EventSystem,
    encounter: ?combat.Encounter,
    random: random.RandomStreamDict,
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

        try fsm.addEventAndTransition(.start_encounter, .splash, .draw_hand);

        try fsm.addEventAndTransition(.begin_player_card_selection, .draw_hand, .player_card_selection);
        try fsm.addEventAndTransition(.begin_commit_phase, .player_card_selection, .commit_phase);
        try fsm.addEventAndTransition(.begin_tick_resolution, .commit_phase, .tick_resolution);
        // try fsm.addEventAndTransition(.player_reaction_opportunity, .tick_resolution, .player_reaction);
        // try fsm.addEventAndTransition(.continue_tick_resolution, .player_reaction, .tick_resolution);
        try fsm.addEventAndTransition(.animate_resolution, .tick_resolution, .animating);
        // try fsm.addEventAndTransition(.continue_tick_resolution, .animating, .tick_resolution);

        try fsm.addEventAndTransition(.player_died, .animating, .splash);
        try fsm.addEventAndTransition(.show_loot, .animating, .encounter_summary);
        try fsm.addEventAndTransition(.redraw, .animating, .draw_hand);

        const playerStats = stats.Block.splat(5);
        const playerBody = try body.Body.fromPlan(alloc, &body.HumanoidPlan);

        const self = try alloc.create(World);

        self.* = .{
            .alloc = alloc,
            .events = try EventSystem.init(alloc),
            .encounter = null, // created after player
            .random = random.RandomStreamDict.init(),
            .entities = try EntityMap.init(alloc),
            .card_registry = try CardRegistry.init(alloc),
            .player = undefined, // set after entities exist
            .fsm = fsm,
            .tickResolver = try TickResolver.init(alloc),
            .eventProcessor = undefined,
            .commandHandler = undefined,
        };

        // Create player deck using card_registry (new system)
        var playerDeck = try Deck.initWithRegistry(alloc, &self.card_registry, &BeginnerDeck);
        self.player = try player.newPlayer(alloc, self, playerDeck, playerStats, playerBody);

        // Populate deck_cards from the deck (for new card storage system)
        try playerDeck.copyCardIdsTo(alloc, &self.player.deck_cards);
        self.encounter = try combat.Encounter.init(alloc, self.player.id);
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
        if (self.encounter) |*encounter| {
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

    /// Process a complete tick: commit actions, resolve, cleanup
    pub fn processTick(self: *World) !tick.TickResult {
        // Reset resolver for new tick
        self.tickResolver.reset();

        // Commit player cards (using plays from AgentEncounterState)
        try self.tickResolver.commitPlayerCards(self.player, self);

        // Commit mob actions
        if (self.encounter) |*enc| {
            try self.tickResolver.commitMobActions(enc.enemies.items, self);
        }

        // Resolve all actions
        const result = try self.tickResolver.resolve(self);

        // Cleanup: apply costs, move cards
        try apply.applyCommittedCosts(self.tickResolver.committed.items, &self.events);

        // Emit tick ended event
        try self.events.push(.{ .tick_ended = {} });

        return result;
    }

    pub fn drawRandom(self: *World, id: random.RandomStreamID) !f32 {
        const r = self.random.get(id).random().float(f32);
        try self.events.push(.{ .draw_random = .{ .stream = id, .result = r } });
        return r;
    }

    pub fn getRandomSource(self: *World, id: random.RandomStreamID) random.RandomSource {
        return .{
            .events = &self.events,
            .stream = self.random.get(id),
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
    const template = &card_list.BeginnerDeck[0];

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

    const template = &card_list.BeginnerDeck[0];
    const instance = try registry.create(template);
    const id = instance.id;

    // Remove (invalidates ID, memory freed on deinit)
    registry.remove(id);

    // Should not be found via get
    try std.testing.expect(registry.get(id) == null);
}
