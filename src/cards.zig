const std = @import("std");
// const assert = std.testing.expectEqual
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event); // std.meta.activeTag(event) for cmp
const EntityID = @import("entity.zig").EntityID;
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");

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

pub const Trigger = union(enum) {
    on_play,
    on_draw,
    on_tick,
    on_event: EventTag,
};

pub const Effect = struct {
    op: OpSpec, // tagged union with payload (damage, draw, etc.)
    predicate: ?Predicate, // optional guard
    target: TargetQuery, // query returning one or many entities/parts
    // mods: ModifierHooks, // optional extra data (e.g., use stamina pipeline)
};

// placeholder for “effect-level instructions to the modifier pipeline,”
// pub const ModifierHooks = struct {
//     use_stamina_pipeline: bool = false,
//     use_time_pipeline: bool = false,
// };

pub const ActionRef = ?u32;

pub const ActionSpec = struct {
    duration: f32 = 1.0,
    cost: Cost,
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

pub const ModifierSpec = struct {};
pub const OpSpec = union(enum) {
    apply_damage: struct {
        base: damage.Packet, // numbers derived from card definition
        scaling: damage.ScalingSpec, // e.g. { stat = .power, ratio = 0.6 }
        damage_kind: damage.Kind,
        action_ref: ActionRef, // optional, for logging/interrupt
    },
    start_action: ActionSpec,
    modify_stamina: struct { amount: i32 },
    move_card: struct { from: Zone, to: Zone },
    add_modifier: ModifierSpec,
    emit_event: Event,
};

pub const Predicate = union(enum) {
    always_true,
    compare_stat: struct { lhs: stats.Accessor, op: CmpOp, rhs: Value },
    has_tag: Tag,
    not: *Predicate,
    this_and: []const Predicate,
    this_or: []const Predicate,
};

pub const Tag = enum {
    none,
};

pub const CmpOp = enum {
    lt,
    lte,
    eq,
    gte,
    gt,
};
pub const Value = union(enum) {
    constant: f32,
    stat: stats.Accessor,
};
pub const TargetQuery = union(enum) {
    single: Selector, // e.g. explicit target chosen during play
    all_enemies,
    self,
    body_part: body.Tag,
    event_source,
};

pub const Selector = struct {
    id: EntityID,
};

pub const Rule = struct {
    trigger: Trigger,
    predicate: ?Predicate,
    effects: []const Effect,
};

pub const Op = union(enum) {
    apply_damage,
    inflict_wound,
    add_condition: damage.Condition,
    remove_condition: damage.Condition,
    exhaust_card: EntityID,
    return_exhausted_card: EntityID,
    interrupt_action,
};

pub const TagSet = struct {};

pub const ID = u16;

pub const Template = struct {
    id: ID,
    name: []const u8,
    description: []const u8,
    tags: TagSet,
    rules: []const Rule,
    cost: Cost, 
};

pub const Instance = struct { id: EntityID,
    template: ID,
    // TODO model card enhancements 
};

pub const Cost = struct {
    stamina: f32,
    time: f32,
    exhausts: bool,
};
