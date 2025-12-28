// CombatView - combat encounter screen
//
// Displays player hand, enemies, engagements, combat phase.
// Handles card selection, targeting, reactions.

const std = @import("std");
const view = @import("view.zig");
const commands = @import("../../commands.zig");
const World = @import("../../domain/world.zig").World;
const cards = @import("../../domain/cards.zig");
const combat = @import("../../domain/combat.zig");

const Renderable = view.Renderable;
const InputEvent = view.InputEvent;
const Point = view.Point;
const Command = commands.Command;
const ID = commands.ID;

pub const CombatView = struct {
    world: *const World,

    pub fn init(world: *const World) CombatView {
        return .{ .world = world };
    }

    // Query methods - expose what the view needs from World

    pub fn playerHand(self: *const CombatView) []const *cards.Instance {
        return self.world.player.cards.deck.hand.items;
    }

    pub fn enemies(self: *const CombatView) []const *combat.Agent {
        if (self.world.encounter) |*enc| {
            return enc.enemies.items;
        }
        return &.{};
    }

    pub fn combatPhase(self: *const CombatView) World.GameState {
        return self.world.fsm.currentState();
    }

    // Input handling

    pub fn handleInput(self: *CombatView, event: InputEvent) ?Command {
        switch (event) {
            .click => |pos| return self.handleClick(pos),
            .key => |keycode| return self.handleKey(keycode),
        }
    }

    fn handleClick(self: *CombatView, pos: Point) ?Command {
        // Hit test cards in hand
        if (self.hitTestHand(pos)) |card_id| {
            return Command{ .play_card = .{ .card_id = card_id } };
        }

        // Hit test enemies (for targeting)
        if (self.hitTestEnemies(pos)) |target_id| {
            return Command{ .select_target = .{ .target_id = target_id } };
        }

        return null;
    }

    fn handleKey(self: *CombatView, keycode: u32) ?Command {
        _ = self;
        // Space/Enter to end turn, Escape to cancel, etc.
        switch (keycode) {
            ' ' => return Command{ .end_turn = {} },
            else => return null,
        }
    }

    // Hit testing - recomputes layout on demand

    fn hitTestHand(self: *CombatView, pos: Point) ?ID {
        const hand = self.playerHand();
        const card_width: f32 = 100;
        const card_height: f32 = 140;
        const hand_y: f32 = 500; // bottom of screen
        const start_x: f32 = 100;
        const spacing: f32 = 110;

        for (hand, 0..) |card, i| {
            const card_x = start_x + @as(f32, @floatFromInt(i)) * spacing;
            if (pos.x >= card_x and pos.x < card_x + card_width and
                pos.y >= hand_y and pos.y < hand_y + card_height)
            {
                return toCommandID(card.id);
            }
        }
        return null;
    }

    fn hitTestEnemies(self: *CombatView, pos: Point) ?ID {
        const enemy_list = self.enemies();
        const enemy_width: f32 = 80;
        const enemy_height: f32 = 120;
        const enemy_y: f32 = 100;
        const start_x: f32 = 300;
        const spacing: f32 = 120;

        for (enemy_list, 0..) |enemy, i| {
            const enemy_x = start_x + @as(f32, @floatFromInt(i)) * spacing;
            if (pos.x >= enemy_x and pos.x < enemy_x + enemy_width and
                pos.y >= enemy_y and pos.y < enemy_y + enemy_height)
            {
                return toCommandID(enemy.id);
            }
        }
        return null;
    }

    // Convert domain entity.ID to commands.ID
    fn toCommandID(eid: @import("../../domain/entity.zig").ID) ID {
        return .{ .index = eid.index, .generation = eid.generation };
    }

    // Rendering

    pub fn renderables(self: *const CombatView, alloc: std.mem.Allocator) !std.ArrayList(Renderable) {
        var list = std.ArrayList(Renderable).init(alloc);

        // TODO: render
        // - player hand (cards at bottom)
        // - enemies (top area)
        // - engagement info / advantage bars
        // - stamina/time indicators
        // - phase indicator

        _ = self;

        return list;
    }
};
