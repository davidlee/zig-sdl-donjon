const std = @import("std");

const CardKind = enum {
    Action,
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

// stubs
const Trigger = struct {};
const Op = struct {};
const IfEffect = struct {};
const ForEachEffect = struct {};
const CustomEffectId = struct {};
const Predicate = struct {};
const TagSet = struct {};
const CardDefId = struct {};

pub const CardDef = struct {
    id: CardDefId,
    tags: TagSet,
    rules: []const Rule,
    // plus UI fields, costs, etc.
};

const CardInst = struct {};
