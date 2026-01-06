const std = @import("std");
// const assert = std.testing.expectEqual
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event); // std.meta.activeTag(event) for cmp
const entity = lib.entity;
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const w = @import("world.zig");
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
    modifier, // enhances another card's action
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

/// Specifies which containers a card can be played from.
/// Multiple sources can be enabled (e.g., a technique might be
/// playable from always_available OR hand if dealt as a bonus).
pub const PlayableFrom = packed struct {
    hand: bool = false, // Dealt cards in hand (CombatState.hand)
    always_available: bool = false, // Known techniques/modifiers (no card draw needed)
    spells_known: bool = false, // Always-available spells (if mana)
    equipped: bool = false, // Draw/throw/swap equipped items
    inventory: bool = false, // Use consumables
    environment: bool = false, // Pick up rubble/thrown items

    pub const hand_only: PlayableFrom = .{ .hand = true };
    pub const always_avail: PlayableFrom = .{ .always_available = true };
    pub const spell: PlayableFrom = .{ .spells_known = true };
};

pub const Trigger = union(enum) {
    on_play,
    on_draw,
    on_tick,
    on_event: EventTag,
    on_commit, // fires during commit phase (e.g., Feint)
    on_resolve, // fires during tick resolution (e.g., recovery effects)
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
    manoeuvre: bool = false,
    // Playability phase flags
    phase_selection: bool = false, // playable during card selection (default for most)
    phase_commit: bool = false, // playable during commit phase (Focus cards)

    pub fn hasTag(self: *const TagSet, required: TagSet) bool {
        const me: u15 = @bitCast(self.*);
        const req: u15 = @bitCast(required);
        return (me & req) == req; // all required bits present
    }

    pub fn hasAnyTag(self: *const TagSet, mask: TagSet) bool {
        const me: u15 = @bitCast(self.*);
        const bm: u15 = @bitCast(mask);
        return (me & bm) != 0; // at least one bit matches
    }

    /// Check if card can be played in given turn phase.
    pub fn canPlayInPhase(self: *const TagSet, phase: combat.TurnPhase) bool {
        return switch (phase) {
            .player_card_selection => self.phase_selection,
            .commit_phase => self.phase_commit,
            .player_reaction => self.reaction, // Future: reaction windows
            else => false,
        };
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
    focus: f32 = 0,
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
    // Condition predicates
    has_condition: damage.Condition, // actor must have this condition
    lacks_condition: damage.Condition, // actor must NOT have this condition
    not: *const Predicate,
    all: []const Predicate,
    any: []const Predicate,
};

pub const TargetQuery = union(enum) {
    // Enemy targeting - reads from Play.target at resolution time
    single, // one enemy chosen when play is created
    elected_n: u8, // up to n enemies chosen when play is created
    all_enemies,

    self,
    body_part: body.PartTag,
    event_source,

    // Play targeting for commit phase effects
    my_play: Predicate, // actor's plays matching predicate
    opponent_play: Predicate, // opponent's plays matching predicate
};

pub const Exclusivity = enum {
    weapon, // keeps one or both arms busy, depending on grip
    primary, // main hand only
    hand, // any hand will do
    arms, // both arms
    footwork, // moving, kicking, a knee to the face
    concentration, // eyes, voice, brain. Spells, taunts, etc. needs a value?
};

/// Which resource channels a technique occupies. Techniques using different
/// channels can be executed simultaneously (e.g., footwork + weapon).
pub const ChannelSet = packed struct {
    weapon: bool = false, // primary weapon arm(s)
    off_hand: bool = false, // shield, off-hand weapon, etc.
    footwork: bool = false, // legs, stance, movement
    concentration: bool = false, // spells, taunts, analysis

    /// Returns true if any channel is used by both sets.
    pub fn conflicts(self: ChannelSet, other: ChannelSet) bool {
        return (self.weapon and other.weapon) or
            (self.off_hand and other.off_hand) or
            (self.footwork and other.footwork) or
            (self.concentration and other.concentration);
    }

    /// Returns true if no channels are occupied.
    pub fn isEmpty(self: ChannelSet) bool {
        return !self.weapon and !self.off_hand and !self.footwork and !self.concentration;
    }

    /// Combines two channel sets (union of occupied channels).
    pub fn merge(self: ChannelSet, other: ChannelSet) ChannelSet {
        return .{
            .weapon = self.weapon or other.weapon,
            .off_hand = self.off_hand or other.off_hand,
            .footwork = self.footwork or other.footwork,
            .concentration = self.concentration or other.concentration,
        };
    }
};

pub const TechniqueID = enum {
    thrust,
    swing,
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
    channels: ChannelSet = .{ .weapon = true }, // resource channels occupied
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

/// Modifier effects for modify_play (extracted for type reference).
pub const ModifyPlay = struct {
    cost_mult: ?f32 = null,
    damage_mult: ?f32 = null,
    replace_advantage: ?combat.TechniqueAdvantage = null,
    height_override: ?body.Height = null,
};

pub const Effect = union(enum) {
    combat_technique: Technique,
    modify_stamina: struct {
        amount: i32,
        ratio: f32,
    },
    modify_focus: struct {
        amount: i32,
        ratio: f32,
    },
    move_card: struct { from: Zone, to: Zone },
    add_condition: damage.ActiveCondition,
    remove_condition: damage.Condition, // TODO: update to ActiveCondition if needed
    exhaust_card: entity.ID,
    return_exhausted_card: entity.ID,
    interrupt,
    emit_event: Event,
    // Commit phase play manipulation
    modify_play: ModifyPlay,
    cancel_play, // removes target play
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

    // Playability metadata
    playable_from: PlayableFrom = PlayableFrom.hand_only, // Default: dealt cards only
    combat_playable: bool = true, // false = out-of-combat only (e.g., don plate armor)

    // Pool card cooldown (turns until available again after use)
    // null = no cooldown, can be played unlimited times per turn
    // 1 = available again next turn (cooldown set immediately on play)
    // N = available after N turns
    cooldown: ?u8 = null,

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

    /// Check if any expression targets .single (requires play-time target selection)
    pub fn requiresSingleTarget(self: *const Template) bool {
        for (self.rules) |rule| {
            for (rule.expressions) |expr| {
                if (expr.target == .single) return true;
            }
        }
        return false;
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

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "ChannelSet.conflicts detects overlap" {
    const weapon_only: ChannelSet = .{ .weapon = true };
    const footwork_only: ChannelSet = .{ .footwork = true };
    const weapon_and_footwork: ChannelSet = .{ .weapon = true, .footwork = true };

    // Same channel conflicts
    try testing.expect(weapon_only.conflicts(weapon_only));
    try testing.expect(footwork_only.conflicts(footwork_only));

    // Different channels don't conflict
    try testing.expect(!weapon_only.conflicts(footwork_only));
    try testing.expect(!footwork_only.conflicts(weapon_only));

    // Partial overlap conflicts
    try testing.expect(weapon_only.conflicts(weapon_and_footwork));
    try testing.expect(weapon_and_footwork.conflicts(weapon_only));
}

test "ChannelSet.conflicts is symmetric" {
    const a: ChannelSet = .{ .weapon = true, .off_hand = true };
    const b: ChannelSet = .{ .off_hand = true, .concentration = true };
    const c: ChannelSet = .{ .footwork = true };

    // Symmetry: a.conflicts(b) == b.conflicts(a)
    try testing.expectEqual(a.conflicts(b), b.conflicts(a));
    try testing.expectEqual(a.conflicts(c), c.conflicts(a));
    try testing.expectEqual(b.conflicts(c), c.conflicts(b));
}

test "ChannelSet.merge combines flags" {
    const a: ChannelSet = .{ .weapon = true };
    const b: ChannelSet = .{ .footwork = true };
    const merged = a.merge(b);

    try testing.expect(merged.weapon);
    try testing.expect(merged.footwork);
    try testing.expect(!merged.off_hand);
    try testing.expect(!merged.concentration);
}

test "empty ChannelSet has no conflicts" {
    const empty: ChannelSet = .{};
    const weapon_ch: ChannelSet = .{ .weapon = true };
    const all: ChannelSet = .{ .weapon = true, .off_hand = true, .footwork = true, .concentration = true };

    try testing.expect(!empty.conflicts(weapon_ch));
    try testing.expect(!empty.conflicts(all));
    try testing.expect(!empty.conflicts(empty));
    try testing.expect(empty.isEmpty());
}

test "ChannelSet.isEmpty" {
    const empty: ChannelSet = .{};
    const weapon_ch: ChannelSet = .{ .weapon = true };

    try testing.expect(empty.isEmpty());
    try testing.expect(!weapon_ch.isEmpty());
}

test "Template.requiresSingleTarget detects .single targeting" {
    // Template with .single target
    const single_target_template = Template{
        .id = 1,
        .kind = .action,
        .name = "test single",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 0 },
        .tags = .{},
        .rules = &.{.{
            .trigger = .on_resolve,
            .valid = .always,
            .expressions = &.{.{
                .effect = .interrupt,
                .filter = null,
                .target = .single,
            }},
        }},
    };

    // Template with .all_enemies target
    const all_enemies_template = Template{
        .id = 2,
        .kind = .action,
        .name = "test all",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 0 },
        .tags = .{},
        .rules = &.{.{
            .trigger = .on_resolve,
            .valid = .always,
            .expressions = &.{.{
                .effect = .interrupt,
                .filter = null,
                .target = .all_enemies,
            }},
        }},
    };

    // Template with no expressions
    const empty_template = Template{
        .id = 3,
        .kind = .action,
        .name = "test empty",
        .description = "",
        .rarity = .common,
        .cost = .{ .stamina = 0 },
        .tags = .{},
        .rules = &.{},
    };

    try testing.expect(single_target_template.requiresSingleTarget());
    try testing.expect(!all_enemies_template.requiresSingleTarget());
    try testing.expect(!empty_template.requiresSingleTarget());
}
