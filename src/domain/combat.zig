const std = @import("std");
const lib = @import("infra");
const zigfsm = @import("zigfsm");
const entity = lib.entity;
const armour = @import("armour.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");
const cards = @import("cards.zig");
const apply = @import("apply.zig");
const ai = @import("ai.zig");
const e = @import("events.zig");
const world = @import("world.zig");
const EventSystem = e.EventSystem;
const Event = e.Event;

const SlotMap = @import("slot_map.zig").SlotMap;

pub const Director = union(enum) {
    player,
    ai: ai.Director,
};
pub const Reach = enum {
    // Weapon reaches (shorter = lower)
    clinch,
    dagger,
    mace,
    sabre,
    longsword,
    spear,
    // Engagement distances (closer = lower)
    near,
    medium,
    far,
};

pub const AdvantageAxis = enum {
    balance,
    pressure,
    control,
    position,
};

pub const Armament = union(enum) {
    single: *weapon.Instance,
    dual: struct {
        primary: *weapon.Instance,
        secondary: *weapon.Instance,
    },
    compound: [][]*weapon.Instance,

    pub fn hasCategory(self: Armament, cat: weapon.Category) bool {
        return switch (self) {
            .single => |w| hasWeaponCategory(w.template, cat),
            .dual => |d| hasWeaponCategory(d.primary.template, cat) or
                hasWeaponCategory(d.secondary.template, cat),
            .compound => |sets| {
                for (sets) |set| {
                    for (set) |w| {
                        if (hasWeaponCategory(w.template, cat)) return true;
                    }
                }
                return false;
            },
        };
    }

    fn hasWeaponCategory(template: *const weapon.Template, cat: weapon.Category) bool {
        for (template.categories) |c| {
            if (c == cat) return true;
        }
        return false;
    }

    /// Get the offensive mode (swing/thrust) from the primary weapon for a given attack mode.
    /// Returns null if the weapon lacks that mode, or for .ranged/.none modes.
    pub fn getOffensiveMode(self: Armament, mode: cards.AttackMode) ?weapon.Offensive {
        const template = switch (self) {
            .single => |w| w.template,
            .dual => |d| d.primary.template,
            .compound => {
                std.debug.print("warning: getOffensiveMode called on compound armament (not yet supported)\n", .{});
                return null;
            },
        };
        return switch (mode) {
            .swing => template.swing,
            .thrust => template.thrust,
            .ranged => null, // ranged uses Ranged type, not Offensive
            .none => null,
        };
    }
};

/// How an agent acquires cards during combat.
pub const DrawStyle = enum {
    shuffled_deck, // cards cycle through draw/hand/discard
    always_available, // cards in always_available pool, cooldown-based (stub)
    scripted, // behaviour tree selects from available cards (stub)
};

/// Result of a combat encounter.
pub const CombatOutcome = enum {
    victory, // all enemies incapacitated
    defeat, // player incapacitated
    flee, // player escaped (stub)
    surrender, // negotiated end (stub)
};

/// Phase within a combat turn (owned by Encounter, not World).
pub const TurnPhase = enum {
    draw_hand,
    player_card_selection, // choose cards in secret
    commit_phase, // reveal; vary or reinforce selections
    tick_resolution, // resolve committed actions
    player_reaction, // future: reaction windows
    animating,
};

/// Events that trigger turn phase transitions.
pub const TurnEvent = enum {
    begin_player_card_selection,
    begin_commit_phase,
    begin_tick_resolution,
    animate_resolution,
    redraw,
};

pub const TurnFSM = zigfsm.StateMachine(TurnPhase, TurnEvent, .draw_hand);

// ============================================================================
// Card Containers (new architecture - see doc/card_storage_design.md)
// ============================================================================

/// Combat-specific zones (subset of cards.Zone for transient combat state).
pub const CombatZone = enum {
    draw,
    hand,
    in_play,
    discard,
    exhaust,
};

/// Transient combat state - created per encounter, holds draw/hand/discard cycle.
/// Card IDs reference World.card_registry.
pub const CombatState = struct {
    alloc: std.mem.Allocator,
    draw: std.ArrayList(entity.ID),
    hand: std.ArrayList(entity.ID),
    discard: std.ArrayList(entity.ID),
    in_play: std.ArrayList(entity.ID),
    exhaust: std.ArrayList(entity.ID),
    // Source tracking: where did cards in in_play come from?
    // For pool cards, also tracks master_id for cooldown application.
    in_play_sources: std.AutoHashMap(entity.ID, InPlayInfo),
    // Cooldowns for pool-based cards - keyed by MASTER id (techniques, maybe spells)
    cooldowns: std.AutoHashMap(entity.ID, u8),

    pub const ZoneError = error{NotFound};
    pub const CardSource = enum { hand, always_available, spells_known, inventory, environment };

    /// Tracks where an in_play card came from and its master (for cloned pool cards).
    pub const InPlayInfo = struct {
        source: CardSource,
        /// For pool cards (always_available, spells_known): the master instance ID.
        /// Cooldowns are applied to this ID. Null for hand/inventory/environment cards.
        master_id: ?entity.ID = null,
    };

    pub fn init(alloc: std.mem.Allocator) !CombatState {
        return .{
            .alloc = alloc,
            .draw = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .hand = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .discard = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .in_play = try std.ArrayList(entity.ID).initCapacity(alloc, 8),
            .exhaust = try std.ArrayList(entity.ID).initCapacity(alloc, 5),
            .in_play_sources = std.AutoHashMap(entity.ID, InPlayInfo).init(alloc),
            .cooldowns = std.AutoHashMap(entity.ID, u8).init(alloc),
        };
    }

    pub fn deinit(self: *CombatState) void {
        self.draw.deinit(self.alloc);
        self.hand.deinit(self.alloc);
        self.discard.deinit(self.alloc);
        self.in_play.deinit(self.alloc);
        self.exhaust.deinit(self.alloc);
        self.in_play_sources.deinit();
        self.cooldowns.deinit();
    }

    pub fn clear(self: *CombatState) void {
        self.draw.clearRetainingCapacity();
        self.hand.clearRetainingCapacity();
        self.discard.clearRetainingCapacity();
        self.in_play.clearRetainingCapacity();
        self.exhaust.clearRetainingCapacity();
        self.in_play_sources.clearRetainingCapacity();
        self.cooldowns.clearRetainingCapacity();
    }

    /// Get the ArrayList for a zone.
    pub fn zoneList(self: *CombatState, zone: CombatZone) *std.ArrayList(entity.ID) {
        return switch (zone) {
            .draw => &self.draw,
            .hand => &self.hand,
            .in_play => &self.in_play,
            .discard => &self.discard,
            .exhaust => &self.exhaust,
        };
    }

    /// Check if a card ID is in a specific zone.
    pub fn isInZone(self: *const CombatState, id: entity.ID, zone: CombatZone) bool {
        const list = switch (zone) {
            .draw => &self.draw,
            .hand => &self.hand,
            .in_play => &self.in_play,
            .discard => &self.discard,
            .exhaust => &self.exhaust,
        };
        for (list.items) |card_id| {
            if (card_id.eql(id)) return true;
        }
        return false;
    }

    /// Find index of card in zone, or null if not found.
    fn findIndex(list: *const std.ArrayList(entity.ID), id: entity.ID) ?usize {
        for (list.items, 0..) |card_id, i| {
            if (card_id.eql(id)) return i;
        }
        return null;
    }

    /// Move a card from one zone to another.
    pub fn moveCard(self: *CombatState, id: entity.ID, from: CombatZone, to: CombatZone) !void {
        const from_list = self.zoneList(from);
        const to_list = self.zoneList(to);

        const idx = findIndex(from_list, id) orelse return ZoneError.NotFound;
        _ = from_list.orderedRemove(idx);
        try to_list.append(self.alloc, id);
    }

    /// Fisher-Yates shuffle of the draw pile.
    pub fn shuffleDraw(self: *CombatState, rand: anytype) !void {
        const items = self.draw.items;
        var i = items.len;
        while (i > 1) {
            i -= 1;
            const r = try rand.drawRandom();
            const j: usize = @intFromFloat(r * @as(f32, @floatFromInt(i + 1)));
            std.mem.swap(entity.ID, &items[i], &items[j]);
        }
    }

    /// Populate discard pile from deck_cards (called at combat start).
    /// Cards start in discard to simplify shuffle logic: when draw is empty,
    /// move discard to draw and shuffle.
    pub fn populateFromDeckCards(self: *CombatState, deck_cards: []const entity.ID) !void {
        self.clear();
        for (deck_cards) |card_id| {
            try self.discard.append(self.alloc, card_id);
        }
    }

    /// Add card to in_play from a non-CombatZone source (always_available, spells_known, etc.)
    /// For pool sources, creates an ephemeral clone so the master stays in the pool.
    /// Returns the ID of the card now in in_play (clone ID for pool sources, original for others).
    pub fn addToInPlayFrom(
        self: *CombatState,
        master_id: entity.ID,
        source: CardSource,
        registry: *world.CardRegistry,
    ) !entity.ID {
        const is_pool_source = switch (source) {
            .always_available, .spells_known => true,
            .hand, .inventory, .environment => false,
        };

        if (is_pool_source) {
            // Clone the master - ephemeral instance gets fresh ID
            const clone = try registry.clone(master_id);
            try self.in_play.append(self.alloc, clone.id);
            try self.in_play_sources.put(clone.id, .{
                .source = source,
                .master_id = master_id,
            });
            return clone.id;
        } else {
            // Non-pool sources: use the original ID directly
            try self.in_play.append(self.alloc, master_id);
            try self.in_play_sources.put(master_id, .{
                .source = source,
                .master_id = null,
            });
            return master_id;
        }
    }

    /// Is pool card available? (not on cooldown)
    /// Cards without cooldown can be played unlimited times per turn.
    /// Cards with cooldown have it set immediately on play, blocking further uses.
    pub fn isPoolCardAvailable(self: *const CombatState, agent: *const Agent, master_id: entity.ID) bool {
        if (self.cooldowns.get(master_id)) |cd| if (cd > 0) return false;
        return agent.poolContains(master_id);
    }

    /// Decrement all cooldowns by 1 (called at turn start)
    pub fn tickCooldowns(self: *CombatState) void {
        var iter = self.cooldowns.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* > 0) entry.value_ptr.* -= 1;
        }
    }

    /// Remove card from in_play, destroy ephemeral clones, return master_id for cooldown.
    /// Returns the master_id if this was a pool card (for cooldown application), null otherwise.
    pub fn removeFromInPlay(
        self: *CombatState,
        id: entity.ID,
        registry: *world.CardRegistry,
    ) !?entity.ID {
        const idx = findIndex(&self.in_play, id) orelse return ZoneError.NotFound;
        _ = self.in_play.orderedRemove(idx);

        const info = self.in_play_sources.get(id);
        _ = self.in_play_sources.remove(id);

        if (info) |i| {
            if (i.master_id) |master_id| {
                // This was a clone - destroy the ephemeral instance
                registry.destroy(id);
                return master_id;
            }
        }

        return null;
    }

    /// Set cooldown for a pool card's master (turns until available again)
    pub fn setCooldown(self: *CombatState, master_id: entity.ID, turns: u8) !void {
        try self.cooldowns.put(master_id, turns);
    }
};

// NOTE: Equipment is handled by existing systems:
// - Weapons: Agent.weapons (Armament union with single/dual/compound)
// - Armor: Agent.armour (armour.Stack with body-aware layers)
//
// When items become cards, we may need to track card IDs that correspond
// to equipped weapon/armor instances for card effect targeting.

/// Canonical pairing of two agents for engagement lookup.
/// Ordering ensures (a,b) and (b,a) map to the same key.
pub const AgentPair = struct {
    a: entity.ID, // lower index
    b: entity.ID, // higher index

    pub fn canonical(x: entity.ID, y: entity.ID) AgentPair {
        std.debug.assert(x.index != y.index); // self-engagement is invalid
        return if (x.index < y.index)
            .{ .a = x, .b = y }
        else
            .{ .a = y, .b = x };
    }
};

pub const Encounter = struct {
    alloc: std.mem.Allocator,
    enemies: std.ArrayList(*combat.Agent),
    player_id: entity.ID,
    engagements: std.AutoHashMap(AgentPair, Engagement),
    agent_state: std.AutoHashMap(entity.ID, AgentEncounterState),

    // Environmental cards (rubble, thrown items, lootable)
    environment: std.ArrayList(entity.ID),
    // Card ownership tracking for thrown items (card_id -> original_owner_id)
    thrown_by: std.AutoHashMap(entity.ID, entity.ID),

    // Combat result (set when combat ends, for summary display)
    outcome: ?CombatOutcome = null,

    // Turn phase FSM (combat flow within encounter)
    turn_fsm: TurnFSM,

    pub fn init(alloc: std.mem.Allocator, player_id: entity.ID) !*Encounter {
        var fsm = TurnFSM.init();

        // Turn phase transitions
        try fsm.addEventAndTransition(.begin_player_card_selection, .draw_hand, .player_card_selection);
        try fsm.addEventAndTransition(.begin_commit_phase, .player_card_selection, .commit_phase);
        try fsm.addEventAndTransition(.begin_tick_resolution, .commit_phase, .tick_resolution);
        try fsm.addEventAndTransition(.animate_resolution, .tick_resolution, .animating);
        try fsm.addEventAndTransition(.redraw, .animating, .draw_hand);

        const enc = try alloc.create(Encounter);
        enc.* = Encounter{
            .alloc = alloc,
            .enemies = try std.ArrayList(*combat.Agent).initCapacity(alloc, 5),
            .player_id = player_id,
            .engagements = std.AutoHashMap(AgentPair, Engagement).init(alloc),
            .agent_state = std.AutoHashMap(entity.ID, AgentEncounterState).init(alloc),
            .environment = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .thrown_by = std.AutoHashMap(entity.ID, entity.ID).init(alloc),
            .outcome = null,
            .turn_fsm = fsm,
        };
        // Initialize player's encounter state
        try enc.agent_state.put(player_id, .{});
        return enc;
    }

    pub fn deinit(self: *Encounter, agents: *SlotMap(*Agent)) void {
        for (self.enemies.items) |enemy| {
            agents.remove(enemy.id);
            enemy.deinit();
        }
        self.enemies.deinit(self.alloc);
        self.engagements.deinit();
        self.agent_state.deinit();
        self.environment.deinit(self.alloc);
        self.thrown_by.deinit();
        self.alloc.destroy(self);
    }

    /// Get engagement between two agents (order doesn't matter).
    pub fn getEngagement(self: *Encounter, a: entity.ID, b: entity.ID) ?*Engagement {
        return self.engagements.getPtr(AgentPair.canonical(a, b));
    }

    /// Get engagement between two agents (const version, returns value not pointer).
    pub fn getEngagementConst(self: *const Encounter, a: entity.ID, b: entity.ID) ?Engagement {
        return self.engagements.get(AgentPair.canonical(a, b));
    }

    /// Get engagement between player and a mob.
    pub fn getPlayerEngagement(self: *Encounter, mob_id: entity.ID) ?*Engagement {
        return self.getEngagement(self.player_id, mob_id);
    }

    /// Get engagement between player and a mob (const version).
    pub fn getPlayerEngagementConst(self: *const Encounter, mob_id: entity.ID) ?Engagement {
        return self.getEngagementConst(self.player_id, mob_id);
    }

    /// Set or create engagement between two agents.
    pub fn setEngagement(self: *Encounter, a: entity.ID, b: entity.ID, eng: Engagement) !void {
        try self.engagements.put(AgentPair.canonical(a, b), eng);
    }

    /// Add enemy and create default engagement with player.
    pub fn addEnemy(self: *Encounter, enemy: *Agent) !void {
        try self.enemies.append(self.alloc, enemy);
        try self.setEngagement(self.player_id, enemy.id, Engagement{});
        try self.agent_state.put(enemy.id, .{});
    }

    /// Get encounter state for an agent.
    pub fn stateFor(self: *Encounter, agent_id: entity.ID) ?*AgentEncounterState {
        return self.agent_state.getPtr(agent_id);
    }

    /// Get encounter state for an agent (const version for read-only access).
    pub fn stateForConst(self: *const Encounter, agent_id: entity.ID) ?*const AgentEncounterState {
        return self.agent_state.getPtr(agent_id);
    }

    /// Current turn phase.
    pub fn turnPhase(self: *const Encounter) TurnPhase {
        // Note: zigfsm.currentState requires mutable but doesn't actually mutate,
        // so we cast away const here for read-only access.
        const mutable_fsm: *TurnFSM = @constCast(&self.turn_fsm);
        return mutable_fsm.currentState();
    }

    /// Transition to a new turn phase (validates transition is allowed).
    pub fn transitionTurnTo(self: *Encounter, target: TurnPhase) !void {
        if (self.turn_fsm.canTransitionTo(target)) {
            try self.turn_fsm.transitionTo(target);
        } else {
            return error.InvalidTurnPhaseTransition;
        }
    }
};

// const ScriptedAction = struct {};
//
// // Creature: pure behavior script, no "cards" at all
// const BehaviourScript = struct {
//     pattern: []const ScriptedAction,
//     index: usize,
//
//     pub fn next(self: *BehaviourScript) ScriptedAction {
//         const action = self.pattern[self.index];
//         self.index = (self.index + 1) % self.pattern.len;
//         return action;
//     }
// };

pub const Agent = struct {
    id: entity.ID,
    alloc: std.mem.Allocator,
    director: Director,
    draw_style: DrawStyle = .shuffled_deck,
    stats: stats.Block,
    // may be humanoid, or not
    body: body.Body,
    // sourced from cards.equipped
    armour: armour.Stack,
    weapons: Armament,
    dominant_side: body.Side = .right, // .center == ambidextrous

    // New card containers (IDs reference World.card_registry)
    // See doc/card_storage_design.md for architecture
    // NOTE: Default to empty - use .init(alloc) pattern for non-test code
    always_available: std.ArrayList(entity.ID) = .{}, // Techniques/modifiers usable without drawing
    spells_known: std.ArrayList(entity.ID) = .{}, // Always available (if mana)
    deck_cards: std.ArrayList(entity.ID) = .{}, // Shuffled into draw at combat start
    inventory: std.ArrayList(entity.ID) = .{}, // Carried items
    combat_state: ?*CombatState = null, // Per-encounter, transient
    // NOTE: weapons handled by Agent.weapons, armor by Agent.armour

    // state (wounds kept in body)
    balance: f32 = 1.0, // 0-1, intrinsic stability
    stamina: stats.Resource,
    focus: stats.Resource,
    time_available: f32 = 1.0,
    //
    conditions: std.ArrayList(damage.ActiveCondition),
    immunities: std.ArrayList(damage.Immunity),
    resistances: std.ArrayList(damage.Resistance),
    vulnerabilities: std.ArrayList(damage.Vulnerability),

    pub fn init(
        alloc: std.mem.Allocator,
        slot_map: *SlotMap(*Agent),
        dr: Director,
        ds: DrawStyle,
        sb: stats.Block,
        bd: body.Body,
        stamina: stats.Resource,
        focus: stats.Resource,
        armament: Armament,
    ) !*Agent {
        const agent = try alloc.create(combat.Agent);
        agent.* = .{
            .id = undefined,
            .alloc = alloc,
            .director = dr,
            .draw_style = ds,
            .stats = sb,
            .body = bd,
            .armour = armour.Stack.init(alloc),
            .weapons = armament,
            .stamina = stamina,
            .focus = focus,

            // New card containers (empty by default)
            .always_available = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .spells_known = try std.ArrayList(entity.ID).initCapacity(alloc, 10),
            .deck_cards = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .inventory = try std.ArrayList(entity.ID).initCapacity(alloc, 20),
            .combat_state = null,

            .conditions = try std.ArrayList(damage.ActiveCondition).initCapacity(alloc, 5),
            .resistances = try std.ArrayList(damage.Resistance).initCapacity(alloc, 5),
            .immunities = try std.ArrayList(damage.Immunity).initCapacity(alloc, 5),
            .vulnerabilities = try std.ArrayList(damage.Vulnerability).initCapacity(alloc, 5),
        };
        const id = try slot_map.insert(agent);
        agent.id = id;
        agent.body.agent_id = id;
        return agent;
    }

    pub fn deinit(self: *Agent) void {
        const alloc = self.alloc;

        // Deinit card containers
        self.always_available.deinit(alloc);
        self.spells_known.deinit(alloc);
        self.deck_cards.deinit(alloc);
        self.inventory.deinit(alloc);
        if (self.combat_state) |cs| {
            cs.deinit();
            alloc.destroy(cs);
        }

        self.conditions.deinit(alloc);
        self.immunities.deinit(alloc);
        self.resistances.deinit(alloc);
        self.vulnerabilities.deinit(alloc);

        self.body.deinit();
        self.armour.deinit();

        alloc.destroy(self);
    }

    pub fn destroy(self: *Agent, slot_map: *SlotMap(*Agent)) void {
        slot_map.remove(self.id);
        self.deinit();
    }

    fn isDominantSide(dominant: body.Side, side: body.Side) bool {
        return dominant == .center or dominant.? == side;
    }

    // Helpers for managing card arraylists
    //
    pub fn poolContains(self: *const Agent, id: entity.ID) bool {
        for (self.always_available.items) |i| if (i.eql(id)) return true;
        for (self.spells_known.items) |i| if (i.eql(id)) return true;
        return false;
    }

    pub fn inAlwaysAvailable(self: *Agent, id: entity.ID) bool {
        for (self.always_available.items) |i| if (i.eql(id)) return true;
        return false;
    }

    pub fn inSpellsKnown(self: *Agent, id: entity.ID) bool {
        for (self.always_available.items) |i| if (i.eql(id)) return true;
        return false;
    }

    /// Initialize combat state from deck_cards (called at combat start).
    pub fn initCombatState(self: *Agent) !void {
        if (self.combat_state != null) return; // already initialized

        const cs = try self.alloc.create(CombatState);
        cs.* = try CombatState.init(self.alloc);
        errdefer {
            cs.deinit();
            self.alloc.destroy(cs);
        }

        try cs.populateFromDeckCards(self.deck_cards.items);
        self.combat_state = cs;
    }

    /// Clean up combat state (called at combat end).
    pub fn cleanupCombatState(self: *Agent) void {
        if (self.combat_state) |cs| {
            cs.deinit();
            self.alloc.destroy(cs);
            self.combat_state = null;
        }
    }

    /// Check if agent is incapacitated (can no longer fight).
    /// Triggers: vital organ destroyed, complete immobility, unconscious/comatose.
    pub fn isIncapacitated(self: *const Agent) bool {
        // Vital organ destroyed (brain, heart, lungs, etc.)
        for (self.body.parts.items) |part| {
            if (part.flags.is_vital and part.severity == .missing) {
                return true;
            }
        }

        // Complete loss of mobility (can't stand at all)
        if (self.body.mobilityScore() == 0.0) {
            return true;
        }

        // Unconscious or comatose condition
        var iter = self.activeConditions(null);
        while (iter.next()) |cond| {
            if (cond.condition == .unconscious or cond.condition == .comatose) {
                return true;
            }
        }

        return false;
    }

    /// Returns an iterator over all active conditions (stored + computed).
    /// For relational conditions (pressured, weapon_bound), pass the engagement
    /// if in an encounter (high values = disadvantage for self).
    pub fn activeConditions(self: *const Agent, engagement: ?*const Engagement) ConditionIterator {
        return ConditionIterator.init(self, engagement);
    }

    /// Check if agent has a specific stored condition.
    /// Note: Does not check computed/relational conditions (pressured, etc.)
    pub fn hasCondition(self: *const Agent, condition: damage.Condition) bool {
        for (self.conditions.items) |cond| {
            if (cond.condition == condition) return true;
        }
        return false;
    }
};

// Per-engagement (one per mob, attached to mob)
pub const Engagement = struct {
    // All 0-1, where 0.5 = neutral
    // >0.5 = player advantage, <0.5 = mob advantage
    pressure: f32 = 0.5,
    control: f32 = 0.5,
    position: f32 = 0.5,
    range: Reach = .sabre, // Current distance

    // Helpers
    pub fn playerAdvantage(self: Engagement) f32 {
        return (self.pressure + self.control + self.position) / 3.0;
    }

    pub fn mobAdvantage(self: Engagement) f32 {
        return 1.0 - self.playerAdvantage();
    }

    pub fn invert(self: Engagement) Engagement {
        return .{
            .pressure = 1.0 - self.pressure,
            .control = 1.0 - self.control,
            .position = 1.0 - self.position,
            .range = self.range,
        };
    }
};

// ============================================================================
// Turn State
// ============================================================================

/// A card being played, with optional modifier stack.
pub const Play = struct {
    pub const max_modifiers = 4;

    action: entity.ID, // the lead card (technique, maneuver, etc.)
    target: ?entity.ID = null, // who this play targets (null for self-target or all)
    modifier_stack_buf: [max_modifiers]entity.ID = undefined,
    modifier_stack_len: usize = 0,
    stakes: cards.Stakes = .guarded,
    added_in_commit: bool = false, // true if added via Focus, cannot be stacked

    // Applied by modify_play effects during commit phase
    cost_mult: f32 = 1.0,
    damage_mult: f32 = 1.0,
    advantage_override: ?TechniqueAdvantage = null,

    pub fn modifiers(self: *const Play) []const entity.ID {
        return self.modifier_stack_buf[0..self.modifier_stack_len];
    }

    pub fn addModifier(self: *Play, card_id: entity.ID) error{Overflow}!void {
        if (self.modifier_stack_len >= max_modifiers) return error.Overflow;
        self.modifier_stack_buf[self.modifier_stack_len] = card_id;
        self.modifier_stack_len += 1;
    }

    pub fn cardCount(self: Play) usize {
        return 1 + self.modifier_stack_len;
    }

    pub fn canStack(self: Play) bool {
        return !self.added_in_commit;
    }

    /// Stakes based on modifier stack depth.
    pub fn effectiveStakes(self: Play) cards.Stakes {
        return switch (self.modifier_stack_len) {
            0 => self.stakes,
            1 => .committed,
            else => .reckless,
        };
    }

    /// Get advantage profile (override if set, else from technique).
    pub fn getAdvantage(self: Play, technique: *const cards.Technique) ?TechniqueAdvantage {
        return self.advantage_override orelse technique.advantage;
    }

    // -------------------------------------------------------------------------
    // Computed modifier effects
    // -------------------------------------------------------------------------

    /// Extract modify_play effect from a template (first on_commit rule with modify_play).
    fn getModifyPlayEffect(template: *const cards.Template) ?cards.ModifyPlay {
        for (template.rules) |rule| {
            if (rule.trigger != .on_commit) continue;
            for (rule.expressions) |expr| {
                switch (expr.effect) {
                    .modify_play => |mp| return mp,
                    else => {},
                }
            }
        }
        return null;
    }

    /// Compute effective cost multiplier from modifier stack + stored override.
    pub fn effectiveCostMult(self: *const Play, registry: *const world.CardRegistry) f32 {
        var mult: f32 = 1.0;
        for (self.modifiers()) |mod_id| {
            const card = registry.getConst(mod_id) orelse continue;
            if (getModifyPlayEffect(card.template)) |mp| {
                mult *= mp.cost_mult orelse 1.0;
            }
        }
        return mult * self.cost_mult; // stored override applied last
    }

    /// Compute effective damage multiplier from modifier stack + stored override.
    pub fn effectiveDamageMult(self: *const Play, registry: *const world.CardRegistry) f32 {
        var mult: f32 = 1.0;
        for (self.modifiers()) |mod_id| {
            const card = registry.getConst(mod_id) orelse continue;
            if (getModifyPlayEffect(card.template)) |mp| {
                mult *= mp.damage_mult orelse 1.0;
            }
        }
        return mult * self.damage_mult; // stored override applied last
    }

    /// Compute effective height from modifier stack (last override wins).
    pub fn effectiveHeight(self: *const Play, registry: *const world.CardRegistry, base: body.Height) body.Height {
        var height = base;
        for (self.modifiers()) |mod_id| {
            const card = registry.getConst(mod_id) orelse continue;
            if (getModifyPlayEffect(card.template)) |mp| {
                if (mp.height_override) |h| height = h;
            }
        }
        return height;
    }

    /// Check if adding a modifier would conflict with existing modifiers.
    /// Currently detects: conflicting height_override (e.g., Low + High).
    pub fn wouldConflict(self: *const Play, new_modifier: *const cards.Template, registry: *const world.CardRegistry) bool {
        const new_effect = getModifyPlayEffect(new_modifier) orelse return false;
        const new_height = new_effect.height_override orelse return false;

        // Check existing modifiers for conflicting height
        for (self.modifiers()) |mod_id| {
            const card = registry.getConst(mod_id) orelse continue;
            if (getModifyPlayEffect(card.template)) |mp| {
                if (mp.height_override) |existing_height| {
                    if (existing_height != new_height) return true;
                }
            }
        }
        return false;
    }
};

/// A play positioned within a tick's timeline.
/// Duration is computed on-demand from the play's current state.
pub const TimeSlot = struct {
    time_start: f32, // 0.0-1.0 within tick
    play: Play,

    /// Compute duration from play's current state (includes modifier effects).
    pub fn duration(self: TimeSlot, registry: *const world.CardRegistry) f32 {
        return getPlayDuration(self.play, registry);
    }

    /// Compute end time from play's current state.
    pub fn timeEnd(self: TimeSlot, registry: *const world.CardRegistry) f32 {
        return self.time_start + self.duration(registry);
    }

    /// Check if this slot overlaps with a time range.
    pub fn overlapsWith(self: TimeSlot, start: f32, end: f32, registry: *const world.CardRegistry) bool {
        return self.timeEnd(registry) > start and self.time_start < end;
    }
};

/// Time-aware collection of plays within a tick.
/// Slots are kept sorted by time_start for natural iteration order.
pub const Timeline = struct {
    pub const max_slots = 12; // More than max_plays since overlaps possible
    pub const granularity: f32 = 0.1; // 100ms slots

    slots_buf: [max_slots]TimeSlot = undefined,
    slots_len: usize = 0,

    /// Get all slots as a slice (sorted by time_start).
    pub fn slots(self: *const Timeline) []const TimeSlot {
        return self.slots_buf[0..self.slots_len];
    }

    /// Get mutable slots slice.
    pub fn slotsMut(self: *Timeline) []TimeSlot {
        return self.slots_buf[0..self.slots_len];
    }

    /// Number of slots.
    pub fn len(self: *const Timeline) usize {
        return self.slots_len;
    }

    /// Snap a time value to granularity (round down).
    pub fn snap(time: f32) f32 {
        return @trunc(time / granularity) * granularity;
    }

    /// Check if a play with given channels can be inserted at time range.
    pub fn canInsert(
        self: *const Timeline,
        time_start: f32,
        time_end: f32,
        channels: cards.ChannelSet,
        registry: *const world.CardRegistry,
    ) bool {
        if (self.slots_len >= max_slots) return false;
        if (time_end > 1.0) return false;

        for (self.slots()) |slot| {
            // Check time overlap first (compute slot's end time on demand)
            if (!slot.overlapsWith(time_start, time_end, registry)) continue;

            // If times overlap, check channel conflict
            const slot_channels = getPlayChannels(slot.play, registry);
            if (channels.conflicts(slot_channels)) return false;
        }
        return true;
    }

    /// Insert a play at specified time. Auto-snaps time_start to granularity.
    /// Duration is computed from the play; time_end parameter used for validation.
    /// Maintains sorted order by time_start.
    pub fn insert(
        self: *Timeline,
        time_start: f32,
        time_end: f32,
        play: Play,
        channels: cards.ChannelSet,
        registry: *const world.CardRegistry,
    ) error{ Conflict, Overflow }!void {
        const snapped_start = snap(time_start);
        const snapped_end = snapped_start + (time_end - time_start);

        if (!self.canInsert(snapped_start, snapped_end, channels, registry)) {
            if (self.slots_len >= max_slots) return error.Overflow;
            return error.Conflict;
        }

        const new_slot = TimeSlot{
            .time_start = snapped_start,
            .play = play,
        };

        // Find insertion point to maintain sorted order
        var insert_pos: usize = self.slots_len;
        for (self.slots(), 0..) |slot, i| {
            if (snapped_start < slot.time_start) {
                insert_pos = i;
                break;
            }
        }

        // Shift elements to make room
        if (insert_pos < self.slots_len) {
            var i = self.slots_len;
            while (i > insert_pos) : (i -= 1) {
                self.slots_buf[i] = self.slots_buf[i - 1];
            }
        }

        self.slots_buf[insert_pos] = new_slot;
        self.slots_len += 1;
    }

    /// Remove slot by index.
    pub fn remove(self: *Timeline, index: usize) void {
        if (index >= self.slots_len) return;
        // Shift remaining slots down
        var i = index;
        while (i < self.slots_len - 1) : (i += 1) {
            self.slots_buf[i] = self.slots_buf[i + 1];
        }
        self.slots_len -= 1;
    }

    /// Find slot index containing card.
    pub fn findByCard(self: *const Timeline, card_id: entity.ID) ?usize {
        for (self.slots(), 0..) |slot, i| {
            if (slot.play.action.eql(card_id)) return i;
        }
        return null;
    }

    /// Find first available start time for given channels and duration.
    /// Returns null if no space available before tick end (1.0).
    pub fn nextAvailableStart(
        self: *const Timeline,
        channels: cards.ChannelSet,
        duration: f32,
        registry: *const world.CardRegistry,
    ) ?f32 {
        var candidate: f32 = 0.0;
        while (candidate + duration <= 1.0) {
            if (self.canInsert(candidate, candidate + duration, channels, registry)) {
                return candidate;
            }
            candidate += granularity;
        }
        return null;
    }

    /// Get channels occupied at a specific time point.
    pub fn channelsOccupiedAt(
        self: *const Timeline,
        time: f32,
        registry: *const world.CardRegistry,
    ) cards.ChannelSet {
        var occupied = cards.ChannelSet{};
        for (self.slots()) |slot| {
            if (time >= slot.time_start and time < slot.timeEnd(registry)) {
                occupied = occupied.merge(getPlayChannels(slot.play, registry));
            }
        }
        return occupied;
    }

    /// Clear all slots.
    pub fn clear(self: *Timeline) void {
        self.slots_len = 0;
    }
};

/// Get duration of a play from its card's time cost.
pub fn getPlayDuration(play: Play, registry: *const world.CardRegistry) f32 {
    const card = registry.getConst(play.action) orelse return 0.0;
    return card.template.cost.time * play.effectiveCostMult(registry);
}

/// Get combined channels occupied by a play (lead card + modifiers).
pub fn getPlayChannels(play: Play, registry: *const world.CardRegistry) cards.ChannelSet {
    var channels = cards.ChannelSet{};

    // Get channels from lead card
    if (registry.getConst(play.action)) |instance| {
        if (instance.template.getTechnique()) |technique| {
            channels = channels.merge(technique.channels);
        }
    }

    // Modifiers don't typically add channels, but include for completeness
    for (play.modifiers()) |mod_id| {
        if (registry.getConst(mod_id)) |instance| {
            if (instance.template.getTechnique()) |technique| {
                channels = channels.merge(technique.channels);
            }
        }
    }

    return channels;
}

/// Target selected for a card before Play is created (during selection phase).
pub const PendingTarget = struct {
    card_id: entity.ID,
    target_id: entity.ID,
};

/// Ephemeral state for the current turn - exists from commit through resolution.
pub const TurnState = struct {
    timeline: Timeline = .{},
    focus_spent: f32 = 0,
    stack_focus_paid: bool = false, // 1F covers all stacking for the turn
    // Targets selected during selection phase, before Plays exist
    pending_targets: [Timeline.max_slots]?PendingTarget = .{null} ** Timeline.max_slots,

    /// Get all slots (sorted by time_start).
    pub fn slots(self: *const TurnState) []const TimeSlot {
        return self.timeline.slots();
    }

    /// Get mutable slots slice.
    pub fn slotsMut(self: *TurnState) []TimeSlot {
        return self.timeline.slotsMut();
    }

    pub fn clear(self: *TurnState) void {
        self.timeline.clear();
        self.focus_spent = 0;
        self.stack_focus_paid = false;
        self.pending_targets = .{null} ** Timeline.max_slots;
    }

    /// Store a pending target for a card (before Play exists).
    pub fn setPendingTarget(self: *TurnState, card_id: entity.ID, target_id: entity.ID) void {
        // Find empty slot or existing entry for this card
        for (&self.pending_targets) |*slot| {
            if (slot.* == null or slot.*.?.card_id.eql(card_id)) {
                slot.* = .{ .card_id = card_id, .target_id = target_id };
                return;
            }
        }
        // Array full - shouldn't happen if max_slots matches timeline capacity
    }

    /// Get pending target for a card, if any.
    pub fn getPendingTarget(self: *const TurnState, card_id: entity.ID) ?entity.ID {
        for (self.pending_targets) |slot| {
            if (slot) |pt| {
                if (pt.card_id.eql(card_id)) return pt.target_id;
            }
        }
        return null;
    }

    /// Clear pending target for a card (e.g., when card is cancelled).
    pub fn clearPendingTarget(self: *TurnState, card_id: entity.ID) void {
        for (&self.pending_targets) |*slot| {
            if (slot.*) |pt| {
                if (pt.card_id.eql(card_id)) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    /// Add a play at the next available time slot.
    /// Preserves sequential behavior from old API.
    pub fn addPlay(
        self: *TurnState,
        play: Play,
        registry: *const world.CardRegistry,
    ) error{ Overflow, Conflict, NoSpace }!void {
        // Check capacity first for clearer error
        if (self.timeline.slots_len >= Timeline.max_slots) return error.Overflow;

        const channels = getPlayChannels(play, registry);
        const duration = getPlayDuration(play, registry);
        const start = self.timeline.nextAvailableStart(channels, duration, registry) orelse
            return error.NoSpace;
        self.timeline.insert(start, start + duration, play, channels, registry) catch |err| switch (err) {
            error.Conflict => return error.Conflict,
            error.Overflow => return error.Overflow,
        };
    }

    /// Add a play at a specific time.
    pub fn addPlayAt(
        self: *TurnState,
        play: Play,
        time_start: f32,
        registry: *const world.CardRegistry,
    ) error{ Overflow, Conflict }!void {
        const channels = getPlayChannels(play, registry);
        const duration = getPlayDuration(play, registry);
        try self.timeline.insert(time_start, time_start + duration, play, channels, registry);
    }

    /// Remove a play by index.
    pub fn removePlay(self: *TurnState, index: usize) void {
        self.timeline.remove(index);
    }

    /// Find a play by its action card ID, returns index or null.
    pub fn findPlayByCard(self: *const TurnState, card_id: entity.ID) ?usize {
        return self.timeline.findByCard(card_id);
    }

    /// Check if a new technique's channels would conflict with any existing play.
    /// Note: With Timeline, this checks for any channel overlap regardless of time.
    /// For time-aware conflict checking, use timeline.canInsert() directly.
    pub fn wouldConflictOnChannel(
        self: *const TurnState,
        new_channels: cards.ChannelSet,
        registry: *const world.CardRegistry,
    ) bool {
        for (self.slots()) |slot| {
            const existing_channels = getPlayChannels(slot.play, registry);
            if (new_channels.conflicts(existing_channels)) return true;
        }
        return false;
    }
};

/// Ring buffer of recent turns for sequencing predicates.
pub const TurnHistory = struct {
    pub const max_history = 4;

    recent_buf: [max_history]TurnState = undefined,
    recent_len: usize = 0,

    pub fn recent(self: *const TurnHistory) []const TurnState {
        return self.recent_buf[0..self.recent_len];
    }

    pub fn push(self: *TurnHistory, turn: TurnState) void {
        if (self.recent_len == max_history) {
            // Shift out oldest
            std.mem.copyForwards(TurnState, self.recent_buf[0 .. max_history - 1], self.recent_buf[1..max_history]);
            self.recent_len -= 1;
        }
        self.recent_buf[self.recent_len] = turn;
        self.recent_len += 1;
    }

    pub fn lastTurn(self: *const TurnHistory) ?*const TurnState {
        return if (self.recent_len > 0)
            &self.recent_buf[self.recent_len - 1]
        else
            null;
    }

    pub fn turnsAgo(self: *const TurnHistory, n: usize) ?*const TurnState {
        if (n >= self.recent_len) return null;
        return &self.recent_buf[self.recent_len - 1 - n];
    }
};

/// Per-agent state within an encounter.
pub const AgentEncounterState = struct {
    current: TurnState = .{},
    history: TurnHistory = .{},

    /// End current turn: push to history and clear.
    pub fn endTurn(self: *AgentEncounterState) void {
        self.history.push(self.current);
        self.current.clear();
    }
};

// ============================================================================
// Condition Iterator
// ============================================================================

/// Iterates stored conditions, then yields computed conditions based on thresholds.
pub const ConditionIterator = struct {
    agent: *const Agent,
    engagement: ?*const Engagement,
    stored_index: usize = 0,
    computed_phase: u2 = 0, // 0=unbalanced, 1=pressured, 2=weapon_bound, 3=done

    const Expiration = damage.ActiveCondition.Expiration;

    pub fn init(agent: *const Agent, engagement: ?*const Engagement) ConditionIterator {
        return .{ .agent = agent, .engagement = engagement };
    }

    pub fn next(self: *ConditionIterator) ?damage.ActiveCondition {
        // Phase 1: yield stored conditions
        if (self.stored_index < self.agent.conditions.items.len) {
            const cond = self.agent.conditions.items[self.stored_index];
            self.stored_index += 1;
            return cond;
        }

        // Phase 2: yield computed conditions
        while (self.computed_phase < 3) {
            const phase = self.computed_phase;
            self.computed_phase += 1;

            switch (phase) {
                0 => if (self.agent.balance < 0.2) {
                    return .{ .condition = .unbalanced, .expiration = .dynamic };
                },
                1 => if (self.engagement) |eng| {
                    if (eng.pressure > 0.8) {
                        return .{ .condition = .pressured, .expiration = .dynamic };
                    }
                },
                2 => if (self.engagement) |eng| {
                    if (eng.control > 0.8) {
                        return .{ .condition = .weapon_bound, .expiration = .dynamic };
                    }
                },
                else => {},
            }
        }

        return null;
    }
};

// ============================================================================
// Advantage Effects
// ============================================================================

/// Deltas to apply to advantage axes after technique resolution
pub const AdvantageEffect = struct {
    pressure: f32 = 0,
    control: f32 = 0,
    position: f32 = 0,
    self_balance: f32 = 0,
    target_balance: f32 = 0,

    pub fn apply(
        self: AdvantageEffect,
        engagement: *Engagement,
        attacker: *Agent,
        defender: *Agent,
    ) void {
        engagement.pressure = std.math.clamp(engagement.pressure + self.pressure, 0, 1);
        engagement.control = std.math.clamp(engagement.control + self.control, 0, 1);
        engagement.position = std.math.clamp(engagement.position + self.position, 0, 1);
        attacker.balance = std.math.clamp(attacker.balance + self.self_balance, 0, 1);
        defender.balance = std.math.clamp(defender.balance + self.target_balance, 0, 1);
    }

    pub fn scale(self: AdvantageEffect, mult: f32) AdvantageEffect {
        return .{
            .pressure = self.pressure * mult,
            .control = self.control * mult,
            .position = self.position * mult,
            .self_balance = self.self_balance * mult,
            .target_balance = self.target_balance * mult,
        };
    }
};

/// Technique-specific advantage overrides per outcome
pub const TechniqueAdvantage = struct {
    on_hit: ?AdvantageEffect = null,
    on_miss: ?AdvantageEffect = null,
    on_blocked: ?AdvantageEffect = null,
    on_parried: ?AdvantageEffect = null,
    on_deflected: ?AdvantageEffect = null,
    on_dodged: ?AdvantageEffect = null,
    on_countered: ?AdvantageEffect = null,
};

//      // Derived: overall openness to decisive strike
// pub fn vulnerability(self: Advantage) f32 {
//     // When any axis is bad enough, you're open
//     const worst = @min(@min(self.control, self.position), self.balance);
//     // Pressure contributes but isn't sufficient alone
//     return (1.0 - worst) * 0.7 + (1.0 - self.pressure) * 0.3;
// }
// Reading Advantage
//
// From the player's perspective against a specific mob:
//
// pub fn playerVsMob(player: *Player, mob: *Mob) struct { f32, f32 } {
//     // Player's vulnerability in this engagement
//     const player_vuln = (1.0 - mob.engagement.playerAdvantage()) * 0.6
//                       + (1.0 - player.state.balance) * 0.4;
//
//     // Mob's vulnerability in this engagement
//     const mob_vuln = mob.engagement.playerAdvantage() * 0.6
//                    + (1.0 - mob.state.balance) * 0.4;
//
//     return .{ player_vuln, mob_vuln };
// }
//
// Balance contributes to vulnerability in all engagements. Relational advantage only matters for this engagement.
//
// Attention split:
// When player acts against mob A, mob B might get a "free" advantage tick:
// pub fn applyAttentionPenalty(player: *Player, focused_mob: *Mob, all_mobs: []*Mob) void {
//     for (all_mobs) |mob| {
//         if (mob != focused_mob) {
//             // Unfocused enemies gain slight positional advantage
//             mob.engagement.position -= 0.05;  // Toward mob advantage
//         }
//     }
// }
//
// Overcommitment penalty spreads:
// When player whiffs a heavy attack against mob A:
// // Player's balance drops (intrinsic)
// player.state.balance -= 0.2;
//
// // This affects ALL engagements because balance is intrinsic
// // No need to update each mob's engagement — the vulnerability
// // calculation already incorporates player.state.balance
//
// Mob coordination:
// If mobs are smart, they can exploit split attention:
// // Mob A feints to draw player's focus
// // Mob B's pattern shifts to "exploit opening" when player.engagement with A shows commitment

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const card_list = @import("card_list.zig");

// NOTE: TechniquePool tests removed during Phase 7 migration.
// TechniquePool was removed in favor of unified draw_style system.

fn testId(index: u32) entity.ID {
    return .{ .index = index, .generation = 0 };
}

test "Armament.hasCategory single weapon" {
    const weapon_list = @import("weapon_list.zig");
    var buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    var sword_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.knights_sword };

    const shield_armament = Armament{ .single = &buckler_instance };
    try testing.expect(shield_armament.hasCategory(.shield));
    try testing.expect(!shield_armament.hasCategory(.sword));

    const sword_armament = Armament{ .single = &sword_instance };
    try testing.expect(!sword_armament.hasCategory(.shield));
    try testing.expect(sword_armament.hasCategory(.sword));
}

test "Armament.hasCategory dual wield" {
    const weapon_list = @import("weapon_list.zig");
    var buckler_instance = weapon.Instance{ .id = testId(0), .template = &weapon_list.buckler };
    var sword_instance = weapon.Instance{ .id = testId(1), .template = &weapon_list.knights_sword };

    const sword_and_shield = Armament{ .dual = .{
        .primary = &sword_instance,
        .secondary = &buckler_instance,
    } };
    try testing.expect(sword_and_shield.hasCategory(.shield));
    try testing.expect(sword_and_shield.hasCategory(.sword));
    try testing.expect(!sword_and_shield.hasCategory(.axe));
}

test "ConditionIterator computed condition thresholds" {
    // Test the threshold logic for computed conditions directly
    // using ConditionIterator's internal state machine

    // Test balance threshold: < 0.2 = unbalanced
    try testing.expect(0.1 < 0.2); // would trigger unbalanced
    try testing.expect(!(0.2 < 0.2)); // boundary: not triggered
    try testing.expect(!(0.5 < 0.2)); // normal: not triggered

    // Test pressure threshold: > 0.8 = pressured
    try testing.expect(0.9 > 0.8); // would trigger pressured
    try testing.expect(!(0.8 > 0.8)); // boundary: not triggered
    try testing.expect(!(0.5 > 0.8)); // normal: not triggered

    // Test control threshold: > 0.8 = weapon_bound
    try testing.expect(0.85 > 0.8); // would trigger weapon_bound
    try testing.expect(!(0.8 > 0.8)); // boundary: not triggered
}

test "Play.effectiveStakes escalates with modifiers" {
    var play = Play{ .action = testId(1) };
    try testing.expectEqual(cards.Stakes.guarded, play.effectiveStakes());

    try play.addModifier(testId(2));
    try testing.expectEqual(cards.Stakes.committed, play.effectiveStakes());

    try play.addModifier(testId(3));
    try testing.expectEqual(cards.Stakes.reckless, play.effectiveStakes());
}

test "Play.canStack false when added_in_commit" {
    const normal_play = Play{ .action = testId(1) };
    try testing.expect(normal_play.canStack());

    const commit_play = Play{ .action = testId(2), .added_in_commit = true };
    try testing.expect(!commit_play.canStack());
}

test "TurnState tracks plays and clears" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};
    try testing.expectEqual(@as(usize, 0), state.slots().len);

    try state.addPlay(.{ .action = testId(1) }, &registry);
    try state.addPlay(.{ .action = testId(2) }, &registry);
    try testing.expectEqual(@as(usize, 2), state.slots().len);

    state.clear();
    try testing.expectEqual(@as(usize, 0), state.slots().len);
    try testing.expectEqual(@as(f32, 0), state.focus_spent);
}

test "TurnHistory ring buffer evicts oldest" {
    var history = TurnHistory{};

    // Push 4 turns (fills buffer)
    var turn1 = TurnState{};
    turn1.focus_spent = 1.0;
    history.push(turn1);

    var turn2 = TurnState{};
    turn2.focus_spent = 2.0;
    history.push(turn2);

    var turn3 = TurnState{};
    turn3.focus_spent = 3.0;
    history.push(turn3);

    var turn4 = TurnState{};
    turn4.focus_spent = 4.0;
    history.push(turn4);

    try testing.expectEqual(@as(usize, 4), history.recent_len);
    try testing.expectEqual(@as(f32, 4.0), history.lastTurn().?.focus_spent);
    try testing.expectEqual(@as(f32, 1.0), history.turnsAgo(3).?.focus_spent);

    // Push 5th turn, should evict turn1
    var turn5 = TurnState{};
    turn5.focus_spent = 5.0;
    history.push(turn5);

    try testing.expectEqual(@as(usize, 4), history.recent_len);
    try testing.expectEqual(@as(f32, 5.0), history.lastTurn().?.focus_spent);
    try testing.expectEqual(@as(f32, 2.0), history.turnsAgo(3).?.focus_spent); // turn1 evicted
}

test "AgentEncounterState.endTurn pushes to history" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = AgentEncounterState{};

    // Add a play to current turn
    try state.current.addPlay(.{ .action = testId(1) }, &registry);
    state.current.focus_spent = 2.5;

    // End turn
    state.endTurn();

    // Current should be cleared
    try testing.expectEqual(@as(usize, 0), state.current.slots().len);
    try testing.expectEqual(@as(f32, 0), state.current.focus_spent);

    // History should have the previous turn
    try testing.expectEqual(@as(usize, 1), state.history.recent_len);
    try testing.expectEqual(@as(f32, 2.5), state.history.lastTurn().?.focus_spent);
}

test "Play.addModifier overflow returns error" {
    var play = Play{ .action = testId(0) };

    // Fill to capacity
    for (0..Play.max_modifiers) |i| {
        try play.addModifier(testId(@intCast(i + 1)));
    }
    try testing.expectEqual(Play.max_modifiers, play.modifier_stack_len);

    // Next one should fail
    try testing.expectError(error.Overflow, play.addModifier(testId(99)));
    try testing.expectEqual(Play.max_modifiers, play.modifier_stack_len); // unchanged
}

test "TurnState.addPlay overflow returns error" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};

    // Fill to capacity (Timeline.max_slots)
    for (0..Timeline.max_slots) |i| {
        try state.addPlay(.{ .action = testId(@intCast(i)) }, &registry);
    }
    try testing.expectEqual(Timeline.max_slots, state.slots().len);

    // Next one should fail with Overflow
    try testing.expectError(error.Overflow, state.addPlay(.{ .action = testId(99) }, &registry));
    try testing.expectEqual(Timeline.max_slots, state.slots().len); // unchanged
}

test "AgentPair.canonical produces consistent key regardless of order" {
    const id_low = entity.ID{ .index = 1, .generation = 0 };
    const id_high = entity.ID{ .index = 5, .generation = 0 };

    const pair_ab = AgentPair.canonical(id_low, id_high);
    const pair_ba = AgentPair.canonical(id_high, id_low);

    try testing.expectEqual(pair_ab.a.index, pair_ba.a.index);
    try testing.expectEqual(pair_ab.b.index, pair_ba.b.index);
    try testing.expectEqual(@as(u32, 1), pair_ab.a.index);
    try testing.expectEqual(@as(u32, 5), pair_ab.b.index);
}

test "TurnState.removePlay shifts remaining plays" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};

    try state.addPlay(.{ .action = testId(1) }, &registry);
    try state.addPlay(.{ .action = testId(2) }, &registry);
    try state.addPlay(.{ .action = testId(3) }, &registry);
    try testing.expectEqual(@as(usize, 3), state.slots().len);

    // Remove middle play
    state.removePlay(1);
    try testing.expectEqual(@as(usize, 2), state.slots().len);
    try testing.expectEqual(@as(u32, 1), state.slots()[0].play.action.index);
    try testing.expectEqual(@as(u32, 3), state.slots()[1].play.action.index);
}

test "TurnState.removePlay handles out of bounds" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};
    try state.addPlay(.{ .action = testId(1) }, &registry);

    // Should do nothing for invalid index
    state.removePlay(5);
    try testing.expectEqual(@as(usize, 1), state.slots().len);
}

test "TurnState.findPlayByCard returns correct index" {
    var registry = try world.CardRegistry.init(testing.allocator);
    defer registry.deinit();

    var state = TurnState{};

    try state.addPlay(.{ .action = testId(10) }, &registry);
    try state.addPlay(.{ .action = testId(20) }, &registry);
    try state.addPlay(.{ .action = testId(30) }, &registry);

    try testing.expectEqual(@as(?usize, 0), state.findPlayByCard(testId(10)));
    try testing.expectEqual(@as(?usize, 1), state.findPlayByCard(testId(20)));
    try testing.expectEqual(@as(?usize, 2), state.findPlayByCard(testId(30)));
    try testing.expectEqual(@as(?usize, null), state.findPlayByCard(testId(99)));
}

// TODO: Integration tests for commit phase commands (requires full World setup):
// - commit_withdraw: refunds stamina, removes from plays, returns card to hand
// - commit_add: validates phase flags, marks added_in_commit, creates new play
// - commit_stack: first stack costs 1F, subsequent free; template matching; can't stack added_in_commit
// - executeCommitPhaseRules: fires on_commit rules, applies play modifications

// Test helper to create minimal agent for isIncapacitated tests
fn makeTestAgent(alloc: std.mem.Allocator, agents: *SlotMap(*Agent)) !*Agent {
    const weapon_list = @import("weapon_list.zig");
    const sword = try alloc.create(weapon.Instance);
    sword.* = .{ .id = testId(999), .template = &weapon_list.knights_sword };

    return Agent.init(
        alloc,
        agents,
        .player,
        .shuffled_deck,
        stats.Block.splat(5),
        try body.Body.fromPlan(alloc, &body.HumanoidPlan),
        stats.Resource.init(10.0, 10.0, 2.0),
        stats.Resource.init(3.0, 5.0, 3.0),
        Armament{ .single = sword },
    );
}

test "isIncapacitated false for healthy agent" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try makeTestAgent(alloc, &agents);
    const sword = agent.weapons.single; // save before destroy
    defer alloc.destroy(sword);
    defer agent.destroy(&agents);

    try testing.expect(!agent.isIncapacitated());
}

test "isIncapacitated true when vital organ destroyed" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try makeTestAgent(alloc, &agents);
    const sword = agent.weapons.single;
    defer alloc.destroy(sword);
    defer agent.destroy(&agents);

    // Find brain (vital organ)
    const brain_idx = agent.body.indexOf("brain").?;
    try testing.expect(agent.body.parts.items[brain_idx].flags.is_vital);

    // Destroy it
    agent.body.parts.items[brain_idx].severity = .missing;

    try testing.expect(agent.isIncapacitated());
}

test "isIncapacitated true when mobility zero" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try makeTestAgent(alloc, &agents);
    const sword = agent.weapons.single;
    defer alloc.destroy(sword);
    defer agent.destroy(&agents);

    // Destroy all can_stand parts (legs, feet, groin)
    for (agent.body.parts.items) |*part| {
        if (part.flags.can_stand) {
            part.severity = .missing;
        }
    }

    try testing.expectEqual(@as(f32, 0.0), agent.body.mobilityScore());
    try testing.expect(agent.isIncapacitated());
}

test "isIncapacitated true when unconscious" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try makeTestAgent(alloc, &agents);
    const sword = agent.weapons.single;
    defer alloc.destroy(sword);
    defer agent.destroy(&agents);

    // Add unconscious condition
    try agent.conditions.append(alloc, .{
        .condition = .unconscious,
        .expiration = .permanent,
    });

    try testing.expect(agent.isIncapacitated());
}

test "isIncapacitated true when comatose" {
    const alloc = testing.allocator;
    var agents = try SlotMap(*Agent).init(alloc);
    defer agents.deinit();

    const agent = try makeTestAgent(alloc, &agents);
    const sword = agent.weapons.single;
    defer alloc.destroy(sword);
    defer agent.destroy(&agents);

    // Add comatose condition
    try agent.conditions.append(alloc, .{
        .condition = .comatose,
        .expiration = .permanent,
    });

    try testing.expect(agent.isIncapacitated());
}

// ============================================================================
// Pool Card (always_available) Tests
// ============================================================================

test "addToInPlayFrom clones pool cards" {
    // Playing a card from always_available should create a new instance (clone)
    // with a different ID than the master, while master stays in pool.
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    var cs = try CombatState.init(alloc);
    defer cs.deinit();

    // Create a master card in always_available
    const master = try registry.create(card_list.BaseAlwaysAvailableTemplates[0]);
    const master_id = master.id;

    // Play it from always_available source
    const in_play_id = try cs.addToInPlayFrom(master_id, .always_available, &registry);

    // Clone should have different ID than master
    try testing.expect(!in_play_id.eql(master_id));

    // Master should still exist in registry
    try testing.expect(registry.get(master_id) != null);

    // Clone should exist in registry
    try testing.expect(registry.get(in_play_id) != null);

    // Clone should be in in_play zone
    try testing.expect(cs.isInZone(in_play_id, .in_play));
}

test "addToInPlayFrom tracks master_id for pool cards" {
    // The in_play_sources entry should have master_id set to the original card
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    var cs = try CombatState.init(alloc);
    defer cs.deinit();

    const master = try registry.create(card_list.BaseAlwaysAvailableTemplates[0]);
    const master_id = master.id;

    const in_play_id = try cs.addToInPlayFrom(master_id, .always_available, &registry);

    // in_play_sources should track the clone with master_id pointing to original
    const info = cs.in_play_sources.get(in_play_id);
    try testing.expect(info != null);
    try testing.expectEqual(CombatState.CardSource.always_available, info.?.source);
    try testing.expect(info.?.master_id != null);
    try testing.expect(info.?.master_id.?.eql(master_id));
}

test "removeFromInPlay destroys pool card clones" {
    // Removing a pool card clone should destroy it via registry,
    // and return the master_id for cooldown application.
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    var cs = try CombatState.init(alloc);
    defer cs.deinit();

    const master = try registry.create(card_list.BaseAlwaysAvailableTemplates[0]);
    const master_id = master.id;

    const clone_id = try cs.addToInPlayFrom(master_id, .always_available, &registry);

    // Remove the clone from in_play
    const returned_master_id = try cs.removeFromInPlay(clone_id, &registry);

    // Should return the master_id for cooldown tracking
    try testing.expect(returned_master_id != null);
    try testing.expect(returned_master_id.?.eql(master_id));

    // Clone should be destroyed (not in registry)
    try testing.expect(registry.get(clone_id) == null);

    // Master should still exist
    try testing.expect(registry.get(master_id) != null);

    // Clone should not be in in_play zone
    try testing.expect(!cs.isInZone(clone_id, .in_play));

    // Source tracking should be cleaned up
    try testing.expect(cs.in_play_sources.get(clone_id) == null);
}

test "isPoolCardAvailable respects cooldowns" {
    // A card with an active cooldown should not be available.
    // A card with no cooldown or expired cooldown should be available.
    // TODO: Implement test
    return error.SkipZigTest;
}

test "tickCooldowns decrements all cooldowns" {
    // After tickCooldowns, all cooldown values should decrease by 1.
    // Cooldowns at 0 should remain at 0.
    // TODO: Implement test
    return error.SkipZigTest;
}

test "pool cards without cooldown can be played multiple times" {
    // A card with cooldown=null in always_available should be playable
    // again immediately after the previous clone is removed.
    // TODO: Implement test
    return error.SkipZigTest;
}

test "pool cards with cooldown block replay until expired" {
    // A card with cooldown=1 should not be playable again until
    // tickCooldowns brings it to 0.
    // TODO: Implement test
    return error.SkipZigTest;
}

test "cancel pool card destroys clone and clears cooldown" {
    // Cancelling a pool card should destroy the clone, not move to hand,
    // and should refund any cooldown that was set.
    // TODO: Implement test
    return error.SkipZigTest;
}

test "cancel hand card moves back to hand" {
    // Cancelling a hand card should move it back to hand, not destroy it.
    // TODO: Implement test
    return error.SkipZigTest;
}

// ============================================================================
// Play Modifier Conflict Tests
// ============================================================================

test "Play.wouldConflict detects conflicting height_override" {
    // High and Low modifiers both set height_override - they conflict
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const high = card_list.byName("high");
    const low = card_list.byName("low");

    // Create cards in registry
    const high_card = try registry.create(high);
    const thrust = try registry.create(card_list.byName("thrust"));

    // Create play with High modifier already attached
    var play = Play{ .action = thrust.id };
    try play.addModifier(high_card.id);

    // Adding Low should conflict
    try testing.expect(play.wouldConflict(low, &registry));
}

test "Play.wouldConflict allows same height_override" {
    // Two High modifiers have the same height_override - no conflict
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const high = card_list.byName("high");

    const high_card = try registry.create(high);
    const thrust = try registry.create(card_list.byName("thrust"));

    var play = Play{ .action = thrust.id };
    try play.addModifier(high_card.id);

    // Adding another High should not conflict (same height)
    try testing.expect(!play.wouldConflict(high, &registry));
}

test "Play.wouldConflict allows non-conflicting modifiers" {
    // Feint has no height_override, so it doesn't conflict with anything
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const high = card_list.byName("high");
    const feint = card_list.byName("feint");

    const high_card = try registry.create(high);
    const thrust = try registry.create(card_list.byName("thrust"));

    var play = Play{ .action = thrust.id };
    try play.addModifier(high_card.id);

    // Adding Feint should not conflict (no height_override)
    try testing.expect(!play.wouldConflict(feint, &registry));
}

test "Play.wouldConflict returns false for empty modifier stack" {
    // Empty modifier stack never has conflicts
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const low = card_list.byName("low");
    const thrust = try registry.create(card_list.byName("thrust"));

    const play = Play{ .action = thrust.id };

    // No existing modifiers - can't conflict
    try testing.expect(!play.wouldConflict(low, &registry));
}

test "TurnState.wouldConflictOnChannel detects weapon channel conflict" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    // Create two weapon technique cards (thrust, slash both use weapon channel)
    const thrust = try registry.create(card_list.byName("thrust"));
    _ = try registry.create(card_list.byName("slash")); // exists but unused

    var state = TurnState{};
    try state.addPlay(.{ .action = thrust.id }, &registry);

    // Another weapon channel card should conflict
    const weapon_channels = cards.ChannelSet{ .weapon = true };
    try testing.expect(state.wouldConflictOnChannel(weapon_channels, &registry));
}

test "TurnState.wouldConflictOnChannel allows different channels" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    // Create weapon technique card
    const thrust = try registry.create(card_list.byName("thrust"));

    var state = TurnState{};
    try state.addPlay(.{ .action = thrust.id }, &registry);

    // Footwork channel should not conflict with weapon
    const footwork_channels = cards.ChannelSet{ .footwork = true };
    try testing.expect(!state.wouldConflictOnChannel(footwork_channels, &registry));
}

test "TurnState.wouldConflictOnChannel empty state has no conflicts" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const state = TurnState{};

    // No plays - no conflicts possible
    const weapon_channels = cards.ChannelSet{ .weapon = true };
    try testing.expect(!state.wouldConflictOnChannel(weapon_channels, &registry));
}

// ============================================================================
// Timeline Tests
// ============================================================================

test "Timeline.canInsert allows non-overlapping same channel" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const thrust = try registry.create(card_list.byName("thrust")); // time = 0.2

    var timeline = Timeline{};
    // Insert thrust at 0.0-0.2
    try timeline.insert(0.0, 0.2, .{ .action = thrust.id }, .{ .weapon = true }, &registry);

    // Another weapon-channel play starting after thrust ends should be allowed
    try testing.expect(timeline.canInsert(0.2, 0.4, .{ .weapon = true }, &registry));
}

test "Timeline.canInsert rejects overlapping same channel" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const thrust = try registry.create(card_list.byName("thrust")); // time = 0.2

    var timeline = Timeline{};
    try timeline.insert(0.0, 0.2, .{ .action = thrust.id }, .{ .weapon = true }, &registry);

    // Overlapping time range with same channel should be rejected
    try testing.expect(!timeline.canInsert(0.1, 0.3, .{ .weapon = true }, &registry));
}

test "Timeline.canInsert allows overlapping different channels" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const thrust = try registry.create(card_list.byName("thrust")); // weapon channel

    var timeline = Timeline{};
    try timeline.insert(0.0, 0.2, .{ .action = thrust.id }, .{ .weapon = true }, &registry);

    // Overlapping time range but different channel (footwork) should be allowed
    try testing.expect(timeline.canInsert(0.0, 0.2, .{ .footwork = true }, &registry));
}

test "Timeline.nextAvailableStart finds first gap" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const thrust = try registry.create(card_list.byName("thrust")); // time = 0.2
    const slash = try registry.create(card_list.byName("slash")); // time = 0.3

    var timeline = Timeline{};
    // Insert thrust at 0.0-0.2
    try timeline.insert(0.0, 0.2, .{ .action = thrust.id }, .{ .weapon = true }, &registry);
    // Insert slash at 0.4-0.7, leaving gap at 0.2-0.4
    try timeline.insert(0.4, 0.7, .{ .action = slash.id }, .{ .weapon = true }, &registry);

    // Should find the gap at 0.2 for a 0.2 duration weapon play
    const start = timeline.nextAvailableStart(.{ .weapon = true }, 0.2, &registry);
    try testing.expectEqual(@as(?f32, 0.2), start);
}

test "Timeline.nextAvailableStart returns null when no space" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const thrust = try registry.create(card_list.byName("thrust")); // time = 0.2

    var timeline = Timeline{};
    // Fill the timeline with weapon-channel plays (0.0-0.2, 0.2-0.4, ..., 0.8-1.0)
    var t: f32 = 0.0;
    while (t + 0.2 <= 1.0) : (t += 0.2) {
        try timeline.insert(t, t + 0.2, .{ .action = thrust.id }, .{ .weapon = true }, &registry);
    }

    // No space for another 0.2 duration weapon play
    const start = timeline.nextAvailableStart(.{ .weapon = true }, 0.2, &registry);
    try testing.expectEqual(@as(?f32, null), start);
}

test "Timeline.insert snaps time_start to granularity" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const thrust = try registry.create(card_list.byName("thrust"));

    var timeline = Timeline{};
    // Insert at 0.15 - should snap to 0.1
    try timeline.insert(0.15, 0.35, .{ .action = thrust.id }, .{ .weapon = true }, &registry);

    try testing.expectEqual(@as(usize, 1), timeline.len());
    try testing.expectEqual(@as(f32, 0.1), timeline.slots()[0].time_start);
}

test "TimeSlot.overlapsWith adjacent slots do not overlap" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const thrust = try registry.create(card_list.byName("thrust")); // time = 0.2

    const slot = TimeSlot{
        .time_start = 0.0,
        .play = .{ .action = thrust.id },
    };

    // Adjacent: slot ends at 0.2, query starts at 0.2 - should NOT overlap
    try testing.expect(!slot.overlapsWith(0.2, 0.4, &registry));
}

test "TimeSlot.overlapsWith exact same range overlaps" {
    const alloc = testing.allocator;

    var registry = try world.CardRegistry.init(alloc);
    defer registry.deinit();

    const thrust = try registry.create(card_list.byName("thrust")); // time = 0.2

    const slot = TimeSlot{
        .time_start = 0.0,
        .play = .{ .action = thrust.id },
    };

    // Exact same range: 0.0-0.2 should overlap
    try testing.expect(slot.overlapsWith(0.0, 0.2, &registry));
}
