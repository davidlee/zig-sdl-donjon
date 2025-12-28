const std = @import("std");
// const assert = std.testing.expectEqual
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event); // std.meta.activeTag(event) for cmp
const entity = @import("entity.zig");
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const TechniqueEntries = @import("card_list.zig").TechniqueEntries;

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
    exhaust,
    // active_passives,
    // active_meta,
    // active_reactions,
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
    weapon_category: weapon.Category,
    weapon_reach: struct { op: Comparator, value: combat.Reach },
    range: struct { op: Comparator, value: combat.Reach },
    advantage_threshold: struct { axis: combat.AdvantageAxis, op: Comparator, value: f32 },
    not: *const Predicate,
    all: []const Predicate,
    any: []const Predicate,
};

pub const Selector = struct {
    id: entity.ID,
};

pub const TargetQuery = union(enum) {
    single: Selector, // e.g. explicit target chosen during play
    all_enemies,
    self,
    body_part: body.PartTag,
    event_source,
};

pub const Exclusivity = enum {
    weapon, // keeps one or both arms busy, depending on grip
    primary, // main hand only
    hand, // any hand will do
    arms, // both arms
    footwork, // moving, kicking, a knee to the face
    concentration, // eyes, voice, brain. Spells, taunts, etc. needs a value?
};

pub const TechniqueID = enum {
    thrust,
    swing,
    feint,
    deflect,
    parry,
    block,
    riposte,
};

/// Which weapon profile an attack uses
pub const AttackMode = enum {
    thrust, // uses weapon.thrust
    swing, // uses weapon.swing
    ranged, // uses weapon.ranged (future)
    none, // defensive technique, no weapon profile
};

pub const Technique = struct {
    id: TechniqueID,
    name: []const u8,
    damage: damage.Base,
    difficulty: f32,
    exclusivity: Exclusivity = .weapon,
    attack_mode: AttackMode = .swing, // which weapon profile to use

    // Hit location targeting
    target_height: body.Height = .mid,
    secondary_height: ?body.Height = null, // for attacks that span zones

    // Defense guard position (for defensive techniques)
    guard_height: ?body.Height = null, // null = not a defensive technique
    covers_adjacent: bool = false, // if true, partial coverage of adjacent heights

    // multiplier for defender's roll (0.0 - 2.0):
    deflect_mult: f32 = 1.0,
    parry_mult: f32 = 1.0,
    dodge_mult: f32 = 1.0,
    counter_mult: f32 = 1.0,

    // technique-specific advantage overrides (null = use defaults)
    advantage: ?combat.TechniqueAdvantage = null,

    pub fn byID(comptime id: TechniqueID) Technique {
        inline for (TechniqueEntries) |tn| {
            if (tn.id == id) return tn;
        }
        @compileError("unknown technique: " ++ @tagName(id));
    }
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
    exhaust_card: entity.ID,
    return_exhausted_card: entity.ID,
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

    /// Extract combat technique from rules (first combat_technique effect found)
    pub fn getTechnique(self: *const Template) ?*const Technique {
        const result = self.getTechniqueWithExpression();
        return if (result) |r| r.technique else null;
    }

    /// Extract combat technique and its containing expression
    pub fn getTechniqueWithExpression(self: *const Template) ?struct {
        technique: *const Technique,
        expression: *const Expression,
    } {
        for (self.rules) |rule| {
            for (rule.expressions) |*expr| {
                switch (expr.effect) {
                    .combat_technique => |*tech| return .{
                        .technique = tech,
                        .expression = expr,
                    },
                    else => {},
                }
            }
        }
        return null;
    }
};

pub const Instance = struct {
    id: entity.ID,
    template: *const Template,
};

// when cards are played, the level of commitment modifies the effects
// no reward without risk ...
pub const Stakes = enum {
    probing,
    guarded,
    committed,
    reckless,

    /// Modifier to base hit chance
    pub fn hitChanceBonus(self: Stakes) f32 {
        return switch (self) {
            .probing => -0.1,
            .guarded => 0.0,
            .committed => 0.1,
            .reckless => 0.2,
        };
    }

    /// Multiplier for damage output
    pub fn damageMultiplier(self: Stakes) f32 {
        return switch (self) {
            .probing => 0.4,
            .guarded => 1.0,
            .committed => 1.4,
            .reckless => 2.0,
        };
    }

    /// Multiplier for advantage effects (higher stakes = bigger swings)
    pub fn advantageMultiplier(self: Stakes, success: bool) f32 {
        return switch (self) {
            .probing => 0.5,
            .guarded => 1.0,
            .committed => if (success) 1.25 else 1.5,
            .reckless => if (success) 1.5 else 2.0,
        };
    }
};
