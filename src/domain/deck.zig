const std = @import("std");
const lib = @import("infra");
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const slot_map = @import("slot_map.zig");
const events = @import("events.zig");

const entity = lib.entity;
const World = @import("world.zig").World;
const Instance = cards.Instance;
const Event = events.Event;
const EventTag = std.meta.Tag(Event);
const Template = cards.Template;
const Zone = cards.Zone;

const BeginnerDeck = card_list.BeginnerDeck;
const SlotMap = slot_map.SlotMap;

const DeckError = error{
    NotFound,
};

pub const Deck = struct {
    alloc: std.mem.Allocator,
    entities: SlotMap(*Instance), // entity.ID provider

    // card piles
    draw: std.ArrayList(*Instance),
    hand: std.ArrayList(*Instance),
    discard: std.ArrayList(*Instance),
    in_play: std.ArrayList(*Instance),
    equipped: std.ArrayList(*Instance),
    inventory: std.ArrayList(*Instance),
    exhaust: std.ArrayList(*Instance),

    // FIXME move these out
    techniques: std.StringHashMap(*const cards.Technique),

    fn moveInternal(self: *Deck, id: entity.ID, from: *std.ArrayList(*Instance), to: *std.ArrayList(*Instance)) !void {
        const i = try Deck.find(id, from);
        const instance = from.orderedRemove(i);
        try to.append(self.alloc, instance);
    }

    fn pileForZone(self: *Deck, zone: cards.Zone) *std.ArrayList(*Instance) {
        return switch (zone) {
            .draw => &self.draw,
            .hand => &self.hand,
            .in_play => &self.in_play,
            .discard => &self.discard,
            .equipped => &self.equipped,
            .inventory => &self.inventory,
            .exhaust => &self.exhaust,
        };
    }

    fn find(id: entity.ID, pile: *std.ArrayList(*Instance)) !usize {
        var i: usize = 0;
        while (i < pile.items.len) : (i += 1) {
            const card = pile.items[i];
            if (card.id.index == id.index and card.id.generation == id.generation) return i;
        }
        return DeckError.NotFound;
    }

    fn createInstance(self: *Deck, template: *const Template) !*Instance {
        var instance = try self.alloc.create(Instance);
        // std.debug.print("insert: {s}", .{template.name});
        instance.template = template;
        // std.debug.print(" -- insert: {s}\n", .{instance.template.name});
        const id: entity.ID = try self.entities.insert(instance);
        instance.id = id;
        return instance;
    }

    pub fn init(alloc: std.mem.Allocator, templates: []const Template) !@This() {
        var self = @This(){
            .alloc = alloc,
            .entities = try SlotMap(*Instance).init(alloc),
            .draw = try std.ArrayList(*Instance).initCapacity(alloc, 20),
            .hand = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .discard = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .in_play = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .equipped = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .inventory = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .exhaust = try std.ArrayList(*Instance).initCapacity(alloc, 10),

            .techniques = std.StringHashMap(*const cards.Technique).init(alloc),
        };

        for (templates) |*t| {
            for (t.rules) |rule| {
                for (rule.expressions) |expr| {
                    switch (expr.effect) {
                        .combat_technique => |value| {
                            if (self.techniques.get(value.name) == null) {
                                try self.techniques.put(value.name, &value);
                            }
                        },
                        else => {},
                    }
                }
            }

            for (0..5) |_| {
                const instance = try self.createInstance(t);
                try self.draw.append(alloc, instance);
            }

            // TODO shuffle, etc
        }
        return self;
    }

    pub fn allInstances(self: *Deck) []*Instance {
        return self.entities.items.items;
    }

    pub fn deinit(self: *Deck) void {
        // Free all allocated instances
        for (self.entities.items.items) |instance| {
            self.alloc.destroy(instance);
        }
        self.entities.deinit();
        self.draw.deinit(self.alloc);
        self.hand.deinit(self.alloc);
        self.discard.deinit(self.alloc);
        self.in_play.deinit(self.alloc);
        self.equipped.deinit(self.alloc);
        self.inventory.deinit(self.alloc);
        self.exhaust.deinit(self.alloc);
        self.techniques.deinit();
    }

    pub fn move(self: *Deck, id: entity.ID, from: Zone, to: Zone) !void {
        try self.moveInternal(id, self.pileForZone(from), self.pileForZone(to));
    }

    pub fn instanceInZone(self: *Deck, id: entity.ID, zone: Zone) bool {
        _ = Deck.find(id, self.pileForZone(zone)) catch return false;
        return true;
    }
};
