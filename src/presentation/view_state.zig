// ViewState - presentation layer state, separate from domain World
//
// Coordinator owns this and keeps it updated. Views receive it as
// immutable input and return updates from handleInput.

const std = @import("std");
const s = @import("sdl3");
const lib = @import("infra");
const entity = lib.entity;

pub const Point = s.rect.FPoint;
pub const Rect = s.rect.FRect;

/// Root view state - system state plus per-view state
pub const ViewState = struct {
    // System - Coordinator keeps updated on relevant events
    screen: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 },
    mouse: Point = .{ .x = 0, .y = 0 },

    // Per-view state (null when not active or fresh)
    combat: ?CombatState = null,
    menu: ?MenuState = null,

    /// Update just the combat state, preserving system state
    pub fn withCombat(self: ViewState, combat_state: ?CombatState) ViewState {
        var new = self;
        new.combat = combat_state;
        return new;
    }

    /// Update just the menu state, preserving system state
    pub fn withMenu(self: ViewState, menu_state: ?MenuState) ViewState {
        var new = self;
        new.menu = menu_state;
        return new;
    }
};

/// Combat view state
pub const CombatState = struct {
    drag: ?DragState = null,
    selected_card: ?entity.ID = null,
    hover_target: ?entity.ID = null,
};

/// Menu view state
pub const MenuState = struct {
    selected_option: usize = 0,
};

/// Drag operation state
pub const DragState = struct {
    id: entity.ID,
    grab_offset: Point, // click position relative to item's origin
    original_pos: Point, // for snap-back on cancel
};
