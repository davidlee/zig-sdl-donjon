const std = @import("std");
const entity = @import("entity.zig");
const armour = @import("armour.zig");
const weapon = @import("weapon.zig");
const combat = @import("combat.zig");
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const body = @import("body.zig");
const deck = @import("deck.zig");
const cards = @import("cards.zig");

const SlotMap = @import("slot_map.zig").SlotMap;
const Instance = cards.Instance;
const Template = cards.Template;

const Director = enum {
    player,
    ai,
};

// Per-entity (player or mob)
pub const State = struct {

    // Could also include:
    // focus: f32,          // Attention split across engagements
    // fatigue: f32,        // Accumulates across engagements
    pub fn init(alloc: std.mem.Allocator, stamina: f32) !State {
        return State{
            .conditions = std.ArrayList(damage.Condition).initCapacity(alloc, 5),
            .stamina = stamina,
            .stamina_available = stamina,
        };
    }

    pub fn deinit(self: State, alloc: std.mem.Allocator) void {
        self.conditions.deinit(alloc);
    }
};

pub const Reach = enum {
    far,
    medium,
    near,
    spear,
    longsword,
    sabre,
    dagger,
    clinch,
};

pub const AdvantageAxis = enum {
    balance,
    pressure,
    control,
    position,
};

const Armament = union(enum) {
    single: weapon.Instance,
    dual: struct {
        primary: weapon.Instance,
        secondary: weapon.Instance,
    },
    compound: [][]weapon.Instance,
};

const Strat = union(enum) {
    deck: deck.Deck,
    // script: BehaviourScript,
    pool: TechniquePool,
};

// Humanoid AI: simplified pool
const TechniquePool = struct {
    available: []const *cards.Template, // what they know
    in_play: std.ArrayList(*cards.Instance), // committed this tick
    cooldowns: std.AutoHashMap(cards.ID, u8), // technique -> ticks remaining

    // No hand/draw - AI picks from available based on behavior pattern
    pub fn canUse(self: *const TechniquePool, t: *const cards.Template) bool {
        return (self.cooldowns.get(t.id) orelse 0) == 0;
    }
};

// const ScriptedAction = struct {};
//
// // Creature: pure behavior script, no "cards" at all
// const BehaviourScript = struct {
//     pattern: []const ScriptedAction,
//     index: usize,
//
//     pub fn next(self: *BehaviourScript) ScriptedAction {
//         const action = self.pattern[self.index];
//         self.index = (self.index + 1) % self.pattern.len;
//         return action;
//     }
// };

const Agent = struct {
    alloc: std.mem.Allocator,
    director: Director,
    cards: Strat,
    stats: stats.Block,
    engagement: ?combat.Engagement, // npc
    // may be humanoid, or not
    body: body.Body,
    // sourced from cards.equipped
    armour: armour.Stack,
    weapons: Armament,

    // state
    balance: f32 = 1.0, // 0-1, intrinsic stability
    stamina: f32 = 0.0,
    stamina_available: f32 = 0.0,
    time_available: f32 = 1.0,
    //
    conditions: std.ArrayList(damage.Condition),
    immunities: std.ArrayList(damage.Immunity),
    resistances: std.ArrayList(damage.Resistance),
    vulnerabilities: std.ArrayList(damage.Vulnerability),
    pub fn init(
        alloc: std.mem.Allocator,
        dr: Director,
        cs: Strat,
        sb: stats.Block,
        bd: body.Body,
        stamina: f32,
    ) !Agent {
        return Agent{
            .alloc = alloc,
            .director = dr,
            .cards = cs,
            .stats = sb,
            .state = State.init(alloc, stamina),
            .body = bd,
            .armour = armour.Stack{},
            .weapons = undefined,
            .engagement = (if (dr == .ai) Engagement{} else null),

            .conditions = try std.ArrayList(damage.Condition).initCapacity(alloc, 5),
            .resistances = try std.ArrayList(damage.Resistance).initCapacity(alloc, 5),
            .immunities = try std.ArrayList(damage.Immunity).initCapacity(alloc, 5),
            .vulnerabilities = try std.ArrayList(damage.Vulnerability).initCapacity(alloc, 5),
        };
    }

    pub fn deinit(self: Agent) void {
        const alloc = self.alloc;

        self.cards.deinit(alloc);

        self.conditions.deinit(alloc);
        self.immunities.deinit(alloc);
        self.resistances.deinit(alloc);
        self.vulnerabilities.deinit(alloc);
    }
};

pub const Mob = struct {
    wounds: f32 = 0,
    state: State,
    engagement: Engagement,
    stats: stats.Block,

    // haxxx
    slot_map: SlotMap(*Instance),
    hand: std.ArrayList(*Instance),
    in_play: std.ArrayList(*Instance),

    // fatigue: f32,  // attention split
    // focus: f32,    // cumulative
    pub fn init(alloc: std.mem.Allocator) !Mob {
        return Mob{
            .slot_map = try SlotMap(*Instance).init(alloc),
            .hand = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .in_play = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .wounds = 0,
            .state = State{
                .balance = 1.0,
            },
            .engagement = Engagement{
                .pressure = 0.5,
                .control = 0.5,
                .position = 0.5,
                .range = .medium,
            },
            .stats = stats.Block.splat(5),
        };
    }

    pub fn deinit(self: *Mob, alloc: std.mem.Allocator) void {
        std.debug.print("DEINIT MOB\n", .{});
        self.hand.deinit(alloc);
        for (self.in_play.items) |item| alloc.destroy(item);
        self.in_play.deinit(alloc);
        self.slot_map.deinit();
        alloc.destroy(self);
    }

    pub fn play(self: *Mob, alloc: std.mem.Allocator, template: *const Template) !void {
        var instance = try alloc.create(Instance);
        instance.template = template;
        const id: entity.ID = try self.slot_map.insert(instance);
        instance.id = id;
        self.in_play.appendAssumeCapacity(instance);
    }
};

// Per-engagement (one per mob, attached to mob)
pub const Engagement = struct {
    // All 0-1, where 0.5 = neutral
    // >0.5 = player advantage, <0.5 = mob advantage
    pressure: f32 = 0.5,
    control: f32 = 0.5,
    position: f32 = 0.5,
    range: Reach = .far, // Current distance

    // Helpers
    pub fn playerAdvantage(self: Engagement) f32 {
        return (self.pressure + self.control + self.position) / 3.0;
    }

    pub fn mobAdvantage(self: Engagement) f32 {
        return 1.0 - self.playerAdvantage();
    }

    pub fn invert(self: Engagement) Engagement {
        return .{
            .pressure = 1.0 - self.pressure,
            .control = 1.0 - self.control,
            .position = 1.0 - self.position,
            .range = self.range,
        };
    }
};

//      // Derived: overall openness to decisive strike
// pub fn vulnerability(self: Advantage) f32 {
//     // When any axis is bad enough, you're open
//     const worst = @min(@min(self.control, self.position), self.balance);
//     // Pressure contributes but isn't sufficient alone
//     return (1.0 - worst) * 0.7 + (1.0 - self.pressure) * 0.3;
// }
// Reading Advantage
//
// From the player's perspective against a specific mob:
//
// pub fn playerVsMob(player: *Player, mob: *Mob) struct { f32, f32 } {
//     // Player's vulnerability in this engagement
//     const player_vuln = (1.0 - mob.engagement.playerAdvantage()) * 0.6
//                       + (1.0 - player.state.balance) * 0.4;
//
//     // Mob's vulnerability in this engagement
//     const mob_vuln = mob.engagement.playerAdvantage() * 0.6
//                    + (1.0 - mob.state.balance) * 0.4;
//
//     return .{ player_vuln, mob_vuln };
// }
//
// Balance contributes to vulnerability in all engagements. Relational advantage only matters for this engagement.
//
// Attention split:
// When player acts against mob A, mob B might get a "free" advantage tick:
// pub fn applyAttentionPenalty(player: *Player, focused_mob: *Mob, all_mobs: []*Mob) void {
//     for (all_mobs) |mob| {
//         if (mob != focused_mob) {
//             // Unfocused enemies gain slight positional advantage
//             mob.engagement.position -= 0.05;  // Toward mob advantage
//         }
//     }
// }
//
// Overcommitment penalty spreads:
// When player whiffs a heavy attack against mob A:
// // Player's balance drops (intrinsic)
// player.state.balance -= 0.2;
//
// // This affects ALL engagements because balance is intrinsic
// // No need to update each mob's engagement — the vulnerability
// // calculation already incorporates player.state.balance
//
// Mob coordination:
// If mobs are smart, they can exploit split attention:
// // Mob A feints to draw player's focus
// // Mob B's pattern shifts to "exploit opening" when player.engagement with A shows commitment
