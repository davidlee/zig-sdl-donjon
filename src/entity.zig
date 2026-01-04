pub const ID = struct {
    index: u32,
    generation: u32,

    pub fn eql(self: ID, other: ID) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};
pub const EntityID = ID; // deprecated
