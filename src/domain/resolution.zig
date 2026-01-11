/// Legacy resolution entry point re-exporting the split modules.
///
/// Maintains backward compatibility for existing imports while delegating to
/// `resolution/mod.zig`.
const resolution_mod = @import("resolution/mod.zig");

pub const context = resolution_mod.context;
pub const advantage = resolution_mod.advantage;
pub const contested = resolution_mod.contested;
pub const damage = resolution_mod.damage;
pub const height = resolution_mod.height;
pub const outcome = resolution_mod.outcome;

// Re-export commonly used types for backward compatibility
pub const Outcome = resolution_mod.Outcome;
pub const AttackContext = resolution_mod.AttackContext;
pub const DefenseContext = resolution_mod.DefenseContext;
pub const ComputedCombatState = resolution_mod.ComputedCombatState;
pub const CombatModifiers = resolution_mod.CombatModifiers;
pub const AggregatedOverlay = resolution_mod.AggregatedOverlay;
pub const ResolutionResult = resolution_mod.ResolutionResult;
pub const AdvantageEffect = resolution_mod.AdvantageEffect;
pub const TechniqueAdvantage = resolution_mod.TechniqueAdvantage;

// Re-export commonly used functions
pub const resolveTechniqueVsDefense = resolution_mod.resolveTechniqueVsDefense;
pub const resolveOutcome = resolution_mod.resolveOutcome;
pub const getOverlayBonuses = resolution_mod.getOverlayBonuses;
pub const getAdvantageEffect = resolution_mod.getAdvantageEffect;
pub const applyAdvantageWithEvents = resolution_mod.applyAdvantageWithEvents;
pub const createDamagePacket = resolution_mod.createDamagePacket;
pub const getWeaponOffensive = resolution_mod.getWeaponOffensive;
pub const selectHitLocation = resolution_mod.selectHitLocation;
pub const selectHitLocationFromExposures = resolution_mod.selectHitLocationFromExposures;
pub const getHeightMultiplier = resolution_mod.getHeightMultiplier;
pub const findPartIndex = resolution_mod.findPartIndex;
