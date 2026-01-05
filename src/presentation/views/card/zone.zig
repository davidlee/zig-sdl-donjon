// Card zone layout - reusable layout parameters for card rendering
//
// Access as: card.Layout

const card_renderer = @import("../../card_renderer.zig");

/// Layout parameters for a card zone
pub const Layout = struct {
    w: f32,
    h: f32,
    y: f32,
    start_x: f32,
    spacing: f32,

    /// Default card dimensions from renderer
    pub fn defaultDimensions() struct { w: f32, h: f32 } {
        return .{
            .w = card_renderer.CARD_WIDTH,
            .h = card_renderer.CARD_HEIGHT,
        };
    }

    /// Create layout with default card dimensions
    pub fn init(y: f32, start_x: f32, spacing: f32) Layout {
        return .{
            .w = card_renderer.CARD_WIDTH,
            .h = card_renderer.CARD_HEIGHT,
            .y = y,
            .start_x = start_x,
            .spacing = spacing,
        };
    }

    /// Apply offset to layout
    pub fn withOffset(self: Layout, offset_x: f32, offset_y: f32) Layout {
        var result = self;
        result.start_x += offset_x;
        result.y += offset_y;
        return result;
    }
};
