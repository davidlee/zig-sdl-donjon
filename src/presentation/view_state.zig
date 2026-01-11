// ViewState - presentation layer state, separate from domain World
//
// Coordinator owns this and keeps it updated. Views receive it as
// immutable input and return updates from handleInput.

const std = @import("std");
const s = @import("sdl3");
const lib = @import("infra");
const view = @import("views/view.zig");
const actions = @import("../domain/actions.zig");
const entity = lib.entity;

pub const Point = s.rect.FPoint;
pub const Rect = s.rect.FRect;

/// Root view state - system state plus per-view state
pub const ViewState = struct {
    // System - Coordinator keeps updated on relevant events
    screen: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 },
    viewport: Rect = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, // area available to active view
    mouse_vp: Point = .{ .x = 0, .y = 0 },
    mouse_novp: Point = .{ .x = 0, .y = 0 }, // no viewport (for chrome, etc)

    // Per-view state (null when not active or fresh)
    combat: ?CombatUIState = null,
    menu: ?MenuState = null,
    clicked: ?Point = null,
    click_time: ?u64 = null, // timestamp (ns) when clicked - for click vs drag detection

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

/// Stance triangle cursor state for pre-round stance selection.
pub const StanceCursor = struct {
    /// Screen position of cursor, or null if following mouse.
    position: ?Point = null,
    /// Whether cursor is locked (click to lock/unlock).
    locked: bool = false,
    /// Whether confirm button is hovered.
    confirm_hovered: bool = false,
};

/// Combat view UI state (interaction: hover, drag, selection)
/// Named to distinguish from domain combat.CombatState (card zones).
pub const CombatUIState = struct {
    drag: ?DragState = null,
    selected_card: ?entity.ID = null,
    pending_target_card: ?entity.ID = null, // card awaiting target selection
    targeting_for_commit: bool = false, // true = commit_add, false = play_card
    focused_enemy: ?entity.ID = null, // UI focus for timeline display / default targeting
    hover: EntityRef = .none,
    log_scroll: i32 = 0, // pixel scroll offset for combat log (0 = bottom/most recent)
    stance_cursor: StanceCursor = .{}, // stance triangle selection cursor
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
            // Remove animations when progress reaches 1.0
            if (anim.progress < 1.0) {
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
        return self.interpolatedRect(to);
    }

    /// Interpolate between from_rect and an explicit destination
    pub fn interpolatedRect(self: CardAnimation, to: Rect) Rect {
        const t = cubicEaseInOut(self.progress);
        return .{
            .x = lerp(self.from_rect.x, to.x, t),
            .y = lerp(self.from_rect.y, to.y, t),
            .w = lerp(self.from_rect.w, to.w, t),
            .h = lerp(self.from_rect.h, to.h, t),
        };
    }

    pub fn isComplete(self: CardAnimation) bool {
        return self.progress >= 1.0;
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
    original_pos: Point,
    start_time: u64, // timestamp (ns) when drag started
    source: DragSource,

    // Drop target indicators (updated during drag)
    target_time: ?f32 = null, // timeline position under cursor (0.0-1.0)
    target_channel: ?actions.ChannelSet = null, // lane under cursor
    is_valid_drop: bool = false, // can drop at current position?

    // Existing (for modifier stacking in commit phase)
    target: ?entity.ID = null, // highlight valid drop target (card ID)
    target_play_index: ?usize = null, // highlight valid drop target (play index)

    pub const DragSource = enum {
        hand, // dragging from hand/carousel
        timeline, // dragging from timeline (reorder/lane switch)
    };
};
