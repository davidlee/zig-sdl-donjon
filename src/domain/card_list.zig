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

const TechniqueRepository = struct {
    entries: []Technique,
};

pub const TechniqueEntries = [_]Technique{
    .{
        .id = .thrust,
        .name = "thrust",
        .attack_mode = .thrust,
        .target_height = .mid, // thrusts target center mass
        .damage = .{
            .instances = &.{
                .{ .amount = 1.0, .types = &.{.pierce} },
            },
            .scaling = .{
                .ratio = 0.5,
                .stats = .{ .average = .{ .speed, .power } },
            },
        },
        .difficulty = 0.7,
        .deflect_mult = 1.3,
        .dodge_mult = 0.5,
        .counter_mult = 1.1,
        .parry_mult = 1.2,
    },

    .{
        .id = .swing,
        .name = "swing",
        .attack_mode = .swing,
        .target_height = .high, // swings come from above
        .secondary_height = .mid, // can catch torso too
        .damage = .{
            .instances = &.{
                .{ .amount = 1.0, .types = &.{.slash} },
            },
            .scaling = .{
                .ratio = 1.2,
                .stats = .{ .average = .{ .speed, .power } },
            },
        },
        .difficulty = 1.0,
        .deflect_mult = 1.0,
        .dodge_mult = 1.2,
        .counter_mult = 1.3,
        .parry_mult = 1.2,
    },

    // Defensive techniques - guard positions
    // Deflect: gentle redirection, cheap, covers adjacent heights
    .{
        .id = .deflect,
        .name = "deflect",
        .attack_mode = .none,
        .guard_height = .mid,
        .covers_adjacent = true, // can catch high/low with penalty
        .damage = .{
            .instances = &.{.{ .amount = 0.0, .types = &.{} }},
            .scaling = .{ .ratio = 0.0, .stats = .{ .stat = .power } },
        },
        .difficulty = 0.8, // easier than parry
        .deflect_mult = 1.2, // good at deflecting
        .dodge_mult = 1.0,
        .counter_mult = 0.8, // hard to counter off a deflect
        .parry_mult = 1.0,
        // Minimal advantage change - just redirects
    },

    // Parry: beat away weapon, creates opening (control gain)
    .{
        .id = .parry,
        .name = "parry",
        .attack_mode = .none,
        .guard_height = .mid, // modifiers shift high/low
        .covers_adjacent = false, // precise, must match height
        .damage = .{
            .instances = &.{.{ .amount = 0.0, .types = &.{} }},
            .scaling = .{ .ratio = 0.0, .stats = .{ .stat = .power } },
        },
        .difficulty = 1.2, // harder than deflect
        .deflect_mult = 0.8, // not great at deflecting
        .dodge_mult = 1.0,
        .counter_mult = 1.3, // good for setting up counter
        .parry_mult = 1.4, // excellent parry
        // Successful parry creates opening
        .advantage = .{
            .on_blocked = .{ .control = 0.15 }, // beat their weapon aside
            .on_parried = .{ .control = 0.20 }, // clean parry = initiative
        },
    },

    .{
        .id = .block,
        .name = "block",
        .attack_mode = .none,
        .channels = .{ .off_hand = true }, // shield technique
        .guard_height = .mid, // shield covers mid
        .covers_adjacent = true, // shields cover wide area
        .damage = .{
            .instances = &.{.{ .amount = 0.0, .types = &.{} }},
            .scaling = .{
                .ratio = 0.0,
                .stats = .{ .stat = .power },
            },
        },
        .difficulty = 1.0,
        .deflect_mult = 1.0,
        .dodge_mult = 1.0,
        .counter_mult = 1.0,
        .parry_mult = 1.0,
    },

    // Riposte: quick counter-thrust after gaining control advantage
    .{
        .id = .riposte,
        .name = "riposte",
        .attack_mode = .thrust,
        .target_height = .mid,
        .damage = .{
            .instances = &.{
                .{ .amount = 1.2, .types = &.{.pierce} }, // slightly more than thrust
            },
            .scaling = .{
                .ratio = 0.6,
                .stats = .{ .average = .{ .speed, .power } },
            },
        },
        .difficulty = 0.5, // easier when you have control
        .deflect_mult = 0.8, // hard to deflect a well-timed riposte
        .dodge_mult = 0.6, // hard to dodge
        .counter_mult = 1.5, // risky to counter a counter
        .parry_mult = 0.9,
        .advantage = .{
            .on_hit = .{ .pressure = 0.15, .control = 0.10 },
            .on_miss = .{ .control = -0.20, .self_balance = -0.10 }, // overextend on miss
        },
    },
};

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
            .target = .all_enemies,
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
            .target = .all_enemies,
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
            .target = .self,
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
            .target = .all_enemies,
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

/// Combat techniques available to all agents by default.
/// Populate Agent.always_available from this array.
pub const BaseAlwaysAvailableTemplates = [_]*const Template{
    &t_thrust,
    &t_slash,
    &t_deflect,
    &t_parry,
    &t_shield_block,
    &t_riposte,
    &m_feint,
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
        .valid = .always,
        .expressions = &.{.{
            .effect = .{ .add_condition = .{
                .condition = .blinded,
                .expiration = .{ .ticks = 1.0 },
            } },
            .filter = null,
            .target = .all_enemies,
        }},
    }},
};
