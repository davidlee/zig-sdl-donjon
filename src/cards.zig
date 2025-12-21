const std = @import("std");
// const assert = std.testing.expectEqual
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event); // std.meta.activeTag(event) for cmp
const EntityID = @import("entity.zig").EntityID;
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");
const actions = @import("actions.zig");

pub const ID = u16;

fn nextCardID(comptime currID: *ID) ID {
    currID.* += 1;
    return currID;
}

pub const Kind = enum {
    action,
    passive,
    reaction,
    encounter,
    mob,
    // Ally,
    environment,
    resource,
    meta_progression,
};

pub const Rarity = enum {
    common,
    uncommon,
    rare,
    epic,
    legendary,
};

pub const Zone = enum {
    draw,
    hand,
    discard,
    in_play,
    equipped,
    inventory,
    active_passives,
    active_meta,
    active_reactions,
};

pub const Trigger = union(enum) {
    on_play,
    on_draw,
    on_tick,
    on_event: EventTag,
};

pub const TagSet = packed struct {
    melee: true,
    ranged: true,
    offensive: true,
    defensive: true,
    spell: true,
    item: true,
    buff: true,
    debuff: true,
    reaction: true,
    power: true,
    skill: true,
    meta: true,
};

pub const Comparator = enum {
    lt,
    lte,
    eq,
    gte,
    gt,
};

pub const ScalingSpec = struct {
    stats: .{ stats.Accessor, ?stats.Accessor },
    ratio: f32 = 1.0,
};

pub const Cost = struct {
    stamina: f32,
    time: f32 = 0.3,
    exhausts: bool = false,
};

pub const Value = union(enum) {
    constant: f32,
    stat: stats.Accessor,
};

pub const Predicate = union(enum) {
    always,
    compare_stat: struct { lhs: stats.Accessor, op: Comparator, rhs: Value },
    has_tag: ?TagSet, // bitmask with one bit set
    not: *Predicate,
    all: []const Predicate,
    any: []const Predicate,
};

pub const Selector = struct {
    id: EntityID,
};

pub const TargetQuery = union(enum) {
    single: Selector, // e.g. explicit target chosen during play
    all_enemies,
    self,
    body_part: body.Tag,
    event_source,
};

pub const Effect = union(enum) {
    apply_damage: struct {
        base: damage.Packet, // numbers derived from card definition
        scaling: ScalingSpec, // e.g. { stat = .power, ratio = 0.6 }
        kind: damage.Kind,
        action_ref: actions.ID, // optional, for logging/interrupt
    },
    start_action: actions.Spec,
    modify_stamina: struct {
        amount: i32,
        ratio: f32,
    },
    move_card: struct { from: Zone, to: Zone },
    // add_modifier: ModifierSpec,
    add_condition: damage.Condition,
    remove_condition: damage.Condition,
    exhaust_card: EntityID,
    return_exhausted_card: EntityID,
    interrupt_action,
    emit_event: Event,
};

pub const Expression = struct {
    effect: Effect, // tagged union with payload (damage, draw, etc.)
    filter: ?Predicate, // optional guard
    target: TargetQuery, // query returning one or many entities/parts
    // mods: ModifierHooks, // optional extra data (e.g., use stamina pipeline)
};

// each effect runs predicate.eval(context) before invoking the op
// and target.execute(context) to produce 1+ targets for the op to mutate
// when the effect is resolved, build a DamageContext or EffectContext(card id, actor id, targets) for the mod pipeline
// placeholder for “effect-level instructions to the modifier pipeline,”
// pub const ModifierHooks = struct {
//     use_stamina_pipeline: bool = false,
//     use_time_pipeline: bool = false,
// };

pub const Rule = struct {
    trigger: Trigger,
    valid: Predicate,
    expressions: []const Expression,
};

pub const Template = struct {
    id: ID,
    kind: Kind,
    name: []const u8,
    description: []const u8,
    rarity: Rarity,
    tags: TagSet,
    rules: []const Rule,
    cost: Cost,
};

pub const Instance = struct {
    id: EntityID,
    template: ID,
    // TODO model card enhancements
};
