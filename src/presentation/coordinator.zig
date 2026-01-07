// Coordinator - integration point between domain and presentation
//
// Owns ViewModels, EffectMapper, EffectSystem, ViewState.
// Routes input to active view, commands to World.
// Drives the presentation loop.

const std = @import("std");
const s = @import("sdl3");

const World = @import("../domain/world.zig").World;
const GameState = World.GameState;

const effects = @import("effects.zig");
const graphics = @import("graphics.zig");
const view = @import("views/view.zig");
const view_state = @import("view_state.zig");
const title = @import("views/title.zig");
const combat = @import("views/combat/mod.zig");
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
const query = @import("../domain/query/mod.zig");

pub const Coordinator = struct {
    alloc: std.mem.Allocator,
    frame_arena: std.heap.ArenaAllocator,
    world: *World,
    ux: *UX,
    effect_system: EffectSystem,
    combat_log: CombatLog,
    current_time: f32,
    vs: ViewState,

    /// Cached combat snapshot - invalidated on any domain event
    cached_snapshot: ?query.CombatSnapshot = null,

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
        self.invalidateSnapshot();
        self.frame_arena.deinit();
        self.effect_system.deinit();
        self.combat_log.deinit();
    }

    /// Per-frame allocator - reset at end of each render cycle
    fn frameAlloc(self: *Coordinator) std.mem.Allocator {
        return self.frame_arena.allocator();
    }

    /// Get or rebuild the combat snapshot. Returns null if not in encounter.
    fn getSnapshot(self: *Coordinator) ?*const query.CombatSnapshot {
        if (self.world.fsm.currentState() != .in_encounter) return null;

        if (self.cached_snapshot == null) {
            self.cached_snapshot = query.buildSnapshot(self.alloc, self.world) catch null;
        }
        return if (self.cached_snapshot) |*snap| snap else null;
    }

    /// Invalidate cached snapshot (call when domain state changes)
    fn invalidateSnapshot(self: *Coordinator) void {
        if (self.cached_snapshot) |*snap| {
            snap.deinit();
            self.cached_snapshot = null;
        }
    }

    // Get the active view with current snapshot
    fn activeView(self: *Coordinator) View {
        return switch (self.world.fsm.currentState()) {
            .splash => View{ .title = title.View.init(self.world) },
            .encounter_summary => View{ .summary = summary.View.init(self.world) },
            .world_map => View{ .title = title.View.init(self.world) },
            .in_encounter => View{ .combat = combat.View.initWithSnapshot(self.world, self.frameAlloc(), self.getSnapshot()) },
        };
    }

    fn isChromeActive(self: *Coordinator) bool {
        return self.world.fsm.currentState() != .splash;
    }

    fn chromeView(self: *Coordinator) chrome.View {
        return chrome.View.init(self.world, &self.combat_log);
    }

    // Handle SDL input event
    pub fn handleInput(self: *Coordinator, sdl_event: s.events.Event) ?Command {
        // Update mouse position on any mouse event
        const vx: f32 = if (self.isChromeActive()) @floatFromInt(chrome.viewport.x) else 0;
        const vy: f32 = if (self.isChromeActive()) @floatFromInt(chrome.viewport.y) else 0;
        switch (sdl_event) {
            .mouse_button_down, .mouse_button_up => |data| {
                self.vs.mouse_vp = self.ux.translateCoords(.{ .x = data.x - vx, .y = data.y - vy });
                self.vs.mouse_novp = self.ux.translateCoords(.{ .x = data.x, .y = data.y });
            },
            .mouse_wheel => |data| {
                self.vs.mouse_vp = self.ux.translateCoords(.{ .x = data.x - vx, .y = data.y - vy });
                self.vs.mouse_novp = self.ux.translateCoords(.{ .x = data.x, .y = data.y });
            },
            .mouse_motion => |data| {
                self.vs.mouse_vp = self.ux.translateCoords(.{ .x = data.x - vx, .y = data.y - vy });
                self.vs.mouse_novp = self.ux.translateCoords(.{ .x = data.x, .y = data.y });
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
        // Invalidate snapshot if any events occurred (domain state changed)
        if (self.world.events.current_events.items.len > 0) {
            self.invalidateSnapshot();
        }

        for (self.world.events.current_events.items) |event| {
            // Delegate animation handling to EffectSystem
            self.effect_system.processEvent(event, &self.vs, self.world);

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
        self.effect_system.tickCardAnimations(dt, &self.vs);
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
