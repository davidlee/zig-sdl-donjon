REV 3

Combat isn't HP attrition — it's advantage accumulation toward a decisive moment. The wound system is severe enough that landing clean is nearly fight-ending. So the game is:

  1. Probe and pressure — test their defenses, accumulate small advantages
  2. Create opening — through superior footwork, feints, breaking their guard
  3. Exploit — the one thrust that ends it

  The challenge is making phases 1 and 2 engaging, not just "grind stance meter to zero."

  ---
  Stance as Multidimensional Continuous State

  Your instinct toward f32 0-1 values is right. But "stance" might be several things:

  pub const Advantage = struct {
      // Relative to opponent, can be negative (disadvantage)

      pressure: f32,      // Accumulated offensive momentum
                          // High = they're retreating, reacting
                          // Low = you're on the back foot

      control: f32,       // Weapon/line control
                          // High = your blade is where you want it
                          // Low = blade out of position, bound, beat aside

      position: f32,      // Spatial advantage
                          // High = good angle, inside their reach
                          // Low = overextended, wrong distance

      balance: f32,       // Physical stability
                          // High = stable, can move freely
                          // Low = off-balance, committed, recovering

      // Derived: overall openness to decisive strike
      pub fn vulnerability(self: Advantage) f32 {
          // When any axis is bad enough, you're open
          const worst = @min(@min(self.control, self.position), self.balance);
          // Pressure contributes but isn't sufficient alone
          return (1.0 - worst) * 0.7 + (1.0 - self.pressure) * 0.3;
      }
  };

  Each exchange nudges these values. Thresholds trigger qualitative effects:
  - control < 0.2 → blade bound, can't attack this tempo
  - balance < 0.3 → staggered, eating next hit clean
  - position > 0.8 → inside their guard, bonus accuracy to gaps

---

Movement as First-Class Citizen

  You're absolutely right that movement is half the game. The "footwork as overlay" idea is great — it solves several problems:

  pub const Technique = struct {
      // ...

      // Can this be played simultaneously with another technique?
      overlay_type: OverlayType,
  };

  pub const OverlayType = enum {
      none,           // Standalone only
      footwork,       // Can overlay arm techniques
      arm,            // Can receive footwork overlay
      either,         // Can overlay or be overlaid
  };

  So you might play:
  - Thrust (arm, 0.3s) + Sidestep (footwork, 0.2s) = 0.3s total
  - The footwork modifies the thrust's properties (angle, position change)

  And the counter-play:
  - They committed to a heavy swing
  - You close in (footwork) while they're mid-swing
  - Now you're inside their arc, their sword is useless, your dagger isn't

  ---
  Commitment as Explicit Axis

  "If you know you're hitting without opposition, it's really going to connect"

  Commitment could be a modifier on any offensive technique:

  pub const AttackCommitment = enum {
      probing,    // Light, safe, low damage, easy recovery
      standard,   // Normal
      committed,  // Heavy, high damage, slow recovery, balance penalty on miss
      all_in,     // Devastating if it lands, catastrophic if it doesn't
  };

  Or continuous:
  pub const DamageEffect = struct {
      base: damage.Base,
      commitment: f32,    // 0.0 = probe, 1.0 = all-in

      // Derived
      pub fn effectiveDamage(self: DamageEffect, base_mult: f32) f32 {
          return self.base.amount * base_mult * (0.5 + self.commitment * 1.0);
      }

      pub fn recoveryPenalty(self: DamageEffect) f32 {
          return self.commitment * 0.5;  // Balance cost on miss
      }
  };

  The player chooses commitment when playing the card, not at definition time. High commitment + miss = you're now at balance: 0.2 and eating their riposte.




  ---
  Weapons as Modifier Palettes

  Rather than weapon-specific techniques, weapons modify what techniques do:

  pub const Weapon = struct {
      name: []const u8,
      reach: Reach,

      // How this weapon performs each action category
      strike: WeaponProfile,
      thrust: WeaponProfile,
      parry: WeaponProfile,

      // Capabilities
      can_half_sword: bool,     // Techniques requiring this
      can_murder_stroke: bool,
      has_guard: GuardType,     // Affects parry, bind

      // Durability
      integrity: f32,
      vs_parry_degradation: f32,  // How much it suffers from blade contact
  };

  pub const WeaponProfile = struct {
      damage_mult: f32,
      speed_mult: f32,
      vs_armor: ArmorEffectiveness,
  };

  pub const ArmorEffectiveness = struct {
      vs_plate: f32,    // 0.0 = useless, 1.0 = full effect
      vs_mail: f32,
      vs_leather: f32,
      vs_cloth: f32,
  };

  So Thrust with a longsword vs plate = base_damage * weapon.thrust.vs_armor.vs_plate = tiny.

  But Thrust with a rondel dagger, after you've grappled them and found the armpit gap = different calculation entirely.

  ---
  The "Nothing Happens" Problem

  Sword vs plate shouldn't be "miss" — it should have some effect:

  pub const StrikeResult = struct {
      damage_dealt: f32,           // Often 0 vs plate

      // But also:
      stamina_cost_attacker: f32,  // Effort expended
      stamina_cost_defender: f32,  // Bracing for impact
      noise: f32,                  // Tactical information
      weapon_degradation: f32,     // Blade damage

      // Stance effects even without penetration
      pressure_delta: f32,         // You're still pressing them
      balance_delta: f32,          // Heavy hit staggers even in plate
  };

  Hammering on plate with a mace doesn't cut, but it:
  - Costs them stamina to absorb
  - Degrades their balance (concussion, being shoved)
  - Might dent the plate (armor integrity)
  - Accumulates pressure toward opening

  So there's always something happening, even when damage is zero.

  ---
  Predicates and Weapon Requirements

  Your existing predicate system can probably handle this with extensions:

  pub const Predicate = union(enum) {
      always,
      has_tag: TagSet,

      // New: weapon requirements
      weapon_has: WeaponCapability,
      weapon_reach: struct { op: Comparator, value: Reach },

      // New: advantage requirements
      advantage_threshold: struct { axis: AdvantageAxis, op: Comparator, value: f32 },

      // New: relative position
      range_is: Reach,

      // Combinators
      not: *const Predicate,
      all: []const Predicate,
      any: []const Predicate,
  };

  pub const WeaponCapability = enum {
      crossguard,      // For murder stroke
      half_sword_grip, // For half-swording
      pommel,          // For pommel strike
      spike,           // For armor-piercing
      hook,            // For disarms
  };

  Murder stroke card:
  .{
      .name = "murder stroke",
      .rules = &.{.{
          .valid = .{ .all = &.{
              .{ .weapon_has = .crossguard },
              .{ .range_is = .near },
          }},
          // ...
      }},
  }

  ---
  The Fun Challenge

  "making plate armour realistic and that actually being fun"

  The key is that fighting armored opponents is a different puzzle, not a "nothing happens" stalemate:

  1. Different viable strategies: Grapple + dagger, mace, target gaps
  2. Different tempo: Plate is slow, you can outmaneuver
  3. Different resource game: They can't turtle forever (stamina, heat exhaustion)
  4. Environmental: Push them down stairs, into mud, off a wall


REV 4

 Relational vs Intrinsic

  Intrinsic (belongs to the entity):
  - Balance — your own stability, affected by your actions and hits taken
  - Stamina — already tracked
  - Wounds — already tracked

  Relational (belongs to a pair):
  - Pressure — who's pushing whom
  - Control — whose blade is dominant in this line
  - Position — spatial advantage relative to this opponent

  The relational properties are zero-sum. If you have 0.7 pressure against mob A, mob A has 0.3 pressure against you. Same information, different perspective.

  ---
  Data Model

  // Per-entity (player or mob)
  pub const CombatantState = struct {
      balance: f32,           // 0-1, intrinsic stability

      // Could also include:
      // focus: f32,          // Attention split across engagements
      // fatigue: f32,        // Accumulates across engagements
  };

  // Per-engagement (one per mob, attached to mob)
  pub const Engagement = struct {
      // All 0-1, where 0.5 = neutral
      // >0.5 = player advantage, <0.5 = mob advantage
      pressure: f32,
      control: f32,
      position: f32,

      range: Reach,           // Current distance

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

  Attach to mob since they're the "per-opponent" entity:

  pub const Mob = struct {
      // Existing
      wounds: f32,

      // New
      state: CombatantState,
      engagement: Engagement,    // vs player
  };

  Player also has intrinsic state:

  pub const Player = struct {
      // Existing
      stamina: f32,
      stats: stats.Block,
      wounds: std.ArrayList(body.Wound),

      // New
      state: CombatantState,
      // No engagement here — it's on each mob
  };

  ---
  Reading Advantage

  From the player's perspective against a specific mob:

  pub fn playerVsMob(player: *Player, mob: *Mob) struct { f32, f32 } {
      // Player's vulnerability in this engagement
      const player_vuln = (1.0 - mob.engagement.playerAdvantage()) * 0.6
                        + (1.0 - player.state.balance) * 0.4;

      // Mob's vulnerability in this engagement
      const mob_vuln = mob.engagement.playerAdvantage() * 0.6
                     + (1.0 - mob.state.balance) * 0.4;

      return .{ player_vuln, mob_vuln };
  }

  Balance contributes to vulnerability in all engagements. Relational advantage only matters for this engagement.

  ---
  Multi-Opponent Dynamics

  With 2+ mobs, interesting things happen:

  Attention split:
  When player acts against mob A, mob B might get a "free" advantage tick:
  pub fn applyAttentionPenalty(player: *Player, focused_mob: *Mob, all_mobs: []*Mob) void {
      for (all_mobs) |mob| {
          if (mob != focused_mob) {
              // Unfocused enemies gain slight positional advantage
              mob.engagement.position -= 0.05;  // Toward mob advantage
          }
      }
  }

  Overcommitment penalty spreads:
  When player whiffs a heavy attack against mob A:
  // Player's balance drops (intrinsic)
  player.state.balance -= 0.2;

  // This affects ALL engagements because balance is intrinsic
  // No need to update each mob's engagement — the vulnerability
  // calculation already incorporates player.state.balance

  Mob coordination:
  If mobs are smart, they can exploit split attention:
  // Mob A feints to draw player's focus
  // Mob B's pattern shifts to "exploit opening" when player.engagement with A shows commitment

  ---
  Example Tick

  Situation:
  - Player vs Mob A (engagement: pressure 0.6, control 0.5, position 0.5)
  - Player vs Mob B (engagement: pressure 0.4, control 0.5, position 0.5)
  - Player balance: 0.8
  - Mob A balance: 0.7
  - Mob B balance: 0.9

  Player plays: Committed Strike against Mob A

  Resolution:
  // Player focuses on A
  applyAttentionPenalty(player, mob_a, &.{mob_a, mob_b});
  // mob_b.engagement.position: 0.5 -> 0.45 (mob B gains slight angle)

  // Strike vs Mob A
  if (strike_lands) {
      mob_a.engagement.pressure += 0.15;  // player pressing harder
      mob_a.engagement.control += 0.1;    // player has initiative
      mob_a.state.balance -= 0.2;         // mob staggered
      // damage calculated separately
  } else {
      mob_a.engagement.control -= 0.15;   // player's blade out of line
      player.state.balance -= 0.15;       // player overextended (affects BOTH engagements)
  }

  Mob B plays: Advance + Probe

  mob_b.engagement.range = .near;         // closed distance
  mob_b.engagement.position -= 0.1;       // mob gains angle (player was focused on A)
  // probe doesn't do damage but tests player's response

  After this tick:
  - Player is potentially winning vs A but exposed vs B
  - Player's balance affects both fights

  ---
  The "Two Clocks Same Time" Question

  You asked about consistency. Here's how it resolves:

  The engagements are independent because you can genuinely be in different states with different opponents. You're pressing mob A while mob B is pressing you — that's a real tactical situation, not a contradiction.

  What is shared:
  - Player's balance (if you're off-balance, you're off-balance against everyone)
  - Player's stamina
  - Player's position in space (if movement matters beyond per-engagement range)

  The model handles this by making intrinsic state (balance) affect all engagements through the vulnerability calculation, while relational state (pressure, control, position) is per-engagement.

  ---
  Open Question: Engagement Coupling

  Should engagements affect each other beyond attention split?

  Scenario: Player parries mob A's attack beautifully. Should this:
  1. Only improve player vs A engagement
  2. Also intimidate mob B (pressure shift)
  3. Also demonstrate skill to mob B (behavior change)

  Option 1 is simplest. Options 2-3 add tactical depth but complexity. Probably start with 1, layer in 2-3 as "smart mob" behaviors.

  ---







REV 2

 ---
  Key Insights from the Design Doc

  1. Simultaneous resolution — both sides commit, both resolve. Strike vs Strike = both hit.
  2. RPS core: Block > Strike > Feint > Block (and Maneuver > Feint)
  3. Time stacking — multiple cards in a tick (0.3 + 0.3 + 0.4 = 1s flurry)
  4. Overcommit — play >1s, risk interrupt, but stance erosion bonus
  5. Reactions — respond to opponent's revealed play, at cost
  6. Stance erosion — successive hits in combo erode stance (separate from damage)
  7. Mobs are asymmetric — behavior patterns, not cards

  ---
  Revised Model

  The "technique" isn't just about what it does — it's about how it interacts with the opponent's play. This is the core of simultaneous resolution.

  pub const ActionCategory = enum {
      strike,     // Offensive, deals damage. Loses to block, beats feint.
      block,      // Defensive, negates strikes. Loses to feint, beats strike.
      feint,      // Setup, wastes blocks. Loses to strike/maneuver, beats block.
      maneuver,   // Positioning. Beats feint, neutral vs others.
      recovery,   // Stamina regen. Vulnerable to everything.
      special,    // Spells, skills - custom resolution.
  };

  Technique as Union

  pub const Technique = struct {
      id: TechniqueId,
      name: []const u8,

      // Costs (universal)
      time: f32,      // Fraction of tick (0.3, 0.4, etc.)
      stamina: f32,

      // What category for RPS resolution
      category: ActionCategory,

      // What it actually does
      effect: Effect,

      // Combo/state interactions
      creates: []const CombatState = &.{},
      exploits: []const CombatState = &.{},  // Bonus if opponent has these
      requires: []const CombatState = &.{},  // Can only play if you have these
  };

  pub const Effect = union(enum) {
      damage: DamageEffect,
      defend: DefendEffect,
      setup: SetupEffect,
      movement: MovementEffect,
      restore: RestoreEffect,
      special: SpecialEffect,
  };

  Effect Types

  pub const DamageEffect = struct {
      base: damage.Base,
      accuracy: f32 = 0.0,              // Modifier to hit
      stance_erosion: f32 = 1.0,        // How much this erodes stance on hit

      // How hard to defend against (modifies opponent's defense roll)
      vs_block: f32 = 1.0,
      vs_parry: f32 = 1.0,
      vs_dodge: f32 = 1.0,

      // Bonus damage/effect if opponent is doing X
      punishes: ?ActionCategory = null,  // e.g., .recovery for "punish catch breath"
  };

  pub const DefendEffect = struct {
      kind: DefenseKind,
      effectiveness: f32,               // 1.0 = full negation

      // What it's good/bad against
      vs_damage_types: ?[]const damage.Kind = null,

      // Does successful defense open a counter?
      enables_counter: bool = false,

      // Stamina cost scaling (for blocks that cost more vs heavy hits)
      absorb_cost_ratio: f32 = 0.0,     // Extra stamina per damage absorbed
  };

  pub const DefenseKind = enum {
      block,      // Shield/weapon absorb, stamina scales with damage
      parry,      // Deflect with weapon, timing-sensitive
      dodge,      // Avoid entirely, may cost positioning
  };

  pub const SetupEffect = struct {
      // What opening/state this creates
      creates: []const CombatState,
      duration: f32,                    // How long the opening lasts

      // For AI/animation - what this looks like
      mimics: ?TechniqueId = null,

      // Stance pressure even without landing
      stance_pressure: f32 = 0.0,
  };

  pub const MovementEffect = struct {
      kind: MovementKind,
      range_change: i8,                 // -2 (closer) to +2 (farther)

      // Can this be played as a "rider" on another card?
      is_rider: bool = false,
  };

  pub const MovementKind = enum {
      advance,
      retreat,
      sidestep,
      close_in,       // Aggressive entry
      create_space,   // Defensive exit
  };

  pub const RestoreEffect = struct {
      stamina: f32,                     // Amount recovered

      // Vulnerability while recovering
      defense_penalty: f32 = 0.5,       // Incoming damage multiplier
  };

  pub const SpecialEffect = struct {
      // Custom effects - spells, skills, etc.
      // Probably needs its own expression/predicate system
      effect_id: SpecialEffectId,

      // Casting time / interruptibility
      interruptible: bool = true,
  };

  Combat State (for combos/openings)

  pub const CombatState = enum {
      // Openings (temporary, from feints/successful defense)
      opening_created,      // Generic "you made an opening"
      off_balance,
      guard_broken,

      // From successful actions
      just_parried,         // Enables riposte window
      just_blocked,         // Enables shield bash
      just_dodged,          // Enables flank

      // Positioning
      inside_range,         // Got past their weapon reach
      at_distance,          // Keeping them at range
      flanking,

      // Stance states (persistent)
      aggressive,
      defensive,

      // Negative states (from being hit/pressured)
      stance_broken,        // Major vulnerability
      winded,               // Stamina recovery impaired
      staggered,            // Next action delayed
  };

  ---
  Resolution Model Sketch

  For simultaneous resolution, you need to know what happens when categories collide:

  pub const Outcome = enum {
      attacker_wins,   // Attacker's effect applies fully
      defender_wins,   // Defender's effect applies, attacker's negated
      mutual,          // Both effects apply
      attacker_bonus,  // Attacker wins + bonus (e.g., feint vs block)
  };

  // Resolution matrix (attacker row, defender column)
  //           strike    block     feint     maneuver  recovery
  // strike    mutual    defender  attacker  mutual    attacker+
  // block     attacker  mutual    defender  mutual    mutual
  // feint     defender  attacker+ mutual    defender  attacker
  // maneuver  mutual    mutual    attacker  mutual    mutual
  // recovery  defender  mutual    defender  mutual    mutual

  pub fn resolveInteraction(attacker: ActionCategory, defender: ActionCategory) Outcome {
      return switch (attacker) {
          .strike => switch (defender) {
              .strike => .mutual,
              .block => .defender_wins,
              .feint => .attacker_wins,
              .maneuver => .mutual,
              .recovery => .attacker_bonus,
              .special => .mutual,  // depends on special
          },
          .block => switch (defender) {
              .strike => .attacker_wins,  // you blocked their strike
              .block => .mutual,          // both blocking, nothing happens
              .feint => .defender_wins,   // they feinted, your block wasted
              .maneuver => .mutual,
              .recovery => .mutual,
              .special => .mutual,
          },
          .feint => switch (defender) {
              .strike => .defender_wins,  // you feinted, they hit you
              .block => .attacker_bonus,  // they wasted block, you set up
              .feint => .mutual,          // both feinting, neutral
              .maneuver => .defender_wins,// maneuver beats feint
              .recovery => .attacker_wins,
              .special => .mutual,
          },
          // ... etc
      };
  }

  ---
  Observations

  1. Category is load-bearing — it determines RPS resolution. The Effect is what happens if you win/succeed.
  2. Stance erosion is separate from damage — a combo that erodes stance makes subsequent hits land harder or breaks guard entirely.
  3. Overcommit maps to multiple techniques — if you play 1.2s of cards in a 1s tick, there's interrupt risk but stance_erosion bonus on each successive hit.
  4. Reactions need special handling — they happen after reveal but before resolution. Probably a separate phase in the loop.
  5. Range complicates things — some techniques only legal at certain ranges. Maneuvers change range. This is another axis.

  ---
  The Headache Zone

  Things that still need design work:

  - Stance as numeric value vs discrete states — is it HP-like (erode to 0 = broken) or state-based?
  - Overcommit interrupt rules — what causes interrupt? Opponent's successful defense? Any hit?
  - Reaction timing — can you react to a reaction? Probably not (too complex).

---

> some answers I have on hand:

  - cards are resolved simultaneously in sequence, counting up in 0.1s increments from the opening of the tick
    - matters because: some reactions / interrupts are playable during execution

  - range is discrete, abstract, per-opponent: - far < medium < near < lance < spear < longsword < cutlass < dagger | grapple

  - reactions on reactions, and during play, feel like a natural extension / progression tbh

  - interrupts - tbd but thoughts
    - chance on any hit, scales with the hit
    - stepping in / getting inside; strong defensive success
    - losing dominant stance
    - outmanouvering

  and some less well arranged thoughts:
  - there's already been a little thought given to conditions, which some of the 'combat state` is veering into
  - I'm mentally separating the elements of combat state into binary (inside range) and continuous (opening created; guard broken)
  - my instinct is to _tend_ towards tracking these as f32 0-1.0 values, to allow them to accumulate over successive moves; perhaps having
  some effect in the in-between values but hitting a 'major impact' threshold at 1.0
  - likewise, my tendency (possibly pathological) is to attach nuances to many of the other pieces of data:
    - creates/exploits/requires: "requires (as base) opponent to be at a 0.3 stance disadvantage vs high attacks, modified by (stats, etc)"
    - punishes ?ActionCategory - ah, why not have it take an f32
    - vs_damage_types - likewise. armour and weapons exist only in relation to each other.
    - enables_counter: bool - this does'nt feel like a boolean, it feels like a palette

  more general thoughts:
  - movement shouldn't (just) be about reach; it should be generally a bad idea to remain standing still. incidentally this is a large part
  of why D&D combat is terrible. Movement is half of stance / priority / initiative, and there should be as much interplay between movements
  as between block/parry/etc. Movement is how you get inside that heavy swing to make your counterattack.
  - the more i think about it, the more i think having movement / footwork cards be able to overlay "arm moves" is genius.
  - movement is also a reason why it's cool to have a damage system that records hits as pierced muscles and ruptured tendons. Once you take
  someone's knee apart, it's hard for them to beat you on "stance".
  - likewise - surgeonlike swordplay requires working fingers.
  - commitment to the attack is another tactical dimension not well represented here yet. If you know you're hitting without opposition,
  it's really going to connect (but if it was a ploy, you might be fucked). Big swings that miss throw you off balance. The "light vs heavy
  attack" trope is a trope for a reason.
  - something I've been wondering (without having prodded at it) is how much work the existing predicate system needs to be able to handle
  the subtleties of wielder's weapons (and sometimes the defender's). you can't murder stroke without an ostentatious crossguard. A swing is
  very different with an axe/mace than a saber, or a spear. And daggers seem weak and useless next to a great big axe, until you shank a
  pinned knight through the armpit with one.
  - shields splinter. Swords chip and blunt. plate is impenetrable no matter how many times a blade glances off it, but hammering on it with
  a footman's mace will change it. But also, fights where "nothing happens" are boring - there's a real challenge in presenting e.g. plate
  armour realistically and that actually being fun.

  overall - I think we're incrementally circling closer to the right modelling, but it's not there yet. In particular I think the notion of
  "stance" is critical but undeveloped. In a lot of Dark Souls-like games, it's central, and it's basically a single number (like stamina)
  which you need to wear down to do lasting damage.

  here, perhaps that's half of it. But it only takes your blade being pinned once, or the one tempo after it's beat aside when you don't
  have control of it, to get 8 inches of steel through the face. Given the severity of the wound system, it's really all about the leadup to
  the one strike that matters - not grinding down HP, not trading hits that land and managing wounds like resources. You get one or two
  sword tips that make it through your gambeson, and it doesn't much matter if you win, you'd better hope the next stop is a shrine of
  regeneration. The challenge is making that tension fun.




----------
REV 1
  Current Problem

  Technique assumes "thing that deals damage and can be defended against":

  pub const Technique = struct {
      damage: damage.Base,        // Defensive techniques: awkward 0 damage
      deflect_mult: f32,          // "How vulnerable am I to deflect" - meaningless for a block
      // ...
  };

  Proposed Structure

  Shared Core + Variant Data

  pub const TechniqueId = enum(u16) {
      // Offensive
      thrust,
      swing,
      pommel_strike,
      // Defensive
      parry,
      block,
      deflect,
      dodge,
      // Counters
      riposte,
      counter_cut,
      // Feints/Setup
      feint_high,
      feint_low,
      // Maneuvers
      advance,
      retreat,
      sidestep,
  };

  pub const Technique = struct {
      id: TechniqueId,
      name: []const u8,

      // Universal costs
      stamina: f32,
      time: f32,

      // What this technique actually does
      action: Action,
  };

  pub const Action = union(enum) {
      attack: Attack,
      defend: Defend,
      counter: Counter,
      feint: Feint,
      maneuver: Maneuver,
  };

  The Primitives

  pub const Attack = struct {
      damage: damage.Base,
      accuracy: f32,                    // Base hit chance modifier

      // How hard is this to defend against?
      vulnerability: DefenseVulnerability,

      // Combo potential
      creates: ?[]const CombatState = null,
      exploits: ?[]const CombatState = null,  // Bonus if target has this state
  };

  pub const DefenseVulnerability = struct {
      block: f32 = 1.0,    // 1.0 = normal, 0.5 = hard to block, 2.0 = easy
      parry: f32 = 1.0,
      deflect: f32 = 1.0,
      dodge: f32 = 1.0,
  };

  pub const Defend = struct {
      kind: DefenseKind,
      effectiveness: f32,              // Damage reduction (1.0 = full, 0.5 = half)

      // What it's good/bad against
      vs_tags: ?cards.TagSet = null,   // Bonus vs these attack types

      // Optional riposte window (for active parries)
      opens_counter: bool = false,
  };

  pub const DefenseKind = enum {
      block,      // Absorb with shield/weapon, stamina cost scales with damage
      parry,      // Redirect with weapon, precise timing
      deflect,    // Glancing blow, partial damage
      dodge,      // Avoid entirely, costs positioning
      absorb,     // Armor/toughness soak
  };

  pub const Counter = struct {
      // The defensive component
      defense: Defend,

      // The offensive component (fires if defense succeeds)
      riposte: Attack,

      // Timing strictness (smaller = harder but more rewarding)
      window: f32,
  };

  pub const Feint = struct {
      // What it looks like (for AI/animation)
      mimics: TechniqueId,

      // What state it creates
      creates: []const CombatState,

      // How long the opening lasts
      duration: f32,
  };

  pub const Maneuver = struct {
      kind: ManeuverKind,
      distance_change: i8,             // -2 to +2 (negative = closer)
      stance_change: ?Stance = null,
      creates: ?[]const CombatState = null,
  };

  pub const ManeuverKind = enum {
      advance,
      retreat,
      sidestep,
      circle,
      close_distance,    // Aggressive move-in
      create_distance,   // Defensive move-out
      stance_shift,
  };

  Combat State (for Combos/Openings)

  pub const CombatState = enum {
      // Openings created by feints/maneuvers
      opening_high,
      opening_low,
      opening_left,
      opening_right,
      off_balance,

      // States from successful actions
      just_parried,       // Enables riposte
      just_blocked,       // Enables shield bash
      just_dodged,        // Enables flank attack

      // Positioning
      in_close,
      at_range,
      flanking,

      // Stances (persistent until changed)
      aggressive_stance,
      defensive_stance,
      neutral_stance,
  };

  pub const CombatStateInstance = struct {
      state: CombatState,
      remaining: f32,      // Time until decay (0 = permanent/stance)
      source: EntityID,    // Who created this state
  };

  ---
  How It Plays Out

  Basic attack:
  .{
      .id = .thrust,
      .name = "thrust",
      .stamina = 2.0,
      .time = 0.3,
      .action = .{ .attack = .{
          .damage = thrust_damage,
          .accuracy = 0.0,
          .vulnerability = .{ .parry = 1.2, .dodge = 0.7 },  // Easy to parry, hard to dodge
          .creates = null,
          .exploits = &.{ .opening_high },  // Bonus damage if they're open high
      }},
  }

  Feint → Exploit:
  // Feint high...
  .{
      .id = .feint_high,
      .name = "feint high",
      .stamina = 1.0,
      .time = 0.2,
      .action = .{ .feint = .{
          .mimics = .swing,
          .creates = &.{ .opening_low },  // They defend high, low is open
          .duration = 0.5,
      }},
  }

  // ...then thrust low exploits it
  .{
      .id = .thrust,
      // ...
      .exploits = &.{ .opening_low },
  }

  Counter:
  .{
      .id = .riposte,
      .name = "riposte",
      .stamina = 3.0,
      .time = 0.4,
      .action = .{ .counter = .{
          .defense = .{
              .kind = .parry,
              .effectiveness = 1.0,
              .opens_counter = true,
          },
          .riposte = .{
              .damage = riposte_damage,
              .accuracy = 0.2,  // Bonus accuracy on counter
              .vulnerability = .{},
          },
          .window = 0.15,  // Tight timing
      }},
  }

  ---
  The Headache Part: Sequencing

  For combo chains / stances, you have a few options:

  Option A: State Decay (Simplest)
  - States have duration, decay each tick
  - No explicit "combo chains," just temporal windows
  - "Feint → Attack" works because opening_low persists for 0.5s

  Option B: Explicit Chains
  pub const Technique = struct {
      // ...
      chains_from: ?[]const TechniqueId = null,  // Only usable after these
      chains_to: ?[]const TechniqueId = null,    // Unlocks these after use
  };

  Option C: Stance Graphs
  pub const Stance = struct {
      available_techniques: []const TechniqueId,
      transitions: []const struct { technique: TechniqueId, to_stance: StanceId },
  };

  My suggestion: Start with Option A. State decay is simple, emergent, and handles 80% of cases. You can layer explicit chains later if needed.

  ---
  Summary

  | Primitive | Purpose          | Key Fields                                |
  |-----------|------------------|-------------------------------------------|
  | Attack    | Deal damage      | damage, accuracy, vulnerability, exploits |
  | Defend    | Reduce damage    | kind, effectiveness, opens_counter        |
  | Counter   | Defend + riposte | defense, riposte, window                  |
  | Feint     | Create opening   | mimics, creates, duration                 |
  | Maneuver  | Reposition       | kind, distance_change, stance_change      |

  The CombatState system handles combo/opening logic through temporal windows rather than hardcoded chains.


