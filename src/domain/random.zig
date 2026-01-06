/// Random stream management for deterministic simulations.
///
/// Wraps RNG streams, exposes RandomSource that emits draw events, and keeps
/// seeds for reproducibility. Does not depend on presentation.
const std = @import("std");

const lib = @import("infra");
const events = @import("events.zig");

const EventSystem = events.EventSystem;

pub const RandomSource = struct {
    events: *EventSystem,
    stream: *Stream,
    stream_id: RandomStreamID,

    pub fn drawRandom(self: *RandomSource) !f32 {
        const r = self.stream.random().float(f32);
        try self.events.push(.{ .draw_random = .{ .stream = self.stream_id, .result = r } });
        return r;
    }
};

pub const Stream = struct {
    seed: u64,
    prng: std.Random.DefaultPrng,

    fn init() @This() {
        var seed: u64 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&seed));

        const prng = std.Random.DefaultPrng.init(seed);

        return Stream{
            .seed = seed,
            .prng = prng,
        };
    }

    pub fn random(self: *Stream) std.Random {
        return self.prng.random();
    }
};

pub const RandomStreamID = enum {
    combat,
    deck_builder,
    shuffler,
    effects,
};

pub const RandomStreamDict = struct {
    combat: Stream,
    deck_builder: Stream,
    shuffler: Stream,
    effects: Stream,

    pub fn init() @This() {
        return @This(){
            .combat = Stream.init(),
            .deck_builder = Stream.init(),
            .shuffler = Stream.init(),
            .effects = Stream.init(),
        };
    }

    pub fn get(self: *RandomStreamDict, id: RandomStreamID) *Stream {
        return switch (id) {
            RandomStreamID.combat => &self.combat,
            RandomStreamID.deck_builder => &self.deck_builder,
            RandomStreamID.shuffler => &self.shuffler,
            RandomStreamID.effects => &self.effects,
        };
    }
};
