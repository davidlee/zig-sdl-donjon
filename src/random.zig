const std = @import("std");

pub const Stream = struct {
    seed: u64,
    rng: std.Random,

    pub fn init() @This() {
        var seed: u64 = undefined;
        std.crypto.random.bytes(std.mem.asBytes(&seed));

        // 2. Initialize a PRNG instance with the seed
        var prng = std.Random.DefaultPrng.init(seed);
        const rng = prng.random(); // Get the random number generator interface

        return Stream {
            .seed = seed,
            .rng = rng,
        };
    }
};
