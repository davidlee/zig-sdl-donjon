const std = @import("std");
pub const Scaling = struct {
    stats: CheckSignature,
    ratio: f32 = 1.0,
};

pub const CheckSignature = union(enum) {
    stat: Accessor,
    average: [2]Accessor,
};

pub const Accessor = enum {
    power,
    speed,
    agility,
    dexterity,
    fortitude,
    endurance,
    acuity,
    will,
    intuition,
    presence,
};

pub const Template = Block;

pub const Block = packed struct {
    // physical
    power: f32,
    speed: f32,
    agility: f32,
    dexterity: f32,
    fortitude: f32,
    endurance: f32,
    // mental
    acuity: f32,
    will: f32,
    intuition: f32,
    presence: f32,

    pub fn splat(num: f32) Block {
        return Block{
            .power = num,
            .speed = num,
            .agility = num,
            .dexterity = num,
            .fortitude = num,
            .endurance = num,
            // mental
            .acuity = num,
            .will = num,
            .intuition = num,
            .presence = num,
        };
    }

    pub fn get(self: *Block, a: Accessor) f32 {
        return switch (a) {
            .power => self.power,
            .speed => self.speed,
            .agility => self.agility,
            .dexterity => self.dexterity,
            .fortitude => self.fortitude,
            .endurance => self.endurance,
            .acuity => self.acuity,
            .will => self.will,
            .intuition => self.intuition,
            .presence => self.presence,
        };
    }
};
