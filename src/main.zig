const std = @import("std");
const Cast = @import("util").Cast;
const gfx = @import("graphics");
const ctl = @import("controls");
const World = @import("model").World;

const log = std.debug.print;

const s = @import("sdl3");

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

    var world = try World.init(alloc);
    defer {
        world.deinit(alloc);
    }

    const window = try s.video.Window.init(
        "hello world",
        world.config.screen_width,
        world.config.screen_height,
        .{ .resizable = true, .vulkan = true },
    );
    defer window.deinit();

    var renderer = try s.render.Renderer.init(window, null);
    defer renderer.deinit();

    try renderer.setLogicalPresentation(world.config.screen_width, world.config.screen_height, s.render.LogicalPresentation.letter_box);

    // Useful for limiting the FPS and getting the delta time.
    var fps_capper = s.extras.FramerateCapper(f32){ .mode = .{ .limited = world.config.fps } };

    var sprite_sheet = try gfx.SpriteSheet.init(alloc, "assets/urizen_onebit_tileset__v2d0.png", // 2679 x 651
        12, 12, 24, 50, renderer);
    defer sprite_sheet.deinit(alloc);

    var camera = s.rect.IRect{
        .x = 0,
        .y = 0,
        .w = Cast.itoi32(world.ui.width),
        .h = Cast.itoi32(world.ui.height),
    };
    camera.x = 0;

    var quit = false;
    while (!quit) {
        // Delay to limit the FPS, returned delta time not needed.
        _ = fps_capper.delay();

        // Update logic.
        try gfx.render(&world, &renderer, &sprite_sheet);

        // Event logic.
        while (s.events.poll()) |event|
            switch (event) {
                .quit => quit = true,
                .terminating => quit = true,
                .key_down => {
                    quit = ctl.keypress(event.key_down.key.?, &world);
                    // const playerLogicalPos = sprite_sheet.xyOf(world.player.x, world.player.y);
                    // log("\n Logical Pos: {}", .{playerLogicalPos});
                },
                .mouse_motion => {
                    // const playerLogicalPos = sprite_sheet.xyOf(world.player.x, world.player.y);
                    // _ = playerLogicalPos;

                    // log("\n player x,y: {},{} \n", .{ playerLogicalPos.x, playerLogicalPos.y });
                    // log("\n mouse: {} \n world: {} \n player x,y: {},{} \n", .{ event, world, playerLogicalPos.x, playerLogicalPos.y });
                    // const rect = sprite_sheet.toXY(event.mouse_motion.x, event.mouse_motion.y);
                    // log("\n rect: {}",.{rect});

                },
                .mouse_wheel => {
                    // log("\nscroll: -> {any}",.{event});
                    world.ui.zoom = std.math.clamp(world.ui.zoom + event.mouse_wheel.scroll_y, 1.0, 10.0);
                    world.ui.scale_changed = true;

                    // const playerLogicalPos = sprite_sheet.xyOf(world.player.x, world.player.y);
                    // var viewport = s.rect.FRect{
                    //     .h = 0,
                    //     .w = 0,
                    //     .x = 0,
                    //     .y = 0,
                    // };

                    //renderer.setViewport()

                    //renderer.renderCoordinatesFromWindowCoordinates()
                    // log("\n mouse: {} \n world: {} \n player x,y: {},{} \n", .{ event, world, playerLogicalPos.x, playerLogicalPos.y });
                    // log("\nY-SCROLL: {}",.{world.ui.scale});
                    // }
                },
                .window_resized => {
                    world.ui.width = Cast.itou64(event.window_resized.width);
                    world.ui.height = Cast.itou64(event.window_resized.height);
                    world.ui.scale_changed = true;
                    // try renderer.setLogicalPresentation(world.ui.width, world.ui.height, s.render.LogicalPresentation.letter_box);
                },
                else => {
                    // log("\nevent:{any}->\n",.{event});
                },
            };
    }
}
