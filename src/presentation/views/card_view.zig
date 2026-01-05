// DEPRECATED: Use card/model.zig directly
// This file provides backward compatibility during migration.

const model = @import("card/model.zig");

// Re-export with old names for compatibility
pub const CardKind = model.Kind;
pub const CardRarity = model.Rarity;
pub const CardState = model.State;
pub const CardViewModel = model.Model;
