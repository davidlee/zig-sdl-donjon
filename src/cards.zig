const std = @import("std");
// const assert = std.testing.expectEqual
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event); // std.meta.activeTag(event) for cmp
const EntityID = @import("entity.zig").EntityID;
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");

pub const ID = u64;

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
    melee: bool = false,
    ranged: bool = false,
    offensive: bool = false,
    defensive: bool = false,
    spell: bool = false,
    item: bool = false,
    buff: bool = false,
    debuff: bool = false,
    reaction: bool = false,
    power: bool = false,
    skill: bool = false,
    meta: bool = false,

    pub fn hasTag(self: *const TagSet, required: TagSet) bool {
        const me: u12 = @bitCast(self.*);
        const req: u12 = @bitCast(required);
        return (me & req) == req; // all required bits present
    }

    pub fn hasAnyTag(self: *const TagSet, mask: TagSet) bool {
        const me: u12 = @bitCast(self.*);
        const bm: u12 = @bitCast(mask);
        return (me & bm) != 0; // at least one bit matches
    }
};

pub const Comparator = enum {
    lt,
    lte,
    eq,
    gte,
    gt,
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
    // compare_stat: struct { lhs: stats.Accessor, op: Comparator, rhs: Value },
    // compare_stamina
    // compare_stance
    // wounds ...
    // weapon ...
    has_tag: TagSet, // bitmask with one bit set
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

pub const Technique = struct {
    id: u64,
    name: []const u8,
    damage: damage.Base,
    difficulty: f32,

    // region: null, // hit location weighting

    // multiplier for defender's roll (0.0 - 2.0):
    deflect_mult: f32 = 1.0,
    parry_mult: f32 = 1.0,
    dodge_mult: f32 = 1.0,
    counter_mult: f32 = 1.0,
};

pub const Effect = union(enum) {
    combat_technique: Technique,
    modify_stamina: struct {
        amount: i32,
        ratio: f32,
    },
    move_card: struct { from: Zone, to: Zone },
    add_condition: damage.Condition,
    remove_condition: damage.Condition,
    exhaust_card: EntityID,
    return_exhausted_card: EntityID,
    interrupt,
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
    template: *const Template,
};
