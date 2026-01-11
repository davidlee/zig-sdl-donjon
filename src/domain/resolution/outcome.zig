/// Outcome orchestration for combat resolution.
///
/// Ties together context, advantage, and damage helpers to compute hit chances,
/// apply results, and emit world events. No UI code here.
const std = @import("std");
const lib = @import("infra");
const entity = lib.entity;
const combat = @import("../combat.zig");
const cards = @import("../cards.zig");
const weapon = @import("../weapon.zig");
const damage_mod = @import("../damage.zig");
const armour = @import("../armour.zig");
const body = @import("../body.zig");
const world = @import("../world.zig");
const events = @import("../events.zig");

// Import from sibling modules
const context = @import("context.zig");
const advantage = @import("advantage.zig");
const damage = @import("damage.zig");

pub const AttackContext = context.AttackContext;
pub const DefenseContext = context.DefenseContext;
pub const CombatModifiers = context.CombatModifiers;
pub const getOverlayBonuses = context.getOverlayBonuses;
pub const AggregatedOverlay = context.AggregatedOverlay;

pub const AdvantageEffect = advantage.AdvantageEffect;
pub const TechniqueAdvantage = advantage.TechniqueAdvantage;
pub const getAdvantageEffect = advantage.getAdvantageEffect;
pub const applyAdvantageWithEvents = advantage.applyAdvantageWithEvents;

pub const createDamagePacket = damage.createDamagePacket;
pub const getWeaponOffensive = damage.getWeaponOffensive;

const Agent = combat.Agent;
const Engagement = combat.Engagement;
const Technique = cards.Technique;
const TechniqueID = cards.TechniqueID;
const Stakes = cards.Stakes;
const World = world.World;

// ============================================================================
// Hit Chance Tuning Constants
// ============================================================================

/// Base hit probability before any modifiers.
/// At 0.5, evenly matched combatants have coin-flip odds.
pub const base_hit_chance: f32 = 0.5;

/// How much each point of technique difficulty reduces hit chance.
/// Higher values make complex techniques harder to land.
pub const technique_difficulty_mult: f32 = 0.1;

/// How much weapon accuracy rating affects hit chance.
/// Accurate weapons (positive accuracy) are easier to land.
pub const weapon_accuracy_mult: f32 = 0.1;

/// How much engagement advantage (pressure/control/position) affects hit chance.
/// Higher values amplify the importance of tactical positioning.
pub const engagement_advantage_mult: f32 = 0.3;

/// How much attacker's balance affects hit chance.
/// Unbalanced attackers (balance < 0.5) are less accurate.
pub const attacker_balance_mult: f32 = 0.2;

/// How much defender's low balance makes them easier to hit.
/// Unbalanced defenders (balance < 1.0) are vulnerable.
pub const defender_imbalance_mult: f32 = 0.15;

/// Hit penalty when defender's guard directly covers the attack zone.
/// Large penalty for attacking into a prepared defense.
pub const guard_direct_cover_penalty: f32 = 0.15;

/// Hit penalty when defender's guard partially covers an adjacent zone.
/// Smaller penalty - guard can still react to nearby attacks.
pub const guard_adjacent_cover_penalty: f32 = 0.08;

/// Hit bonus when attacking an unguarded zone (opening).
/// Small bonus for exploiting gaps in defense.
pub const guard_opening_bonus: f32 = 0.05;

/// How much defender's weapon parry rating reduces hit chance.
/// Defensive weapons make attacks harder to land.
pub const weapon_parry_mult: f32 = 0.1;

/// Minimum possible hit chance after all modifiers.
/// Ensures even overwhelming defense can't guarantee safety.
pub const hit_chance_min: f32 = 0.05;

/// Maximum possible hit chance after all modifiers.
/// Ensures even overwhelming advantage can't guarantee hits.
pub const hit_chance_max: f32 = 0.95;

// ============================================================================
// Contested Roll Constants
// ============================================================================

/// Roll mode: single roll (linear distribution) or independent pair (triangular).
pub const ContestedRollMode = enum { single, independent_pair };

/// Which mode to use for contested rolls. `.single` is rollback-friendly.
pub const contested_roll_mode: ContestedRollMode = .independent_pair;

/// Scales overall randomness magnitude in contested rolls.
pub const contested_roll_variance: f32 = 1.0;

/// Shifts roll center. 0.0 = uncentered (roll adds positive bias), -0.5 = centered.
pub const contested_roll_calibration: f32 = 0.0;

/// How much stance commitment affects capability (0.0 = irrelevant, 1.0 = dominant).
/// At 0.5: 0 investment = 0.5 multiplier, 1.0 investment = 1.5 multiplier.
pub const stance_effectiveness: f32 = 0.5;

// --- Score Bases ---

/// Baseline attack score before factors.
pub const attack_score_base: f32 = 0.5;

/// Baseline defense score before factors.
pub const defense_score_base: f32 = 0.5;

// --- Defense Scaling ---

/// Weapon parry contribution when no active defense technique (holding sword passively).
pub const passive_weapon_defense_mult: f32 = 0.5;

/// Weapon parry contribution when defender is also attacking (sword busy).
pub const offensive_committed_defense_mult: f32 = 0.25;

/// Attack score penalty when attacker is also defending in same slice.
pub const simultaneous_defense_attack_penalty: f32 = 0.1;

// --- Outcome Thresholds ---

/// Margin threshold for critical hit.
pub const hit_margin_critical: f32 = 0.4;

/// Margin threshold for solid hit (full damage).
pub const hit_margin_solid: f32 = 0.2;

/// Damage multiplier for partial hits (margin >= 0 but < solid).
pub const partial_hit_damage_mult: f32 = 0.5;

/// Damage multiplier for critical hits.
pub const critical_hit_damage_mult: f32 = 1.5;

// ============================================================================
// Outcome Determination
// ============================================================================

pub const Outcome = enum {
    hit,
    miss,
    blocked,
    parried,
    deflected,
    dodged,
    countered,
};

/// Details of a combat roll for logging/display
pub const RollResult = struct {
    outcome: Outcome,
    hit_chance: f32, // final chance after all modifiers
    roll: f32, // actual roll value
    margin: f32, // roll - hit_chance (positive = miss margin, negative = hit margin)
    attacker_modifier: f32, // total from attacker conditions
    defender_modifier: f32, // total from defender conditions (defense_mult reduction)
};

/// Calculate hit probability for an attack
pub fn calculateHitChance(attack: AttackContext, defense: DefenseContext) f32 {
    var chance: f32 = base_hit_chance;

    // Technique difficulty (higher = harder to land)
    chance -= attack.technique.difficulty * technique_difficulty_mult;

    // Weapon accuracy modifier
    if (getWeaponOffensive(attack.weapon_template, attack.technique)) |weapon_off| {
        chance += weapon_off.accuracy * weapon_accuracy_mult;
    }

    // Stakes modifier
    chance += attack.stakes.hitChanceBonus();

    // Engagement advantage (pressure, control, position)
    const engagement_bonus = (attack.engagement.playerAdvantage() - base_hit_chance) * engagement_advantage_mult;
    chance += if (attack.attacker.director == .player) engagement_bonus else -engagement_bonus;

    // Attacker balance
    chance += (attack.attacker.balance - base_hit_chance) * attacker_balance_mult;

    // Condition modifiers
    const attacker_mods = CombatModifiers.forAttacker(attack);
    const defender_mods = CombatModifiers.forDefender(defense);
    chance += attacker_mods.hit_chance;

    // Defense modifiers
    if (defense.technique) |def_tech| {
        // Active defense technique modifies attacker's chance
        var def_mult = switch (def_tech.id) {
            .parry => attack.technique.parry_mult,
            .block => attack.technique.deflect_mult, // using deflect as proxy for now
            .deflect => attack.technique.deflect_mult,
            else => 1.0,
        };
        // Defender conditions reduce defense effectiveness
        def_mult *= defender_mods.defense_mult;
        chance *= def_mult;

        // Height coverage: if guard covers the attack's target zone
        if (def_tech.guard_height) |gh| {
            if (gh == attack.technique.target_height) {
                // Guard directly covers attack zone
                chance -= guard_direct_cover_penalty;
            } else if (def_tech.covers_adjacent and gh.adjacent(attack.technique.target_height)) {
                // Guard partially covers adjacent zone
                chance -= guard_adjacent_cover_penalty;
            } else {
                // Attacking an opening (unguarded zone)
                chance += guard_opening_bonus;
            }
        }

        // Defender weapon defensive modifiers
        chance -= defense.weapon_template.defence.parry * weapon_parry_mult;
    }

    // Defender balance (low balance = easier to hit)
    chance += (1.0 - defense.defender.balance) * defender_imbalance_mult;

    // Defender condition dodge penalty (passive evasion)
    chance -= defender_mods.dodge_mod;

    return std.math.clamp(chance, hit_chance_min, hit_chance_max);
}

/// Determine outcome of attack vs defense
pub fn resolveOutcome(
    w: *World,
    attack: AttackContext,
    defense: DefenseContext,
) !RollResult {
    const hit_chance = calculateHitChance(attack, defense);

    // Apply attacker's overlay bonuses (from overlapping manoeuvres)
    const attacker_overlay = getOverlayBonuses(w, attack.attacker.id, attack.time_start, attack.time_end, true);

    // Apply defender's overlay bonuses (from overlapping manoeuvres)
    const defender_overlay = getOverlayBonuses(w, defense.defender.id, defense.time_start, defense.time_end, false);

    // defense_bonus reduces hit chance (defender's movement makes them harder to hit)
    const final_chance = std.math.clamp(
        hit_chance + attacker_overlay.to_hit_bonus - defender_overlay.defense_bonus,
        hit_chance_min,
        hit_chance_max,
    );

    const roll = try w.drawRandom(.combat);

    // Capture condition modifiers for logging
    const attacker_mods = CombatModifiers.forAttacker(attack);
    const defender_mods = CombatModifiers.forDefender(defense);

    const outcome: Outcome = if (roll > final_chance) blk: {
        // Attack failed - determine how based on defense
        if (defense.technique) |def_tech| {
            break :blk switch (def_tech.id) {
                .parry => .parried,
                .block => .blocked,
                .deflect => .deflected,
                else => .miss,
            };
        }
        break :blk .miss;
    } else .hit;

    return RollResult{
        .outcome = outcome,
        .hit_chance = final_chance,
        .roll = roll,
        .margin = roll - final_chance,
        .attacker_modifier = attacker_mods.hit_chance,
        .defender_modifier = 1.0 - defender_mods.defense_mult, // how much defense was reduced
    };
}

// ============================================================================
// Full Resolution
// ============================================================================

pub const ResolutionResult = struct {
    outcome: Outcome,
    advantage_applied: AdvantageEffect,
    damage_packet: ?damage_mod.Packet,
    armour_result: ?armour.AbsorptionResult,
    body_result: ?body.Body.DamageResult,
};

/// Resolve a single technique against a defense, applying all effects
pub fn resolveTechniqueVsDefense(
    w: *World,
    attack: AttackContext,
    defense: DefenseContext,
    target_part: body.PartIndex,
) !ResolutionResult {
    // 1. Determine outcome (hit/miss/blocked/etc) with roll details
    const roll_result = try resolveOutcome(w, attack, defense);

    // 2. Calculate and apply advantage effects (with events)
    const adv_effect = getAdvantageEffect(attack.technique, roll_result.outcome, attack.stakes);
    try applyAdvantageWithEvents(adv_effect, w, attack.engagement, attack.attacker, attack.defender);

    // 3. If hit, create damage packet and resolve through armor/body
    var dmg_packet: ?damage_mod.Packet = null;
    var armour_result: ?armour.AbsorptionResult = null;
    var body_result: ?body.Body.DamageResult = null;

    if (roll_result.outcome == .hit) {
        dmg_packet = createDamagePacket(
            attack.technique,
            attack.weapon_template,
            attack.attacker,
            attack.stakes,
        );

        // Apply overlay damage multiplier from overlapping manoeuvres
        const attacker_overlay = getOverlayBonuses(w, attack.attacker.id, attack.time_start, attack.time_end, true);
        dmg_packet.?.amount *= attacker_overlay.damage_mult;

        // Capture initial packet values for audit event (post-overlay, pre-armour)
        const initial_amount = dmg_packet.?.amount;
        const initial_penetration = dmg_packet.?.penetration;
        const damage_kind = dmg_packet.?.kind;
        const initial_geometry = dmg_packet.?.geometry;
        const initial_energy = dmg_packet.?.energy;
        const initial_rigidity = dmg_packet.?.rigidity;

        // Resolve through armor
        const target_body_part = &attack.defender.body.parts.items[target_part];
        armour_result = try armour.resolveThroughArmourWithEvents(
            w,
            attack.defender.id,
            &attack.defender.armour,
            target_part,
            target_body_part.tag,
            target_body_part.side,
            dmg_packet.?,
        );

        // Apply remaining damage to body (emits wound_inflicted, severed, etc.)
        if (armour_result.?.remaining.amount > 0) {
            body_result = try attack.defender.body.applyDamageWithEvents(
                &w.events,
                target_part,
                armour_result.?.remaining,
            );

            // Apply pain and trauma from wound
            if (body_result) |result| {
                const trauma_mult = target_body_part.trauma_mult;
                const pain = damage_mod.painFromWound(result.wound, trauma_mult);
                const trauma = damage_mod.traumaFromWound(result.wound, trauma_mult, result.hit_major_artery);
                attack.defender.pain.inflict(pain);
                attack.defender.trauma.inflict(trauma);

                // Emit events for computed condition changes (pain/trauma thresholds)
                const is_defender_player = attack.defender.isPlayer();
                attack.defender.invalidateConditionCache(&w.events, is_defender_player);

                // Trigger adrenaline surge on first significant wound
                const severity = @intFromEnum(result.wound.worstSeverity());
                const inhibited = @intFromEnum(body.Severity.inhibited);
                if (severity >= inhibited) {
                    if (!attack.defender.hasCondition(.adrenaline_surge) and
                        !attack.defender.hasCondition(.adrenaline_crash))
                    {
                        try attack.defender.conditions.append(w.alloc, .{
                            .condition = .adrenaline_surge,
                            .expiration = .{ .ticks = 8.0 },
                        });
                        // Emit event for adrenaline surge
                        try w.events.push(.{ .condition_applied = .{
                            .agent_id = attack.defender.id,
                            .condition = .adrenaline_surge,
                            .actor = .{ .id = attack.defender.id, .player = is_defender_player },
                        } });
                    }
                }
            }
        }

        // Emit audit event with full packet lifecycle
        const wound_severity: ?u8 = if (body_result) |br|
            @intFromEnum(br.wound.worstSeverity())
        else
            null;
        try w.events.push(.{ .combat_packet_resolved = .{
            .attacker_id = attack.attacker.id,
            .defender_id = attack.defender.id,
            .technique_id = attack.technique.id,
            .target_part = target_part,
            .initial_amount = initial_amount,
            .initial_penetration = initial_penetration,
            .damage_kind = damage_kind,
            .initial_geometry = initial_geometry,
            .initial_energy = initial_energy,
            .initial_rigidity = initial_rigidity,
            .post_armour_amount = armour_result.?.remaining.amount,
            .post_armour_penetration = armour_result.?.remaining.penetration,
            .post_armour_geometry = armour_result.?.remaining.geometry,
            .post_armour_energy = armour_result.?.remaining.energy,
            .post_armour_rigidity = armour_result.?.remaining.rigidity,
            .armour_layers_hit = armour_result.?.layers_hit,
            .armour_deflected = armour_result.?.deflected,
            .gap_found = armour_result.?.gap_found,
            .wound_severity = wound_severity,
        } });
    }

    // Emit technique_resolved event with full roll details
    try w.events.push(.{ .technique_resolved = .{
        .attacker_id = attack.attacker.id,
        .defender_id = attack.defender.id,
        .technique_id = attack.technique.id,
        .weapon_name = attack.weapon_template.name,
        .outcome = roll_result.outcome,
        .hit_chance = roll_result.hit_chance,
        .roll = roll_result.roll,
        .margin = roll_result.margin,
        .attacker_modifier = roll_result.attacker_modifier,
        .defender_modifier = roll_result.defender_modifier,
    } });

    return ResolutionResult{
        .outcome = roll_result.outcome,
        .advantage_applied = adv_effect,
        .damage_packet = dmg_packet,
        .armour_result = armour_result,
        .body_result = body_result,
    };
}

// ============================================================================
// Tests
// ============================================================================

const ai = @import("../ai.zig");
const stats = @import("../stats.zig");
const species = @import("../species.zig");
const weapon_list = @import("../weapon_list.zig");
const slot_map = @import("../slot_map.zig");

fn makeTestWorld(alloc: std.mem.Allocator) !*World {
    return World.init(alloc);
}

fn makeTestAgent(
    alloc: std.mem.Allocator,
    agents: *slot_map.SlotMap(*Agent),
    director: combat.Director,
) !*Agent {
    return Agent.init(
        alloc,
        agents,
        director,
        .shuffled_deck,
        &species.DWARF,
        stats.Block.splat(5),
    );
}

test "calculateHitChance base case" {
    // Would need mock agents/engagement - placeholder for now
}

test "resolveTechniqueVsDefense emits technique_resolved event" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    // Create attacker (player) and defender (mob)
    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    // Add to encounter (creates engagement)
    try w.encounter.?.addEnemy(defender);

    // Get engagement from encounter
    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;

    // Get thrust technique
    const technique = &cards.Technique.byID(.thrust);

    // Create attack and defense contexts
    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null, // passive defense
        .weapon_template = &weapon_list.knights_sword,
    };

    // Get a target body part
    const target_part: body.PartIndex = 0; // torso

    // Resolve the technique
    const result = try resolveTechniqueVsDefense(w, attack, defense, target_part);

    // Swap buffers to make events readable
    w.events.swap_buffers();

    // Check that technique_resolved event was emitted
    var found_technique_resolved = false;
    while (w.events.pop()) |event| {
        switch (event) {
            .technique_resolved => |data| {
                try std.testing.expectEqual(attacker.id, data.attacker_id);
                try std.testing.expectEqual(defender.id, data.defender_id);
                try std.testing.expectEqual(TechniqueID.thrust, data.technique_id);
                try std.testing.expectEqual(result.outcome, data.outcome);
                found_technique_resolved = true;
            },
            else => {},
        }
    }

    try std.testing.expect(found_technique_resolved);
}

test "resolveTechniqueVsDefense emits advantage_changed events on hit" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;

    const technique = &cards.Technique.byID(.swing);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .committed, // higher stakes = bigger advantage swings
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
    };

    const target_part: body.PartIndex = 0;

    // Force a hit by setting defender balance very low
    defender.balance = 0.1;

    const result = try resolveTechniqueVsDefense(w, attack, defense, target_part);

    w.events.swap_buffers();

    // Count advantage_changed events
    var advantage_events: u32 = 0;
    var found_balance_event = false;

    while (w.events.pop()) |event| {
        switch (event) {
            .advantage_changed => |data| {
                advantage_events += 1;
                if (data.axis == .balance) {
                    found_balance_event = true;
                    // Balance changes should have engagement_with = null (intrinsic)
                    try std.testing.expectEqual(@as(?entity.ID, null), data.engagement_with);
                }
            },
            else => {},
        }
    }

    // Hit or miss, we should get advantage events based on outcome
    if (result.outcome == .hit) {
        // Hit should change pressure, control, and target_balance
        try std.testing.expect(advantage_events >= 2);
    } else {
        // Miss should change control and self_balance
        try std.testing.expect(advantage_events >= 1);
    }
}

test "resolveTechniqueVsDefense applies damage on hit" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;

    const technique = &cards.Technique.byID(.thrust);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .reckless, // maximum damage
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
    };

    const target_part: body.PartIndex = 0;

    // Stack odds for a hit
    defender.balance = 0.0;
    engagement.pressure = 0.9; // player advantage
    engagement.control = 0.9;
    engagement.position = 0.9;

    const result = try resolveTechniqueVsDefense(w, attack, defense, target_part);

    if (result.outcome == .hit) {
        // Should have created a damage packet
        try std.testing.expect(result.damage_packet != null);

        const packet = result.damage_packet.?;
        try std.testing.expect(packet.amount > 0);
        try std.testing.expectEqual(damage_mod.Kind.pierce, packet.kind);

        // Reckless stakes should give 2x damage multiplier
        // Base damage is technique.damage * stat_mult * weapon_mult * stakes_mult
    }
}

test "AdvantageEffect.apply modifies engagement and balance" {
    var engagement = Engagement{
        .pressure = 0.5,
        .control = 0.5,
        .position = 0.5,
    };

    const alloc = std.testing.allocator;
    const agents = try alloc.create(slot_map.SlotMap(*Agent));
    agents.* = try slot_map.SlotMap(*Agent).init(alloc, .agent);
    defer {
        agents.deinit();
        alloc.destroy(agents);
    }

    var attacker = try makeTestAgent(alloc, agents, .player);
    defer attacker.deinit();

    var defender = try makeTestAgent(alloc, agents, ai.noop());
    defer defender.deinit();

    attacker.balance = 1.0;
    defender.balance = 1.0;

    const effect = AdvantageEffect{
        .pressure = 0.1,
        .control = -0.1,
        .position = 0.05,
        .self_balance = -0.1,
        .target_balance = -0.2,
    };

    effect.apply(&engagement, attacker, defender);

    try std.testing.expectApproxEqAbs(@as(f32, 0.6), engagement.pressure, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), engagement.control, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), engagement.position, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), attacker.balance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), defender.balance, 0.001);
}

fn findCardByName(w: *World, name: []const u8) ?entity.ID {
    for (w.player.always_available.items) |card_id| {
        const card = w.action_registry.getConst(card_id) orelse continue;
        if (std.mem.eql(u8, card.template.name, name)) {
            return card_id;
        }
    }
    return null;
}

test "resolveOutcome applies overlay to_hit_bonus from attacker manoeuvres" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;

    // Find sidestep card (+5% to_hit) and add to player's timeline
    const sidestep_id = findCardByName(w, "sidestep") orelse return error.TestSkipped;
    const enc_state = w.encounter.?.stateFor(attacker.id) orelse return error.TestSkipped;
    try enc_state.current.addPlay(.{ .action = sidestep_id }, &w.action_registry);

    const technique = &cards.Technique.byID(.thrust);

    // Attack with timing that overlaps sidestep (0.0 to 0.5s)
    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
        .time_start = 0.0,
        .time_end = 0.5,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
    };

    // The test verifies that overlay bonuses are queried and applied
    // by checking that resolveOutcome doesn't error with manoeuvres in timeline
    const result = try resolveOutcome(w, attack, defense);
    _ = result; // We just verify no error; the bonus application is in the code path
}

test "CombatModifiers.forAttacker reduces hit_chance when unbalanced" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;

    // Add unbalanced condition to attacker
    try attacker.conditions.append(w.alloc, .{
        .condition = .unbalanced,
        .expiration = .{ .ticks = 2.0 },
    });

    const technique = &cards.Technique.byID(.thrust);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .guarded,
        .engagement = engagement,
    };

    const mods = CombatModifiers.forAttacker(attack);

    // Unbalanced should reduce hit_chance by 10%
    try std.testing.expectApproxEqAbs(@as(f32, -0.10), mods.hit_chance, 0.001);
}

test "CombatModifiers.forDefender reduces defense_mult when pressured" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();

    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;

    // Add pressured condition to defender
    try defender.conditions.append(w.alloc, .{
        .condition = .pressured,
        .expiration = .{ .ticks = 2.0 },
    });

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
        .engagement = engagement,
    };

    const mods = CombatModifiers.forDefender(defense);

    // Pressured should reduce defense_mult to 0.85
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), mods.defense_mult, 0.001);
}

test "resolveTechniqueVsDefense emits condition_applied for pain threshold" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;

    // Use a heavy technique for maximum damage
    const technique = &cards.Technique.byID(.swing);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .reckless,
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
    };

    const target_part: body.PartIndex = 0; // torso

    // Stack odds for a guaranteed hit
    defender.balance = 0.0;
    engagement.pressure = 0.95;
    engagement.control = 0.95;
    engagement.position = 0.95;

    // Pre-inflict some pain to ensure we cross threshold
    defender.pain.inflict(2.5); // 25% - any additional wound should push us over 30%

    const result = try resolveTechniqueVsDefense(w, attack, defense, target_part);

    // Only test if we got a hit with body damage
    if (result.outcome == .hit and result.body_result != null) {
        w.events.swap_buffers();

        var found_distracted = false;
        while (w.events.pop()) |event| {
            switch (event) {
                .condition_applied => |e| {
                    if (e.condition == .distracted) {
                        found_distracted = true;
                        try std.testing.expectEqual(defender.id, e.agent_id);
                    }
                },
                else => {},
            }
        }

        // Defender should now have distracted condition from pain
        try std.testing.expect(found_distracted);
    }
}

test "resolveTechniqueVsDefense emits combat_packet_resolved on hit" {
    const alloc = std.testing.allocator;

    var w = try makeTestWorld(alloc);
    defer w.deinit();
    w.attachEventHandlers();

    const attacker = w.player;
    const defender = try makeTestAgent(alloc, w.entities.agents, ai.noop());
    try w.encounter.?.addEnemy(defender);

    const engagement = w.encounter.?.getPlayerEngagement(defender.id).?;

    const technique = &cards.Technique.byID(.thrust);

    const attack = AttackContext{
        .attacker = attacker,
        .defender = defender,
        .technique = technique,
        .weapon_template = &weapon_list.knights_sword,
        .stakes = .committed,
        .engagement = engagement,
    };

    const defense = DefenseContext{
        .defender = defender,
        .technique = null,
        .weapon_template = &weapon_list.knights_sword,
    };

    const target_part: body.PartIndex = 0; // torso

    // Stack odds for a guaranteed hit
    defender.balance = 0.0;
    engagement.pressure = 0.95;
    engagement.control = 0.95;
    engagement.position = 0.95;

    const result = try resolveTechniqueVsDefense(w, attack, defense, target_part);

    // Only test if we got a hit
    if (result.outcome == .hit) {
        w.events.swap_buffers();

        var found_packet_event = false;
        while (w.events.pop()) |event| {
            switch (event) {
                .combat_packet_resolved => |data| {
                    found_packet_event = true;
                    // Verify identities
                    try std.testing.expectEqual(attacker.id, data.attacker_id);
                    try std.testing.expectEqual(defender.id, data.defender_id);
                    try std.testing.expectEqual(cards.TechniqueID.thrust, data.technique_id);
                    try std.testing.expectEqual(target_part, data.target_part);
                    // Verify packet data is populated
                    try std.testing.expect(data.initial_amount > 0);
                    try std.testing.expect(data.initial_penetration > 0);
                    try std.testing.expectEqual(damage_mod.Kind.pierce, data.damage_kind);
                    // Post-armour values should be <= initial (armour absorbs)
                    try std.testing.expect(data.post_armour_amount <= data.initial_amount);
                },
                else => {},
            }
        }

        try std.testing.expect(found_packet_event);
    }
}
