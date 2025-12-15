pub const Cast = struct {
    pub fn itof32(i: anytype) f32 {
        return @floatFromInt(i);
    }

    pub fn itou64(i: anytype) u64 {
        return @intCast(i);
    }

    pub fn itoi32(i: anytype) i32 {
        return @intCast(i);
    }

};

