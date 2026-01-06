/// Resolution module - orchestrates attack/defense outcomes.
///
/// Aggregates submodules for combat contexts, advantage, damage packets,
/// height targeting, and final outcome resolution. See doc/decomposition.md
/// for a high-level diagram.

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
