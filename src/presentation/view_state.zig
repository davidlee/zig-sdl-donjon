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
    combat: ?CombatUIState = null,
    menu: ?MenuState = null,

    /// Update just the combat UI state, preserving system state
    pub fn withCombat(self: ViewState, combat_state: ?CombatUIState) ViewState {
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

    /// Update combat log scroll offset
    pub fn withLogScroll(self: ViewState, scroll: usize) ViewState {
        var new = self;
        if (new.combat) |*c| c.log_scroll = scroll;
        return new;
    }
};

const EntityRef = union(enum) {
    none,
    card: entity.ID,
    enemy: entity.ID,
};

/// Combat view UI state (interaction: hover, drag, selection)
/// Named to distinguish from domain combat.CombatState (card zones).
pub const CombatUIState = struct {
    drag: ?DragState = null,
    selected_card: ?entity.ID = null,
    hover: EntityRef = .none,
    log_scroll: usize = 0, // scroll offset for combat log (0 = most recent)
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
