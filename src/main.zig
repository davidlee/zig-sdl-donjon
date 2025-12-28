const std = @import("std");
const lib = @import("infra");

const Cast = lib.Cast;
const log = lib.log;
const s = lib.sdl;

// const gfx = lib.gfx;
const World = @import("world.zig").World;
const ctrl = @import("controls.zig");
const gfx = @import("graphics.zig");
const cards = @import("cards.zig");
const deck = @import("card_list.zig").BeginnerDeck;

const harness = @import("harness.zig");
const resolution = @import("resolution.zig");
const weapon_list = @import("weapon_list.zig");
const tick = @import("tick.zig");

const CommandHandler = @import("apply.zig").CommandHandler;

pub fn main() !void {
    defer s.shutdown();

    // Initialize SDL with subsystems you need here.
    const init_flags = s.InitFlags{ .video = true, .events = true };
    try s.init(init_flags);
    defer s.quit(init_flags);

    var gpa = std.heap.DebugAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        _ = gpa.deinit();
    }

    const config = lib.config.Config.init();

    var world = try World.init(alloc);
    world.attachEventHandlers();
    defer {
        world.deinit();
    }

    var ux = try gfx.UX.init(alloc, &config);

    var quit = false;
    while (!quit) {
        // Delay to limit the FPS, returned delta time not needed.
        _ = ux.fps_capper.delay();

        // Update logic.
        try world.step();

        try ux.render(world);

        // swap event streams
        world.events.swap_buffers();

        // SDL Event handlers
        while (s.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                .key_down => {
                    quit = ctrl.keypress(event.key_down.key.?, world);
                },
                .mouse_motion => {
                    ux.ui.mouse = s.rect.FPoint{ .x = event.mouse_motion.x, .y = event.mouse_motion.y };
                },
                .mouse_wheel => {
                    // world.ui.zoom = std.math.clamp(world.ui.zoom + event.mouse_wheel.scroll_y, 1.0, 10.0);
                },
                .window_resized => {
                    ux.ui.screen.w = event.window_resized.width;
                    ux.ui.screen.h = event.window_resized.height;
                },
                .window_pixel_size_changed => {
                    ux.ui.screen.w = event.window_pixel_size_changed.width;
                    ux.ui.screen.h = event.window_pixel_size_changed.height;
                },
                else => {
                    // log("\nevent:{any}->\n", .{event});
                },
            };
    }
}

// Force test discovery for all modules with tests
test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("body.zig");
    _ = @import("resolution.zig");
    _ = @import("weapon_list.zig");
    _ = @import("tick.zig");
}
