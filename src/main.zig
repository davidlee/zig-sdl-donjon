const std = @import("std");
const lib = @import("infra");
const s = @import("sdl3");

const Cast = lib.Cast;
const log = lib.log;

// domain
const World = @import("domain/world.zig").World;
const cards = @import("domain/cards.zig");
const deck = @import("domain/action_list.zig").BeginnerDeck;
const harness = @import("harness.zig");
const resolution = @import("domain/resolution.zig");
const weapon_list = @import("domain/weapon_list.zig");
const tick = @import("domain/tick.zig");
const apply = @import("domain/apply.zig");
const CommandHandler = apply.CommandHandler;
const CommandError = apply.CommandError;
const audit_log = @import("domain/audit_log.zig");
const json_event_log = @import("domain/json_event_log.zig");

// const coordinator = @import("presentation/coordinator.zig");
const presentation = @import("presentation/mod.zig");

// presentation
const ctrl = @import("presentation/controls.zig");
const gfx = @import("presentation/graphics.zig");

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

    var event_log = json_event_log.JsonEventLog.init(null);
    defer event_log.deinit();

    var ux = try gfx.UX.init(alloc, &config);
    defer ux.deinit();

    // make sure we got a mob, etc
    try harness.setupEncounter(world);

    var coordinator = try presentation.Coordinator.init(alloc, world, &ux);
    defer coordinator.deinit();

    var quit = false;

    while (!quit) {
        // SDL Event handlers
        while (s.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                else => {
                    // if the coordinator yields a command from user input, handle it
                    const cmd = coordinator.handleInput(event);
                    if (cmd) |c| world.commandHandler.handle(c) catch |err| log("ERR: {any}\n", .{err});

                    // or it might be a system event. let coordinator figure it out.
                    coordinator.processSystemEvent(event);
                },
            };

        // Update logic.
        try world.step();

        // swap event streams
        world.events.swap_buffers();

        // audit log for damage packet analysis
        audit_log.drainPacketEvents(&world.events);

        // JSON event log for all events
        event_log.drainAllEvents(&world.events);
        event_log.advanceFrame();

        // read this frame's events
        try coordinator.processWorldEvents();

        // Delay to limit the FPS, returned delta time used for animation timing
        try coordinator.update(ux.fps_capper.delay());

        // render
        try coordinator.render();
    }
}

// Force test discovery for all modules with tests
test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("domain/body.zig");
    _ = @import("domain/species.zig");
    _ = @import("domain/resolution.zig");
    _ = @import("domain/weapon_list.zig");
    _ = @import("domain/armour_list.zig");
    _ = @import("domain/tick.zig");
    _ = @import("testing/mod.zig");
}
