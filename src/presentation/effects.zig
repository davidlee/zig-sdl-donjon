// Effects - transient presentation state (animations, particles, floating text)
//
// EffectMapper: transforms domain Events -> presentation Effects
// EffectSystem: owns in-flight Tweens, ticks them, produces Renderables

const std = @import("std");
const events = @import("../domain/events.zig");
const infra = @import("infra");
const entity = infra.entity;
const Event = events.Event;
const ID = infra.commands.ID;
const World = @import("../domain/world.zig").World;
const view_state = @import("view_state.zig");
const ViewState = view_state.ViewState;
const CombatUIState = view_state.CombatUIState;
const Rect = view_state.Rect;

// Presentation effects - what the UI should show
pub const Effect = union(enum) {
    // Card animations
    card_dealt: struct { card_id: ID },
    card_played: struct { card_id: ID },
    card_discarded: struct { card_id: ID },

    // Combat feedback
    damage_number: struct { target_id: ID, amount: f32 },
    hit_flash: struct { target_id: ID },
    status_applied: struct { target_id: ID, status: []const u8 },

    // Advantage changes
    advantage_changed: struct { agent_id: ID, axis: u8, delta: f32 },

    // Screen effects
    screen_shake: struct { intensity: f32 },
};

// Animation interpolation
pub const Tween = struct {
    effect: Effect,
    start_time: f32,
    duration: f32,
    elapsed: f32 = 0,

    pub fn progress(self: *const Tween) f32 {
        return std.math.clamp(self.elapsed / self.duration, 0.0, 1.0);
    }

    pub fn isComplete(self: *const Tween) bool {
        return self.elapsed >= self.duration;
    }

    pub fn tick(self: *Tween, dt: f32) void {
        self.elapsed += dt;
    }
};

// Maps domain events to presentation effects
pub const EffectMapper = struct {
    pub fn map(event: Event) ?Effect {
        return switch (event) {
            .card_moved => |data| switch (data.to) {
                .hand => Effect{ .card_dealt = .{ .card_id = toID(data.instance) } },
                // Note: in_play handled by played_action_card (covers both hand and pool cards)
                .discard => Effect{ .card_discarded = .{ .card_id = toID(data.instance) } },
                else => null,
            },
            // played_action_card fires for all played cards, including always_available clones
            // (card_moved only fires for hand->in_play, not for pool card clones)
            .played_action_card => |data| Effect{ .card_played = .{ .card_id = toID(data.instance) } },
            .wound_inflicted => |data| Effect{ .hit_flash = .{ .target_id = toID(data.agent_id) } },
            .advantage_changed => |data| Effect{
                .advantage_changed = .{
                    .agent_id = toID(data.agent_id),
                    .axis = @intFromEnum(data.axis),
                    .delta = data.new_value - data.old_value,
                },
            },
            // Most events don't need visual feedback
            else => null,
        };
    }

    fn toID(eid: entity.ID) ID {
        return .{ .index = eid.index, .generation = eid.generation };
    }
};

// Owns and ticks in-flight animations
pub const EffectSystem = struct {
    alloc: std.mem.Allocator,
    pending: std.ArrayList(Effect),
    animations: std.ArrayList(Tween),

    pub fn init(alloc: std.mem.Allocator) !EffectSystem {
        return .{
            .alloc = alloc,
            .pending = try std.ArrayList(Effect).initCapacity(alloc, 16),
            .animations = try std.ArrayList(Tween).initCapacity(alloc, 16),
        };
    }

    pub fn deinit(self: *EffectSystem) void {
        self.pending.deinit(self.alloc);
        self.animations.deinit(self.alloc);
    }

    pub fn push(self: *EffectSystem, effect: Effect) !void {
        try self.pending.append(self.alloc, effect);
    }

    // Process pending effects into animations
    pub fn spawnAnimations(self: *EffectSystem, current_time: f32) !void {
        for (self.pending.items) |effect| {
            const duration: f32 = switch (effect) {
                .card_dealt, .card_played, .card_discarded => 0.3,
                .damage_number => 1.0,
                .hit_flash => 0.15,
                .status_applied => 0.5,
                .advantage_changed => 0.4,
                .screen_shake => 0.2,
            };
            try self.animations.append(self.alloc, .{
                .effect = effect,
                .start_time = current_time,
                .duration = duration,
            });
        }
        self.pending.clearRetainingCapacity();
    }

    // Tick all animations, remove completed ones
    pub fn tick(self: *EffectSystem, dt: f32) void {
        var i: usize = 0;
        while (i < self.animations.items.len) {
            self.animations.items[i].tick(dt);
            if (self.animations.items[i].isComplete()) {
                _ = self.animations.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn activeAnimations(self: *const EffectSystem) []const Tween {
        return self.animations.items;
    }

    // --- Card Animation Handling (updates ViewState) ---

    const card_animation_duration: f32 = 0.5; // seconds

    /// Process a domain event, updating card animations in ViewState
    pub fn processEvent(self: *EffectSystem, event: Event, vs: *ViewState, world: *const World) void {
        _ = self;
        _ = world;
        switch (event) {
            .card_cloned => |data| handleCardCloned(vs, data.master_id, data.clone_id),
            else => {},
        }
    }

    /// Tick card animations in ViewState
    pub fn tickCardAnimations(self: *EffectSystem, dt: f32, vs: *ViewState) void {
        _ = self;
        var cs = vs.combat orelse return;
        const progress_delta = dt / card_animation_duration;

        for (cs.card_animations[0..cs.card_animation_len]) |*anim| {
            anim.progress = @min(1.0, anim.progress + progress_delta);
        }

        cs.removeCompletedAnimations();
        vs.combat = cs;
    }
};

/// When a card is cloned (pool cards), update the animation's card_id to the clone
fn handleCardCloned(vs: *ViewState, master_id: entity.ID, clone_id: entity.ID) void {
    var cs = vs.combat orelse return;

    if (cs.findAnimation(master_id)) |anim| {
        anim.card_id = clone_id;
        vs.combat = cs;
    }
}
