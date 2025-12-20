const std = @import("std");
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event); // std.meta.activeTag(event) for cmp
const EntityID = @import("entity.zig").EntityID;

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

pub const Effect = union(enum) {
    Op: Op, // the boring, composable ops
    If: IfEffect, // condition + then/else
    ForEach: ForEachEffect, // query + effect
    Custom: CustomEffectId, // escape hatch
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

// stubs
const IfEffect = struct {};
const ForEachEffect = struct {};
const CustomEffectId = struct {};
const Predicate = struct {};
const TagSet = struct {};

const CardID = u16;

pub const CardDef = struct {
    id: CardID,
    tags: TagSet,
    rules: []const Rule,
    // plus UI fields, costs, etc.
};

const CardInst = struct { id: EntityID };
