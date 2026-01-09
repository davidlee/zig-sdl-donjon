/// Curated card template lists for development and tests.
///
/// Provides compile-time access to named card templates (starter deck, pools).
/// Does not own runtime registries; callers still register templates elsewhere.
const std = @import("std");
const Event = @import("events.zig").Event;

const body = @import("body.zig");
const cards = @import("cards.zig");
const combat = @import("combat.zig");
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const weapon = @import("weapon.zig");

const Rule = cards.Rule;
const TagSet = cards.TagSet;
const Cost = cards.Cost;
const Trigger = cards.Trigger;
const Effect = cards.Effect;
const Template = cards.Template;
const Expression = cards.Expression;
const Technique = cards.Technique;
const TechniqueID = cards.TechniqueID;
const PlayableFrom = cards.PlayableFrom;

const ID = cards.ID;

pub fn byName(comptime name: []const u8) *const Template {
    inline for (BeginnerDeck) |template| {
        if (comptime std.mem.eql(u8, template.name, name)) {
            return template;
        }
    }
    inline for (BaseAlwaysAvailableTemplates) |template| {
        if (comptime std.mem.eql(u8, template.name, name)) {
            return template;
        }
    }
    @compileError("unknown card: " ++ name);
}

fn hashName(comptime name: []const u8) ID {
    return std.hash.Wyhash.hash(0, name);
}

const generated = @import("../gen/generated_data.zig");

comptime {
    @setEvalBranchQuota(20000);
}

const TechniqueRepository = struct {
    entries: []Technique,
};

pub const TechniqueEntries = generateTechniqueEntries();

fn generateTechniqueEntries() [generated.GeneratedTechniques.len]Technique {
    var entries: [generated.GeneratedTechniques.len]Technique = undefined;
    inline for (generated.GeneratedTechniques, 0..) |def, idx| {
        entries[idx] = makeTechnique(def);
    }
    return entries;
}

fn makeTechnique(def: generated.TechniqueDefinition) Technique {
    var technique = Technique{
        .id = parseTechniqueID(def.id),
        .name = def.name,
        .attack_mode = parseAttackMode(def.attack_mode),
        .channels = .{
            .weapon = def.channels.weapon,
            .off_hand = def.channels.off_hand,
            .footwork = def.channels.footwork,
        },
        .covers_adjacent = def.covers_adjacent,
        .damage = .{
            .instances = def.damage_instances,
            .scaling = def.scaling,
        },
        .difficulty = def.difficulty,
        .deflect_mult = def.deflect_mult,
        .parry_mult = def.parry_mult,
        .dodge_mult = def.dodge_mult,
        .counter_mult = def.counter_mult,
        .overlay_bonus = buildOverlay(def),
    };
    if (def.target_height) |height| technique.target_height = height;
    if (def.secondary_height) |height| technique.secondary_height = height;
    if (def.guard_height) |height| technique.guard_height = height;
    return technique;
}

fn parseTechniqueID(name: []const u8) TechniqueID {
    inline for (std.meta.fields(TechniqueID)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @field(TechniqueID, field.name);
        }
    }
    @compileError("unknown TechniqueID '" ++ name ++ "'");
}

fn parseAttackMode(value: []const u8) cards.AttackMode {
    inline for (std.meta.fields(cards.AttackMode)) |field| {
        if (std.mem.eql(u8, value, field.name)) {
            return @field(cards.AttackMode, field.name);
        }
    }
    @compileError("unknown attack mode '" ++ value ++ "'");
}

fn buildOverlay(def: generated.TechniqueDefinition) ?cards.OverlayBonus {
    const offensive =
        def.overlay_offensive_to_hit_bonus != 0 or def.overlay_offensive_damage_mult != 1;
    const defensive = def.overlay_defensive_defense_bonus != 0;
    if (!offensive and !defensive) return null;

    var bonus: cards.OverlayBonus = .{};
    if (offensive) {
        bonus.offensive = .{
            .to_hit_bonus = def.overlay_offensive_to_hit_bonus,
            .damage_mult = def.overlay_offensive_damage_mult,
        };
    }
    if (defensive) {
        bonus.defensive = .{ .defense_bonus = def.overlay_defensive_defense_bonus };
    }
    return bonus;
}

// -----------------------------------------------------------------------------
// Template helpers
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Starter deck
// -----------------------------------------------------------------------------

pub const BeginnerDeck = [_]*const Template{
    &m_high,
    &m_high,
    &m_high,
    &m_low,
    &m_low,
    &m_low,
    &m_high,
    &m_high,
    &m_high,
    &m_low,
    &m_low,
    &m_low,
    &t_breath_work,
    &t_breath_work,
    &t_probing_stare,
    &t_probing_stare,
    &t_sand_in_the_eyes,
};

const t_thrust = Template{
    .id = hashName("thrust"),
    .kind = .action,
    .name = "thrust",
    .description = "hit them with the pokey bit",
    .rarity = .common,
    .cost = .{ .stamina = 3.0, .time = 0.2 },
    .tags = .{ .melee = true, .offensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_play,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.thrust) },
            .filter = null,
            .target = .single,
        }},
    }},
};

const t_slash = Template{
    .id = hashName("slash"),
    .kind = .action,
    .name = "slash",
    .description = "slash them like a pirate",
    .rarity = .common,
    .cost = .{ .stamina = 3.0, .time = 0.3 },
    .tags = .{ .melee = true, .offensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_play,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.swing) },
            .filter = null,
            .target = .single,
        }},
    }},
};

const t_throw = Template{
    .id = hashName("throw"),
    .kind = .action,
    .name = "throw",
    .description = "hurl something at them",
    .rarity = .common,
    .cost = .{ .stamina = 2.5, .time = 0.2 },
    .tags = .{ .ranged = true, .offensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_play,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.throw) },
            .filter = null,
            .target = .single,
        }},
    }},
};

const t_shield_block = Template{
    .id = hashName("shield_block"),
    .kind = .action,
    .name = "shield block",
    .description = "shields were made to be splintered",
    .rarity = .common,
    .cost = .{ .stamina = 2.0, .time = 0.3 },
    .tags = .{ .melee = true, .defensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_play,
        .valid = .{ .weapon_category = .shield },
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.block) },
            .filter = null,
            .target = .self, // single?
        }},
    }},
};

const t_riposte = Template{
    .id = hashName("riposte"),
    .kind = .action,
    .name = "riposte",
    .description = "seize the opening",
    .rarity = .uncommon,
    .cost = .{ .stamina = 3.0, .time = 0.25 },
    .tags = .{ .melee = true, .offensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_play,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.riposte) },
            // Only hits targets where you have control >= 0.6
            .filter = .{ .advantage_threshold = .{
                .axis = .control,
                .op = .gte,
                .value = 0.6,
            } },
            .target = .single,
        }},
    }},
};

const t_deflect = Template{
    .id = hashName("deflect"),
    .kind = .action,
    .name = "deflect",
    .description = "redirect incoming attacks",
    .rarity = .common,
    .cost = .{ .stamina = 1.5, .time = 0.2 },
    .tags = .{ .melee = true, .defensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_play,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.deflect) },
            .filter = null,
            .target = .self,
        }},
    }},
};

const t_parry = Template{
    .id = hashName("parry"),
    .kind = .action,
    .name = "parry",
    .description = "beat aside their weapon",
    .rarity = .common,
    .cost = .{ .stamina = 2.5, .time = 0.15 },
    .tags = .{ .melee = true, .defensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_play,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.parry) },
            .filter = null,
            .target = .self,
        }},
    }},
};

// -----------------------------------------------------------------------------
// Manoeuvre cards - footwork that overlays with weapon techniques
// -----------------------------------------------------------------------------

const t_advance = Template{
    .id = hashName("advance"),
    .kind = .action,
    .name = "advance",
    .description = "close distance, boost damage",
    .rarity = .common,
    .cost = .{ .stamina = 1.5, .time = 0.3 },
    .tags = .{ .manoeuvre = true, .offensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{
            .{
                .effect = .{ .combat_technique = Technique.byID(.advance) },
                .filter = null,
                .target = .self,
            },
            .{
                .effect = .{ .modify_range = .{ .steps = -1 } }, // close 1 step
                .filter = null,
                .target = .single,
            },
        },
    }},
};

const t_retreat = Template{
    .id = hashName("retreat"),
    .kind = .action,
    .name = "retreat",
    .description = "open distance, boost defense",
    .rarity = .common,
    .cost = .{ .stamina = 1.0, .time = 0.2 },
    .tags = .{ .manoeuvre = true, .defensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{
            .{
                .effect = .{ .combat_technique = Technique.byID(.retreat) },
                .filter = null,
                .target = .self,
            },
            .{
                .effect = .{ .modify_range = .{ .steps = 1 } }, // open 1 step
                .filter = null,
                .target = .single,
            },
        },
    }},
};

const t_sidestep = Template{
    .id = hashName("sidestep"),
    .kind = .action,
    .name = "sidestep",
    .description = "lateral movement, boost accuracy",
    .rarity = .common,
    .cost = .{ .stamina = 1.5, .time = 0.2 },
    .tags = .{ .manoeuvre = true, .offensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.sidestep) },
            .filter = null,
            .target = .self,
        }},
    }},
};

const t_hold = Template{
    .id = hashName("hold"),
    .kind = .action,
    .name = "hold",
    .description = "stand firm (stationary penalty applies)",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0.3 },
    .tags = .{ .manoeuvre = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .combat_technique = Technique.byID(.hold) },
            .filter = null,
            .target = .self,
        }},
    }},
};

// -----------------------------------------------------------------------------
// Multi-opponent manoeuvres
// -----------------------------------------------------------------------------

const t_circle = Template{
    .id = hashName("circle"),
    .kind = .action,
    .name = "circle",
    .description = "improve position vs all enemies",
    .rarity = .common,
    .cost = .{ .stamina = 2.0, .time = 0.4 },
    .tags = .{ .manoeuvre = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{
            .{
                .effect = .{ .combat_technique = Technique.byID(.circle) },
                .filter = null,
                .target = .self,
            },
            .{
                .effect = .{ .modify_position = 0.1 },
                .filter = null,
                .target = .all_enemies,
            },
        },
    }},
};

const t_disengage = Template{
    .id = hashName("disengage"),
    .kind = .action,
    .name = "disengage",
    .description = "open range from all enemies",
    .rarity = .common,
    .cost = .{ .stamina = 2.5, .time = 0.5 },
    .tags = .{ .manoeuvre = true, .defensive = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{
            .{
                .effect = .{ .combat_technique = Technique.byID(.disengage) },
                .filter = null,
                .target = .self,
            },
            .{
                .effect = .{ .modify_range = .{ .steps = 1, .propagate = false } },
                .filter = null,
                .target = .all_enemies,
            },
        },
    }},
};

const t_pivot = Template{
    .id = hashName("pivot"),
    .kind = .action,
    .name = "pivot",
    .description = "switch focus + position bonus vs one",
    .rarity = .common,
    .cost = .{ .stamina = 1.5, .time = 0.3 },
    .tags = .{ .manoeuvre = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.always_avail,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{
            .{
                .effect = .{ .combat_technique = Technique.byID(.pivot) },
                .filter = null,
                .target = .self,
            },
            .{
                .effect = .set_primary_target, // choose a new target
                .filter = null,
                .target = .single,
            },
            .{
                .effect = .{ .modify_position = 0.15 },
                .filter = null,
                .target = .single,
            },
        },
    }},
};

/// Combat techniques available to all agents by default.
/// Populate Agent.always_available from this array.
pub const BaseAlwaysAvailableTemplates = [_]*const Template{
    &t_thrust,
    &t_slash,
    &t_throw,
    &t_deflect,
    &t_parry,
    &t_shield_block,
    &t_riposte,
    &m_feint,
    // Manoeuvres
    &t_advance,
    &t_retreat,
    &t_sidestep,
    &t_hold,
    // Multi-opponent manoeuvres
    &t_circle,
    &t_disengage,
    &t_pivot,
};

// -----------------------------------------------------------------------------
// Modifier cards - attach to plays during commit phase
// Stacking multiple modifiers escalates stakes (2 = committed, 3+ = reckless)
// -----------------------------------------------------------------------------

const m_high = Template{
    .id = hashName("high"),
    .kind = .modifier,
    .name = "high",
    .description = "strike high - more damage, harder to land",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0 },
    .tags = .{ .offensive = true, .phase_commit = true },
    .icon = .y,
    .rules = &.{.{
        .trigger = .on_commit,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .modify_play = .{
                .damage_mult = 1.2,
                .height_override = .high,
            } },
            .target = .{ .my_play = .{ .has_tag = .{ .offensive = true } } },
            .filter = null,
        }},
    }},
};

const m_low = Template{
    .id = hashName("low"),
    .kind = .modifier,
    .name = "low",
    .description = "strike low - faster, less damage",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0 },
    .tags = .{ .offensive = true, .phase_commit = true },
    .icon = .u,
    .rules = &.{.{
        .trigger = .on_commit,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .modify_play = .{
                .cost_mult = 0.8,
                .damage_mult = 0.9,
                .height_override = .low,
            } },
            .target = .{ .my_play = .{ .has_tag = .{ .offensive = true } } },
            .filter = null,
        }},
    }},
};

const m_feint = Template{
    .id = hashName("feint"),
    .kind = .modifier,
    .name = "feint",
    .playable_from = .{ .always_available = true, .hand = true },
    .description = "feign commitment - no damage, gain initiative",
    .rarity = .uncommon,
    .cost = .{ .stamina = 0, .time = 0, .focus = 1 },
    .tags = .{ .offensive = true, .phase_commit = true },
    .icon = .f,
    .rules = &.{.{
        .trigger = .on_commit,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{
                .modify_play = .{
                    .damage_mult = 0,
                    .cost_mult = 0.5,
                    .replace_advantage = .{
                        // Opponent parried/blocked a feint = wasted their defense
                        .on_parried = .{ .control = 0.25, .pressure = 0.1 },
                        .on_blocked = .{ .control = 0.20 },
                        // Opponent attacked through = called your bluff
                        .on_countered = .{ .control = -0.15, .self_balance = -0.1 },
                        // "Hit" (opponent did nothing) = gained initiative
                        .on_hit = .{ .control = 0.15 },
                        // Dodged = neutral, they repositioned
                        .on_dodged = .{ .position = -0.05 },
                    },
                },
            },
            .target = .{ .my_play = .{ .has_tag = .{ .offensive = true } } },
            .filter = null,
        }},
    }},
};

// -----------------------------------------------------------------------------
// Recovery cards - utility actions that recover resources
// -----------------------------------------------------------------------------

const t_breath_work = Template{
    .id = hashName("breath work"),
    .kind = .action,
    .name = "breath work",
    .description = "steady your breathing, recover stamina",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0.1, .exhausts = true },
    .tags = .{ .skill = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.hand_only,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .modify_stamina = .{ .amount = 2, .ratio = 0 } },
            .filter = null,
            .target = .self,
        }},
    }},
};

const t_probing_stare = Template{
    .id = hashName("probing stare"),
    .kind = .action,
    .name = "probing stare",
    .description = "read your opponent, sharpen your focus",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0.1, .exhausts = true },
    .tags = .{ .skill = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.hand_only,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .modify_focus = .{ .amount = 1, .ratio = 0 } },
            .filter = null,
            .target = .self,
        }},
    }},
};

const t_sand_in_the_eyes = Template{
    .id = hashName("sand in the eyes"),
    .kind = .action,
    .name = "sand in the eyes",
    .description = "a handful of grit to blind your foe",
    .rarity = .uncommon,
    .cost = .{ .stamina = 1, .time = 0.15, .exhausts = true },
    .tags = .{ .skill = true, .debuff = true, .phase_selection = true, .phase_commit = true },
    .playable_from = PlayableFrom.hand_only,
    .rules = &.{.{
        .trigger = .on_resolve,
        .valid = .{ .range = .{ .op = .lte, .value = .sabre } }, // must be close
        .expressions = &.{.{
            .effect = .{ .add_condition = .{
                .condition = .blinded,
                .expiration = .{ .ticks = 1.0 },
            } },
            .filter = null,
            .target = .single, // targets one enemy, selected at play time
        }},
    }},
};

// -----------------------------------------------------------------------------
// Dud cards - involuntary status cards injected when conditions are gained
// These waste a play slot and may block certain card types while in hand.
// Exhaust automatically when played via .cost.exhausts = true.
// -----------------------------------------------------------------------------

/// Wince: minor distraction from pain. Just wastes time.
pub const dud_wince = Template{
    .id = hashName("wince"),
    .kind = .action,
    .name = "Wince",
    .description = "Involuntary flinch. Wastes time.",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0.6, .exhausts = true },
    .tags = .{ .involuntary = true, .phase_selection = true },
    .playable_from = PlayableFrom.hand_only,
    .rules = &.{}, // No blocking - just time cost
};

/// Tremor: trembling hands block precision techniques while in hand.
pub const dud_tremor = Template{
    .id = hashName("tremor"),
    .kind = .action,
    .name = "Trembling Hands",
    .description = "Blocks precision techniques while in hand.",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0, .exhausts = true },
    .tags = .{ .involuntary = true, .phase_selection = true },
    .playable_from = PlayableFrom.hand_only,
    .rules = &.{Rule{
        .trigger = .on_play_attempt,
        .valid = .{ .has_tag = .{ .precision = true } },
        .expressions = &.{.{ .effect = .cancel_play, .filter = null, .target = .self }},
    }},
};

/// Retch: nausea blocks finesse techniques while in hand.
pub const dud_retch = Template{
    .id = hashName("retch"),
    .kind = .action,
    .name = "Retch",
    .description = "Nausea. Blocks finesse techniques while in hand.",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0.3, .exhausts = true },
    .tags = .{ .involuntary = true, .phase_selection = true },
    .playable_from = PlayableFrom.hand_only,
    .rules = &.{Rule{
        .trigger = .on_play_attempt,
        .valid = .{ .has_tag = .{ .finesse = true } },
        .expressions = &.{.{ .effect = .cancel_play, .filter = null, .target = .self }},
    }},
};

/// Stagger: unsteady footing blocks manoeuvres while in hand.
pub const dud_stagger = Template{
    .id = hashName("stagger"),
    .kind = .action,
    .name = "Stagger",
    .description = "Unsteady footing. Blocks manoeuvres while in hand.",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0.4, .exhausts = true },
    .tags = .{ .involuntary = true, .phase_selection = true },
    .playable_from = PlayableFrom.hand_only,
    .rules = &.{Rule{
        .trigger = .on_play_attempt,
        .valid = .{ .has_tag = .{ .manoeuvre = true } },
        .expressions = &.{.{ .effect = .cancel_play, .filter = null, .target = .self }},
    }},
};

/// Blackout: severe trauma blocks offensive techniques while in hand.
pub const dud_blackout = Template{
    .id = hashName("blackout"),
    .kind = .action,
    .name = "Blackout",
    .description = "Vision swimming. Blocks offensive techniques while in hand.",
    .rarity = .common,
    .cost = .{ .stamina = 0, .time = 0.5, .exhausts = true },
    .tags = .{ .involuntary = true, .phase_selection = true },
    .playable_from = PlayableFrom.hand_only,
    .rules = &.{Rule{
        .trigger = .on_play_attempt,
        .valid = .{ .has_tag = .{ .offensive = true } },
        .expressions = &.{.{ .effect = .cancel_play, .filter = null, .target = .self }},
    }},
};

/// Lookup table for condition → dud card template mapping.
/// Used by event processor to inject dud cards when conditions are gained.
pub const condition_dud_cards = blk: {
    var arr = std.EnumArray(damage.Condition, ?*const Template).initFill(null);
    arr.set(.distracted, &dud_wince);
    arr.set(.trembling, &dud_tremor);
    arr.set(.nauseous, &dud_retch);
    arr.set(.unsteady, &dud_stagger);
    arr.set(.reeling, &dud_blackout);
    break :blk arr;
};
