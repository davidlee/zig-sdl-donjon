// Coordinator - integration point between domain and presentation
//
// Owns ViewModels, EffectMapper, EffectSystem, ViewState.
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
const view_state = @import("view_state.zig");
const title = @import("views/title.zig");
const combat_view = @import("views/combat_view.zig");
const summary = @import("views/summary.zig");
const chrome = @import("views/chrome.zig");
const combat_log = @import("combat_log.zig");

const EffectSystem = effects.EffectSystem;
const EffectMapper = effects.EffectMapper;
const CombatLog = combat_log.CombatLog;
const View = view.View;
const ViewState = view_state.ViewState;
const Point = view_state.Point;
const UX = graphics.UX;
const infra = @import("infra");
const Command = infra.commands.Command;

pub const Coordinator = struct {
    alloc: std.mem.Allocator,
    frame_arena: std.heap.ArenaAllocator,
    world: *World,
    ux: *UX,
    effect_system: EffectSystem,
    combat_log: CombatLog,
    current_time: f32,
    vs: ViewState,

    pub fn init(alloc: std.mem.Allocator, world: *World, ux: *UX) !Coordinator {
        return .{
            .alloc = alloc,
            .frame_arena = std.heap.ArenaAllocator.init(alloc),
            .world = world,
            .ux = ux,
            .effect_system = try EffectSystem.init(alloc),
            .combat_log = try CombatLog.init(alloc),
            .current_time = 0,
            .vs = .{},
        };
    }

    pub fn deinit(self: *Coordinator) void {
        self.frame_arena.deinit();
        self.effect_system.deinit();
        self.combat_log.deinit();
    }

    /// Per-frame allocator - reset at end of each render cycle
    fn frameAlloc(self: *Coordinator) std.mem.Allocator {
        return self.frame_arena.allocator();
    }

    // Get the active view based on game state
    fn activeView(self: *Coordinator) View {
        return switch (self.world.fsm.currentState()) {
            .splash => View{ .title = title.View.init(self.world) },
            .encounter_summary => View{ .summary = summary.View.init(self.world) },
            // TODO: create proper WorldMapView when dungeon crawling is implemented
            .world_map => View{ .title = title.View.init(self.world) },
            // Active combat - turn phase determines sub-state within CombatView
            .in_encounter => View{ .combat = combat_view.CombatView.init(self.world, self.frameAlloc()) },
        };
    }

    fn isChromeActive(self: *Coordinator) bool {
        return self.world.fsm.currentState() != .splash;
    }

    fn chromeView(self: *Coordinator) chrome.ChromeView {
        return chrome.ChromeView.init(self.world, &self.combat_log);
    }

    // Handle SDL input event
    pub fn handleInput(self: *Coordinator, sdl_event: s.events.Event) ?Command {
        // Update mouse position on any mouse event
        const vx: f32 = if (self.isChromeActive()) @floatFromInt(chrome.viewport.x) else 0;
        const vy: f32 = if (self.isChromeActive()) @floatFromInt(chrome.viewport.y) else 0;
        switch (sdl_event) {
            .mouse_button_down, .mouse_button_up => |data| {
                self.vs.mouse = self.ux.translateCoords(.{ .x = data.x - vx, .y = data.y - vy });
            },
            .mouse_wheel => |data| {
                self.vs.mouse = self.ux.translateCoords(.{ .x = data.x - vx, .y = data.y - vy });
            },
            .mouse_motion => |data| {
                self.vs.mouse = self.ux.translateCoords(.{ .x = data.x - vx, .y = data.y - vy });
            },
            else => {},
        }

        // Dispatch to active view
        var v = self.activeView();
        const result = v.handleInput(sdl_event, self.world, self.vs);

        if (result.vs) |new_vs| self.vs = new_vs;

        // chrome can apply viewstate updates as well, but only issues a command
        // if one wasn't already issued by the active view
        //
        if (self.isChromeActive()) {
            var c = self.chromeView();
            const ui_result = c.handleInput(sdl_event, self.world, self.vs);
            if (ui_result.vs) |new_vs| self.vs = new_vs;

            return result.command orelse ui_result.command;
        } else {
            return result.command;
        }
    }

    // Handle SDL non-input event
    pub fn processSystemEvent(self: *Coordinator, sdl_event: s.events.Event) void {
        switch (sdl_event) {
            .window_resized => |data| {
                self.vs.screen.w = @floatFromInt(data.width);
                self.vs.screen.h = @floatFromInt(data.height);
            },
            .window_pixel_size_changed => |data| {
                self.vs.screen.w = @floatFromInt(data.width);
                self.vs.screen.h = @floatFromInt(data.height);
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
            // Format event for combat log
            if (try combat_log.format(event, self.world, self.alloc)) |text| {
                try self.combat_log.append(text);
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
        const frame_alloc = self.frameAlloc();

        try self.ux.renderClear();

        var v = self.activeView();
        // LAYER 1: Game / Active View
        var renderables = try v.renderables(frame_alloc, self.vs);

        if (self.isChromeActive()) {
            const c = self.chromeView();

            // render game view in a viewport
            try self.ux.renderWithViewport(renderables.items, chrome.viewport);

            // LAYER 2: Chrome
            renderables = try c.renderables(frame_alloc, self.vs);
        }

        try self.ux.renderList(renderables.items); // either game view or chrome

        // LAYER 3: Effects / overlays
        // todo

        // Layer 4: debug
        try self.ux.renderDebug();
        try self.ux.renderFinalize();

        // Cleanup textures invalidated during this frame
        self.ux.endFrame();

        // Reset frame arena - frees all transient allocations from this frame
        _ = self.frame_arena.reset(.retain_capacity);
    }
};
