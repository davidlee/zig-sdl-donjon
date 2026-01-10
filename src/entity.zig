pub const EntityKind = enum(u8) {
    action, // cards.Instance
    agent, // combat.Agent
    weapon, // weapon.Instance
    armour, // armour.Instance (no registry yet, placeholder)
    item, // T048 placeholder
};

pub const ID = struct {
    index: u32,
    generation: u32,
    kind: EntityKind,

    pub fn eql(self: ID, other: ID) bool {
        return self.kind == other.kind and
            self.index == other.index and
            self.generation == other.generation;
    }
};

pub const EntityID = ID; // deprecated
