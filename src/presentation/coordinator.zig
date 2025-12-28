// Coordinator - integration point between domain and presentation
//
// Owns ViewModels, EffectMapper, EffectSystem.
// Routes input to active view, commands to World.
// Drives the presentation loop.

const std = @import("std");
const s = @import("sdl3");

const World = @import("../domain/world.zig").World;
const events = @import("../domain/events.zig");
const GameState = World.GameState;

const effects = @import("effects.zig");
const graphics = @import("graphics.zig");
const view = @import("views/view.zig");
const splash = @import("views/splash.zig");
const combat = @import("views/combat.zig");
const summary = @import("views/summary.zig");

const EffectSystem = effects.EffectSystem;
const EffectMapper = effects.EffectMapper;
const View = view.View;
const InputEvent = view.InputEvent;
const Point = view.Point;
const UX = graphics.UX;
const infra = @import("infra");
const Command = infra.commands.Command;

pub const Coordinator = struct {
    alloc: std.mem.Allocator,
    world: *World,
    ux: *UX,
    effect_system: EffectSystem,
    current_time: f32,

    pub fn init(alloc: std.mem.Allocator, world: *World, ux: *UX) !Coordinator {
        return .{
            .alloc = alloc,
            .world = world,
            .ux = ux,
            .effect_system = try EffectSystem.init(alloc),
            .current_time = 0,
        };
    }

    pub fn deinit(self: *Coordinator) void {
        self.effect_system.deinit();
    }

    // Get the active view based on game state
    pub fn activeView(self: *Coordinator) View {
        return switch (self.world.fsm.currentState()) {
            .splash => View{ .title = splash.TitleScreenView.init(self.world) },
            .encounter_summary => View{ .summary = summary.SummaryView.init(self.world) },
            // All combat-related states use CombatView
            .draw_hand,
            .player_card_selection,
            .tick_resolution,
            .player_reaction,
            .animating,
            => View{ .combat = combat.CombatView.init(self.world) },
        };
    }

    // Handle SDL input event
    pub fn handleInput(self: *Coordinator, sdl_event: s.events.Event) ?Command {
        const input_event: InputEvent = switch (sdl_event) {
            .mouse_button_down => |data| blk: {
                const coords = self.ux.translateCoords(.{ .x = data.x, .y = data.y });
                break :blk InputEvent{ .click = .{ .x = coords.x, .y = coords.y } };
            },
            .key_down => |data| InputEvent{ .key = data.key.? },
            else => return null,
        };

        std.debug.print("input event: {any}", .{input_event});

        var v = self.activeView();
        return v.handleInput(input_event);
    }

    // Handle SDL non-input event
    pub fn processSystemEvent(self: *Coordinator, sdl_event: s.events.Event) void {
        switch (sdl_event) {
            .window_resized => {
                self.ux.ui.screen.w = sdl_event.window_resized.width;
                self.ux.ui.screen.h = sdl_event.window_resized.height;
            },
            .window_pixel_size_changed => {
                self.ux.ui.screen.w = sdl_event.window_pixel_size_changed.width;
                self.ux.ui.screen.h = sdl_event.window_pixel_size_changed.height;
            },
            else => {},
        }
    }

    // Process domain events into presentation effects
    pub fn processWorldEvents(self: *Coordinator) !void {
        for (self.world.events.current_events.items) |event| {
            if (EffectMapper.map(event)) |effect| {
                try self.effect_system.push(effect);
            }
        }
        try self.effect_system.spawnAnimations(self.current_time);
    }

    // Tick animations
    pub fn update(self: *Coordinator, dt: f32) !void {
        self.current_time += dt;
        self.effect_system.tick(dt);
    }

    // Render current state
    pub fn render(self: *Coordinator) !void {
        var v = self.activeView();
        var renderables = try v.renderables(self.alloc);
        defer renderables.deinit(self.alloc);

        // TODO: also gather effect renderables and append

        try self.ux.renderView(renderables.items);
    }
};
