const std = @import("std");
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event); // std.meta.activeTag(event) for cmp
const EntityID = @import("entity.zig").EntityID;
const BodyPartTag = @import("body.zig").BodyPartTag;

const CardKind = enum {
    Action,
    Passive,
    Reaction,
    Encounter,
    Mob,
    // Ally,
    Environment,
    Resource,
    MetaProgression,
};

pub const TriggerKind = union(enum) {
    on_play,
    on_draw,
    on_tick,
    on_event: EventTag,
};

pub const Effect = struct {
    op: OpSpec, // tagged union with payload (damage, draw, etc.)
    predicate: ?Predicate, // optional guard
    target: TargetQuery, // query returning one or many entities/parts
    mods: ModifierHooks, // optional extra data (e.g., use stamina pipeline)
};
pub const ModifierHooks = struct {
    use_stamina_pipeline: bool = false,
    use_time_pipeline: bool = false,
};
const DamageType = enum {
    blunt,
    piercing,
    slashing,
    fire,
    acid,
    arcane,
};
const DamageInstance = struct {
    amount: i32,
    types: []const DamageType,
};
pub const DamagePacket = struct {
    instances: []const DamageInstance,
};

pub const ScalingSpec = struct {
    stat: StatAccessor = .power,
    ratio: f32 = 1.0,
};
pub const DamageKind = enum {
    physical,
    elemental,
};
pub const ActionRef = ?u32;
pub const ActionSpec = struct {
    duration: f32 = 1.0,
    cost: CardCost,
};
pub const Zone = enum {
    draw,
    hand,
    discard,
    exhaust,
    in_play,
};
pub const ModifierSpec = struct {};
pub const OpSpec = union(enum) {
    ApplyDamage: struct {
        base: DamagePacket, // numbers derived from card definition
        scaling: ScalingSpec, // e.g. { stat = .power, ratio = 0.6 }
        damage_kind: DamageKind,
        action_ref: ActionRef, // optional, for logging/interrupt
    },
    StartAction: ActionSpec,
    ModifyStamina: struct { amount: i32 },
    MoveCard: struct { from: Zone, to: Zone },
    AddModifier: ModifierSpec,
    EmitEvent: Event,
};
pub const Predicate = union(enum) {
    AlwaysTrue,
    CompareStat: struct { lhs: StatAccessor, op: CmpOp, rhs: Value },
    HasTag: Tag,
    Not: *Predicate,
    And: []const Predicate,
    Or: []const Predicate,
};
pub const Tag = enum {
    none,
};
pub const StatAccessor = enum {
    power,
    speed,
    agility,
    dexterity,
    fortitude,
    endurance,
    acuity,
    will,
    intuition,
    presence,
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
    stat: StatAccessor,
};
pub const TargetQuery = union(enum) {
    Single: Selector, // e.g. explicit target chosen during play
    AllEnemies,
    Self,
    BodyPart: BodyPartTag,
    EventSource,
};
pub const Selector = struct {
    id: EntityID,
};
pub const Rule = struct {
    trigger: TriggerKind,
    predicate: ?Predicate,
    effects: []const Effect,
};

const Op = union(enum) {
    ApplyDamage,
    InflictWound,
    AddCondition, // Condition
    RemoveCondition, // Condition
    ExhaustCard, // zone (constraint)
    ReturnExhaustedCard,
    InterruptAction,
};

const TagSet = struct {};

const CardID = u16;

pub const CardDef = struct {
    id: CardID,
    tags: TagSet,
    rules: []const Rule,
    // plus UI fields, costs, etc.
};

const CardInst = struct { id: EntityID };

const CardCost = struct {
    stamina: f32,
    time: f32,
    exhausts: bool,
};
