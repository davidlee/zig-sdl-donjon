Let's map it out. The key insight is that different technique categories have natural advantage dynamics, and specific techniques tweak from there.

  ---
  Advantage Effects Structure

  pub const AdvantageEffect = struct {
      // Relational (positive = toward player advantage)
      pressure: f32 = 0,
      control: f32 = 0,
      position: f32 = 0,

      // Intrinsic
      self_balance: f32 = 0,
      target_balance: f32 = 0,

      // Range
      range_delta: i8 = 0,  // -1 = closer, +1 = farther

      pub fn scale(self: AdvantageEffect, mult: f32) AdvantageEffect {
          return .{
              .pressure = self.pressure * mult,
              .control = self.control * mult,
              .position = self.position * mult,
              .self_balance = self.self_balance * mult,
              .target_balance = self.target_balance * mult,
              .range_delta = self.range_delta,
          };
      }

      pub fn add(self: AdvantageEffect, other: AdvantageEffect) AdvantageEffect {
          return .{
              .pressure = self.pressure + other.pressure,
              .control = self.control + other.control,
              .position = self.position + other.position,
              .self_balance = self.self_balance + other.self_balance,
              .target_balance = self.target_balance + other.target_balance,
              .range_delta = self.range_delta + other.range_delta,
          };
      }
  };

  ---
  Outcome-Based Effects

  Techniques produce different effects based on what happened:

  pub const TechniqueAdvantage = struct {
      // Applied regardless of outcome
      always: AdvantageEffect = .{},

      // Outcome-specific (null = use category default)
      on_hit: ?AdvantageEffect = null,
      on_miss: ?AdvantageEffect = null,
      on_blocked: ?AdvantageEffect = null,
      on_parried: ?AdvantageEffect = null,
      on_dodged: ?AdvantageEffect = null,

      // For defensive techniques
      on_success: ?AdvantageEffect = null,  // Successfully defended
      on_failure: ?AdvantageEffect = null,  // Defense failed / baited
  };

  ---
  Category Defaults

  Each category has baseline advantage dynamics:

  pub const CategoryDefaults = struct {

      pub const strike = TechniqueAdvantage{
          .on_hit = .{
              .pressure = 0.15,
              .control = 0.10,
              .target_balance = -0.15,
          },
          .on_miss = .{
              .control = -0.15,
              .self_balance = -0.10,
          },
          .on_blocked = .{
              .pressure = 0.05,
              .control = -0.05,
          },
          .on_parried = .{
              .control = -0.20,
              .self_balance = -0.05,
          },
          .on_dodged = .{
              .pressure = 0.05,
              .control = -0.10,
              .self_balance = -0.05,
          },
      };

      pub const block = TechniqueAdvantage{
          .on_success = .{
              .control = 0.10,
          },
          .on_failure = .{  // Baited by feint
              .control = -0.15,
              .pressure = -0.10,
          },
      };

      pub const parry = TechniqueAdvantage{
          .on_success = .{
              .control = 0.20,
              .pressure = 0.05,
          },
          .on_failure = .{
              .control = -0.20,
              .self_balance = -0.10,
          },
      };

      pub const feint = TechniqueAdvantage{
          .always = .{
              .pressure = 0.10,
          },
          .on_success = .{  // They reacted to nothing
              .control = 0.15,
              .pressure = 0.10,  // Stacks with always
          },
          // on_failure = opponent didn't bite, just pressure gain
      };

      pub const maneuver = TechniqueAdvantage{
          // Varies heavily by specific move, no useful default
      };

      pub const recovery = TechniqueAdvantage{
          .always = .{
              .pressure = -0.15,      // Ceding initiative
              .self_balance = 0.10,   // But stabilizing
          },
      };
  };

  ---
  Specific Techniques

  Techniques can override or extend category defaults:

  pub const Techniques = struct {

      pub const thrust = Technique{
          .id = .thrust,
          .name = "thrust",
          .category = .strike,
          .time = 0.3,
          .stamina = 2.0,
          .effect = .{ .damage = thrust_damage },

          // Uses strike defaults, but thrust is harder to parry
          .advantage = CategoryDefaults.strike.with(.{
              .on_parried = .{
                  .control = -0.10,  // Less penalty than default
                  .self_balance = 0,
              },
          }),
      };

      pub const heavy_swing = Technique{
          .id = .heavy_swing,
          .name = "heavy swing",
          .category = .strike,
          .time = 0.5,
          .stamina = 4.0,
          .effect = .{ .damage = heavy_damage },

          // Exaggerated risk/reward
          .advantage = .{
              .on_hit = .{
                  .pressure = 0.25,
                  .control = 0.15,
                  .target_balance = -0.30,
              },
              .on_miss = .{
                  .control = -0.25,
                  .self_balance = -0.25,
                  .position = -0.10,
              },
              .on_blocked = .{
                  .pressure = 0.10,
                  .target_balance = -0.10,  // Heavy hit staggers even through block
              },
              .on_parried = .{
                  .control = -0.30,
                  .self_balance = -0.20,
              },
          },
      };

      pub const sidestep = Technique{
          .id = .sidestep,
          .name = "sidestep",
          .category = .maneuver,
          .time = 0.2,
          .stamina = 1.0,
          .overlay = .footwork,  // Can combine with arm techniques

          .advantage = .{
              .always = .{
                  .position = 0.15,
                  .self_balance = -0.05,  // Minor cost to reposition
              },
          },
      };

      pub const advance = Technique{
          .id = .advance,
          .name = "advance",
          .category = .maneuver,
          .time = 0.2,
          .stamina = 1.5,
          .overlay = .footwork,

          .advantage = .{
              .always = .{
                  .pressure = 0.10,
                  .range_delta = -1,
                  .self_balance = -0.05,
              },
          },
      };

      pub const retreat = Technique{
          .id = .retreat,
          .name = "retreat",
          .category = .maneuver,
          .time = 0.2,
          .stamina = 1.0,
          .overlay = .footwork,

          .advantage = .{
              .always = .{
                  .pressure = -0.10,
                  .range_delta = 1,
                  .self_balance = 0.05,  // Safer
              },
          },
      };

      pub const riposte = Technique{
          .id = .riposte,
          .name = "riposte",
          .category = .counter,
          .time = 0.3,
          .stamina = 3.0,
          .requires = &.{ .just_parried },  // Only after successful parry

          .advantage = .{
              .on_hit = .{
                  .pressure = 0.25,
                  .control = 0.20,
                  .target_balance = -0.25,
              },
              .on_miss = .{
                  // Riposte miss is less punishing - you're already in good position
                  .control = -0.05,
              },
          },
      };
  };

  ---
  Commitment Scaling

  Commitment modifies advantage effects (and damage):

  pub const Commitment = enum {
      probing,
      standard,
      committed,
      all_in,

      pub fn advantageScale(self: Commitment) f32 {
          return switch (self) {
              .probing => 0.5,
              .standard => 1.0,
              .committed => 1.25,
              .all_in => 1.5,
          };
      }

      pub fn riskScale(self: Commitment) f32 {
          return switch (self) {
              .probing => 0.25,
              .standard => 1.0,
              .committed => 1.75,
              .all_in => 2.5,
          };
      }

      pub fn damageScale(self: Commitment) f32 {
          return switch (self) {
              .probing => 0.4,
              .standard => 1.0,
              .committed => 1.4,
              .all_in => 2.0,
          };
      }
  };

  Applied at resolution:

  fn resolveStrike(
      technique: *const Technique,
      commitment: Commitment,
      outcome: Outcome,
      engagement: *Engagement,
      player: *Player,
      mob: *Mob,
  ) void {
      const base_effect = switch (outcome) {
          .hit => technique.advantage.on_hit orelse CategoryDefaults.strike.on_hit.?,
          .miss => technique.advantage.on_miss orelse CategoryDefaults.strike.on_miss.?,
          .blocked => technique.advantage.on_blocked orelse CategoryDefaults.strike.on_blocked.?,
          // etc
      };

      // Scale based on commitment
      const scale = if (outcome == .hit or outcome == .blocked)
          commitment.advantageScale()
      else
          commitment.riskScale();

      const effect = base_effect.scale(scale);

      // Apply always effects
      if (technique.advantage.always) |always| {
          applyEffect(always, engagement, player, mob);
      }

      // Apply outcome effect
      applyEffect(effect, engagement, player, mob);
  }

  fn applyEffect(effect: AdvantageEffect, engagement: *Engagement, player: *Player, mob: *Mob) void {
      engagement.pressure = std.math.clamp(engagement.pressure + effect.pressure, 0, 1);
      engagement.control = std.math.clamp(engagement.control + effect.control, 0, 1);
      engagement.position = std.math.clamp(engagement.position + effect.position, 0, 1);

      player.state.balance = std.math.clamp(player.state.balance + effect.self_balance, 0, 1);
      mob.state.balance = std.math.clamp(mob.state.balance + effect.target_balance, 0, 1);

      if (effect.range_delta != 0) {
          engagement.range = engagement.range.shift(effect.range_delta);
      }
  }

  ---
  Footwork Overlay Example

  Playing Thrust + Sidestep together:

  fn resolveOverlaidTechniques(
      arm: *const Technique,      // thrust
      footwork: *const Technique, // sidestep
      commitment: Commitment,
      outcome: Outcome,
      engagement: *Engagement,
      player: *Player,
      mob: *Mob,
  ) void {
      // Footwork always applies
      applyEffect(footwork.advantage.always, engagement, player, mob);

      // Arm technique resolves based on outcome
      resolveStrike(arm, commitment, outcome, engagement, player, mob);

      // Time cost = max of both (they're simultaneous)
      // Stamina cost = sum of both
  }

  Result of Thrust (hit) + Sidestep:
  - pressure: +0.15 (thrust hit)
  - control: +0.10 (thrust hit)
  - position: +0.15 (sidestep)
  - target_balance: -0.15 (thrust hit)
  - self_balance: -0.05 (sidestep cost)

  You've hit them and gained angle. Nice.

  ---
  Thresholds

  When advantage crosses thresholds, qualitative effects trigger:

  pub fn checkThresholds(engagement: *Engagement, player: *Player, mob: *Mob) void {
      // Player has dominant pressure
      if (engagement.pressure > 0.8) {
          mob.addState(.pressured);  // Mob options limited
      }

      // Player lost control of the line
      if (engagement.control < 0.2) {
          player.addState(.blade_bound);  // Can't attack this tempo
      }

      // Mob's balance broken
      if (mob.state.balance < 0.2) {
          mob.addState(.staggered);  // Eating next hit clean
      }

      // Player has positional dominance
      if (engagement.position > 0.8 and engagement.range == .near) {
          player.addState(.flanking);  // Bonus accuracy to gaps
      }
  }

  ---