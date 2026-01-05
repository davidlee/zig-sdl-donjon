// End turn button component
//
// Displays the "End Turn" button during player turn phases.
// Access as: combat.button.EndTurn or combat.EndTurn

const view = @import("../view.zig");
const combat = @import("../../../domain/combat.zig");

const Renderable = view.Renderable;
const AssetId = view.AssetId;
const Point = view.Point;
const Rect = view.Rect;

pub const EndTurn = struct {
    rect: Rect,
    active: bool,
    asset_id: AssetId,

    pub fn init(turn_phase: ?combat.TurnPhase) EndTurn {
        const active = if (turn_phase) |phase|
            (phase == .player_card_selection or phase == .commit_phase)
        else
            false;
        return EndTurn{
            .active = active,
            .asset_id = AssetId.end_turn,
            .rect = Rect{
                .x = 50,
                .y = 690,
                .w = 120,
                .h = 40,
            },
        };
    }

    pub fn hitTest(self: *EndTurn, pt: Point) bool {
        if (self.active) {
            if (self.rect.pointIn(pt)) return true;
        }
        return false;
    }

    pub fn renderable(self: *const EndTurn) ?Renderable {
        if (self.active) {
            return Renderable{ .sprite = .{
                .asset = self.asset_id,
                .dst = self.rect,
            } };
        } else return null;
    }
};
