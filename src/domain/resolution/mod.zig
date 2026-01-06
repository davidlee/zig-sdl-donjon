// Resolution module - see doc/decomposition.md for refactor notes
//
// This module handles combat resolution:
// - context: Attack/Defense contexts, combat modifiers, overlay bonuses
// - advantage: Advantage effects and application
// - damage: Damage packet creation
// - height: Hit location selection
// - outcome: Outcome determination and full resolution orchestration

pub const context = @import("context.zig");
pub const advantage = @import("advantage.zig");
pub const damage = @import("damage.zig");
pub const height = @import("height.zig");
pub const outcome = @import("outcome.zig");

// Re-export commonly used types at top level
pub const Outcome = outcome.Outcome;
pub const AttackContext = context.AttackContext;
pub const DefenseContext = context.DefenseContext;
pub const CombatModifiers = context.CombatModifiers;
pub const AggregatedOverlay = context.AggregatedOverlay;
pub const ResolutionResult = outcome.ResolutionResult;
pub const AdvantageEffect = advantage.AdvantageEffect;
pub const TechniqueAdvantage = advantage.TechniqueAdvantage;

// Re-export commonly used functions
pub const resolveTechniqueVsDefense = outcome.resolveTechniqueVsDefense;
pub const resolveOutcome = outcome.resolveOutcome;
pub const calculateHitChance = outcome.calculateHitChance;
pub const getOverlayBonuses = context.getOverlayBonuses;
pub const getAdvantageEffect = advantage.getAdvantageEffect;
pub const applyAdvantageWithEvents = advantage.applyAdvantageWithEvents;
pub const createDamagePacket = damage.createDamagePacket;
pub const getWeaponOffensive = damage.getWeaponOffensive;
pub const selectHitLocation = height.selectHitLocation;
pub const selectHitLocationFromExposures = height.selectHitLocationFromExposures;
pub const getHeightMultiplier = height.getHeightMultiplier;
pub const findPartIndex = height.findPartIndex;
