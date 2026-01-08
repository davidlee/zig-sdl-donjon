/// Event types and event-system queue for domain notifications.
///
/// Defines the union of domain events and the EventSystem that buffers them.
/// Presentation and other systems consume these events; no rendering here.
const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const RandomStreamID = @import("random.zig").RandomStreamID;
const Slot = void; // TODO what's this look like?
const cards = @import("cards.zig");
const damage = @import("damage.zig");
const world = @import("world.zig");
const body = @import("body.zig");
const combat = @import("combat.zig");
const resolution = @import("resolution.zig");
const apply = @import("apply.zig");
const Zone = cards.Zone;
pub const CardWithSlot = struct {
    card: entity.ID,
    slot: Slot,
};

pub const CardWithEvent = struct {
    card: entity.ID,
    event_index: usize, // in the EventSystem.current_events queue - must exist
};

pub const RandomWithMeta = struct {
    stream: RandomStreamID,
    result: f32,
};

pub const AgentMeta = struct {
    id: entity.ID,
    player: bool = false,
};

// tagged union: events
pub const Event = union(enum) {
    entity_died: u32, // Payload: just the ID
    mob_died: entity.ID,

    played_action_card: struct { instance: entity.ID, template: u64, actor: AgentMeta, target: ?entity.ID = null },
    card_moved: struct { instance: entity.ID, from: Zone, to: Zone, actor: AgentMeta },
    card_cloned: struct { clone_id: entity.ID, master_id: entity.ID, actor: AgentMeta },
    card_cancelled: struct { instance: entity.ID, actor: AgentMeta },

    game_state_transitioned_to: world.GameState,
    turn_phase_transitioned_to: combat.TurnPhase,

    card_cost_reserved: struct {
        stamina: f32,
        time: f32,
        actor: AgentMeta,
    },

    card_cost_returned: struct {
        stamina: f32,
        time: f32,
        actor: AgentMeta,
        // TODO instances -> [exhausted?]
    },

    // TODO update agent refs for the rest
    // what is worth recording out of:
    // -- who's affected (AgentMeta) - yes
    // -- who caused it - maybe
    // -- what [kind of] card / effect caused it? - maybe

    // wound events
    wound_inflicted: struct {
        agent_id: entity.ID,
        wound: body.Wound,
        part_idx: body.PartIndex,
        part_tag: body.PartTag,
        part_side: body.Side,
    },

    body_part_severed: struct {
        agent_id: entity.ID,
        part_idx: body.PartIndex,
        part_tag: body.PartTag,
        part_side: body.Side,
    },
    hit_major_artery: struct {
        agent_id: entity.ID,
        part_idx: body.PartIndex,
        part_tag: body.PartTag,
        part_side: body.Side,
    },

    // Armour events
    armour_deflected: struct {
        agent_id: entity.ID,
        part_idx: body.PartIndex,
        part_tag: body.PartTag,
        part_side: body.Side,
        layer: u8, // inventory.Layer as int
    },
    armour_absorbed: struct {
        agent_id: entity.ID,
        part_idx: body.PartIndex,
        part_tag: body.PartTag,
        part_side: body.Side,
        damage_reduced: f32,
        layers_hit: u8,
    },
    armour_layer_destroyed: struct {
        agent_id: entity.ID,
        part_idx: body.PartIndex,
        part_tag: body.PartTag,
        part_side: body.Side,
        layer: u8,
    },
    attack_found_gap: struct {
        agent_id: entity.ID,
        part_idx: body.PartIndex,
        part_tag: body.PartTag,
        part_side: body.Side,
        layer: u8,
    },

    // Resolution events
    technique_resolved: struct {
        attacker_id: entity.ID,
        defender_id: entity.ID,
        technique_id: cards.TechniqueID,
        outcome: resolution.Outcome,
        // Roll details
        hit_chance: f32, // final chance after all modifiers
        roll: f32, // actual roll value
        margin: f32, // roll - hit_chance (positive = miss margin, negative = hit margin)
        // Modifier totals (from conditions, etc)
        attacker_modifier: f32, // total hit chance adjustment from attacker conditions
        defender_modifier: f32, // total defense adjustment from defender conditions
    },

    attack_out_of_range: struct {
        attacker_id: entity.ID,
        defender_id: entity.ID,
        technique_id: cards.TechniqueID,
        weapon_reach: combat.Reach,
        engagement_range: combat.Reach,
    },

    manoeuvre_contest_resolved: struct {
        aggressor_id: entity.ID,
        defender_id: entity.ID,
        aggressor_move: apply.ManoeuvreType,
        defender_move: apply.ManoeuvreType,
        aggressor_score: f32,
        defender_score: f32,
        outcome: apply.ManoeuvreOutcome,
    },

    advantage_changed: struct {
        agent_id: entity.ID,
        engagement_with: ?entity.ID, // null for intrinsic (balance)
        axis: combat.AdvantageAxis,
        old_value: f32,
        new_value: f32,
    },

    range_changed: struct {
        actor_id: entity.ID,
        target_id: entity.ID,
        old_range: combat.Reach,
        new_range: combat.Reach,
    },

    position_changed: struct {
        actor_id: entity.ID,
        target_id: entity.ID,
        old_position: f32,
        new_position: f32,
    },

    primary_target_changed: struct {
        actor_id: entity.ID,
        old_target: ?entity.ID,
        new_target: entity.ID,
    },

    played_reaction: CardWithEvent,

    equipped_item: CardWithSlot,
    unequipped_item: CardWithSlot,

    equipped_spell: CardWithSlot,
    unequipped_spell: CardWithSlot,

    equipped_passive: CardWithSlot,
    unequipped_passive: CardWithSlot,

    draw_random: RandomWithMeta,

    play_sound: struct { // Payload: struct
        id: u16,
        volume: f32,
    },
    player_turn_ended: void, // Payload: none
    player_committed: void, // Payload: none
    tick_ended: void, // tick resolution completed
    combat_ended: combat.CombatOutcome, // Encounter finished (victory/defeat/etc)

    // Tick cleanup events (for observability)
    stamina_deducted: struct {
        agent_id: entity.ID,
        amount: f32,
        new_value: f32,
    },
    // Resolution phase resource recovery
    stamina_recovered: struct {
        agent_id: entity.ID,
        amount: f32,
        new_value: f32,
        actor: AgentMeta,
    },
    focus_recovered: struct {
        agent_id: entity.ID,
        amount: f32,
        new_value: f32,
        actor: AgentMeta,
    },
    blood_drained: struct {
        agent_id: entity.ID,
        amount: f32,
        new_value: f32,
    },
    condition_applied: struct {
        agent_id: entity.ID,
        condition: damage.Condition,
        actor: AgentMeta,
    },
    condition_expired: struct {
        agent_id: entity.ID,
        condition: damage.Condition,
        actor: AgentMeta,
    },
    cooldown_applied: struct {
        agent_id: entity.ID,
        template_id: cards.ID,
        ticks: u8,
    },
};

pub const EventSystem = struct {
    // We use two buffers to avoid "modifying the list while iterating it"
    current_events: std.ArrayList(Event),
    next_events: std.ArrayList(Event),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !EventSystem {
        return .{
            .current_events = try std.ArrayList(Event).initCapacity(alloc, 1000),
            .next_events = try std.ArrayList(Event).initCapacity(alloc, 1000),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *EventSystem) void {
        self.current_events.deinit(self.alloc);
        self.next_events.deinit(self.alloc);
    }

    fn logQueueSize(self: *EventSystem, label: []const u8) void {
        std.debug.print("events::{s} ->  next: {d} -- current: {d} \n", .{
            label,
            self.next_events.items.len,
            self.current_events.items.len,
        });
    }

    fn logEvent(self: *EventSystem, label: []const u8, event: *const Event) void {
        _ = self;
        std.debug.print("events::{s} ->  event: {any}\n", .{ label, event });
    }

    pub fn pop(self: *EventSystem) ?Event {
        return self.current_events.pop();
    }

    // Systems call this to queue something for NEXT frame
    pub fn push(self: *EventSystem, event: Event) !void {
        // self.logEvent("push", &event);
        try self.next_events.append(self.alloc, event);
    }

    // Call this at the start of your frame (or end)
    pub fn swap_buffers(self: *EventSystem) void {
        // Clear the "old" current list (which we just finished processing)
        self.current_events.clearRetainingCapacity();

        // Swap the lists.
        // 'next' becomes 'current' (to be read).
        // 'current' becomes 'next' (empty, ready to be written to).
        std.mem.swap(std.ArrayList(Event), &self.current_events, &self.next_events);
    }
};
