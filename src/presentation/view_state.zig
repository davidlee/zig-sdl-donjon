// ViewState - presentation layer state, separate from domain World
//
// Coordinator owns this and keeps it updated. Views receive it as
// immutable input and return updates from handleInput.

const std = @import("std");
const s = @import("sdl3");
const lib = @import("infra");
const view = @import("views/view.zig");
const entity = lib.entity;

pub const Point = s.rect.FPoint;
pub const Rect = s.rect.FRect;

/// Root view state - system state plus per-view state
pub const ViewState = struct {
    // System - Coordinator keeps updated on relevant events
    screen: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 },
    mouse_vp: Point = .{ .x = 0, .y = 0 },
    mouse_novp: Point = .{ .x = 0, .y = 0 }, // no viewport (for chrome, etc)

    // Per-view state (null when not active or fresh)
    combat: ?CombatUIState = null,
    menu: ?MenuState = null,
    clicked: ?Point = null,

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

    /// Update combat log scroll offset (pixels)
    pub fn withLogScroll(self: ViewState, scroll: i32) ViewState {
        var new = self;
        if (new.combat) |*c| c.log_scroll = scroll;
        return new;
    }
};

pub const EntityRef = union(enum) {
    none,
    card: entity.ID,
    enemy: entity.ID,
};

/// Combat view UI state (interaction: hover, drag, selection)
/// Named to distinguish from domain combat.CombatState (card zones).
pub const CombatUIState = struct {
    drag: ?DragState = null,
    selected_card: ?entity.ID = null,
    pending_target_card: ?entity.ID = null, // card awaiting target selection
    targeting_for_commit: bool = false, // true = commit_add, false = play_card
    hover: EntityRef = .none,
    log_scroll: i32 = 0, // pixel scroll offset for combat log (0 = bottom/most recent)
    card_animations: [max_card_animations]CardAnimation = undefined,
    card_animation_len: u8 = 0,

    const max_card_animations = 4;

    pub fn addAnimation(self: *CombatUIState, anim: CardAnimation) void {
        if (self.card_animation_len < max_card_animations) {
            self.card_animations[self.card_animation_len] = anim;
            self.card_animation_len += 1;
        }
    }

    pub fn activeAnimations(self: *const CombatUIState) []const CardAnimation {
        return self.card_animations[0..self.card_animation_len];
    }

    pub fn findAnimation(self: *CombatUIState, card_id: entity.ID) ?*CardAnimation {
        for (self.card_animations[0..self.card_animation_len]) |*anim| {
            if (anim.card_id.eql(card_id)) return anim;
        }
        return null;
    }

    pub fn isAnimating(self: *const CombatUIState, card_id: entity.ID) bool {
        for (self.activeAnimations()) |anim| {
            if (anim.card_id.eql(card_id)) return true;
        }
        return false;
    }

    pub fn removeCompletedAnimations(self: *CombatUIState) void {
        var write_idx: u8 = 0;
        for (self.card_animations[0..self.card_animation_len]) |anim| {
            // Remove completed animations AND stale ones (never got destination)
            const is_stale = anim.to_rect == null and anim.progress > 0.5;
            if (!anim.isComplete() and !is_stale) {
                self.card_animations[write_idx] = anim;
                write_idx += 1;
            }
        }
        self.card_animation_len = write_idx;
    }

    pub fn isTargeting(self: *const CombatUIState) bool {
        return self.pending_target_card != null;
    }
};

/// Card position tween animation
pub const CardAnimation = struct {
    card_id: entity.ID,
    from_rect: Rect,
    to_rect: ?Rect, // null until effect processing sets destination
    progress: f32, // 0.0 to 1.0

    pub fn currentRect(self: CardAnimation) Rect {
        const to = self.to_rect orelse return self.from_rect;
        const t = cubicEaseInOut(self.progress);
        return .{
            .x = lerp(self.from_rect.x, to.x, t),
            .y = lerp(self.from_rect.y, to.y, t),
            .w = lerp(self.from_rect.w, to.w, t),
            .h = lerp(self.from_rect.h, to.h, t),
        };
    }

    pub fn isComplete(self: CardAnimation) bool {
        return self.to_rect != null and self.progress >= 1.0;
    }

    fn lerp(a: f32, b: f32, t: f32) f32 {
        return a + (b - a) * t;
    }

    fn cubicEaseInOut(t: f32) f32 {
        if (t < 0.5) {
            return 4 * t * t * t;
        } else {
            const f = 2 * t - 2;
            return 0.5 * f * f * f + 1;
        }
    }
};

/// Menu view state
pub const MenuState = struct {
    selected_option: usize = 0,
};

/// Drag operation state
pub const DragState = struct {
    id: entity.ID,
    // grab_offset: Point, // click position relative to item's origin
    original_pos: Point,
    target: ?entity.ID = null, // highlight valid drop target (card ID)
    target_play_index: ?usize = null, // highlight valid drop target (play index for modifiers)
};
