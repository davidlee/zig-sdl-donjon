//! Shared card infrastructure - types common to all card kinds.
//!
//! Actions, items, agents are all "cards" in this card game.
//! This module contains types shared across all card kinds.

pub const Rarity = enum {
    common,
    uncommon,
    rare,
    epic,
    legendary,
};

pub const Zone = enum {
    draw,
    hand,
    discard,
    in_play,
    equipped,
    inventory,
    exhaust,
    limbo, // virtual zone for cards created/injected from nowhere (dud cards)
};
