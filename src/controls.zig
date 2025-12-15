const std = @import("std");
const World= @import("model").World;
const Cast = @import("util").Cast;
const s = @import("sdl3");

pub fn keypress(keycode: s.keycode.Keycode, world: *World) bool {
    switch (keycode) {
        .left => {
            if (world.player.x > 0)
                world.player.x -= 1;
        },
        .right => {
            if (world.player.x < world.max.x - 1)
                world.player.x += 1;
        },
        .up => {
            if (world.player.y > 0)
                world.player.y -= 1;
        },
        .down => {
            if (world.player.y < world.max.y - 1)
                world.player.y += 1;
        },
        .escape => {
            return true;
        },
        else => {},
    }
    return false;
}
