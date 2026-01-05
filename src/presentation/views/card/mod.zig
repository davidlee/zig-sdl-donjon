// Card presentation components
//
// Reusable card rendering primitives for any view that displays cards.
// Access as: card.Model, card.Data, card.Layout, etc.

pub const model = @import("model.zig");
pub const data = @import("data.zig");
pub const zone = @import("zone.zig");

// Convenience re-exports
pub const Model = model.Model;
pub const Kind = model.Kind;
pub const Rarity = model.Rarity;
pub const State = model.State;
pub const Data = data.Data;
pub const Layout = zone.Layout;
