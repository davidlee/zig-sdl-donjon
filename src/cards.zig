const std = @import("std");
const lib = @import("infra");
const events = lib.events;

const CardKind = enum {
    Action,
    Passive,
    Reaction,
    Encounter,
    Environment,
    Mob,
    Ally,
    Resource,
    MetaProgression,
};

pub const TriggerKind = enum {
    OnPlay,
    OnDraw,
    OnSecond,
    OnEvent, // parameterized by EventKind
};

pub const Effect = union(enum) {
    Op: Op, // the boring, composable ops
    If: IfEffect, // condition + then/else
    ForEach: ForEachEffect, // query + effect
    Custom: CustomEffectId, // escape hatch
};

pub const Rule = struct {
    trigger: Trigger,
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
const Trigger = lib.events.Event;
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
