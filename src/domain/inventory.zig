const std = @import("std");
const body = @import("body.zig");

pub const Layer = enum(u8) {
    Skin = 0, // Tattoos, Piercings
    Underwear = 1, // Loincloth, singlet, socks
    CloseFit = 2, // Shirt, Rings (if under glove)
    Gambeson = 3, // Padding
    Mail = 4, // Chainmail
    Plate = 5, // Rigid Armor
    Outer = 6, // Tabard, Surcote, Overcoat
    Cloak = 7, // Weather protection
    Strapped = 8, // Backpacks, sheathed weapons
};

// inventory
//
pub const Coverage = struct {
    part_tags: []const body.PartTag,
    layer: Layer,
};

pub const ItemDef = struct {
    name: []const u8,
    // configurations: []const []const Coverage,
    coverage: []const Coverage,
};
