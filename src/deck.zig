const std = @import("std");
const lib = @import("infra");
const Event = @import("events.zig").Event;
const EventTag = std.meta.Tag(Event);

const EntityID = @import("entity.zig").EntityID;
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const World = @import("world.zig").World;

const cards = @import("cards.zig");
const Instance = cards.Instance;
const Template = cards.Template;
const card_list = @import("card_list.zig");
const BeginnerDeck = card_list.BeginnerDeck;
const slot_map = @import("slot_map.zig");
const SlotMap = slot_map.SlotMap;

pub const Deck = struct {
    alloc: std.mem.Allocator,
    entities: SlotMap(*Instance),
    deck: std.ArrayList(*Instance),
    hand: std.ArrayList(*Instance),
    exhaust: std.ArrayList(*Instance),

    pub fn init(alloc: std.mem.Allocator, templates: []const Template) !@This() {
        var self = @This(){
            .alloc = alloc,
            .entities = try SlotMap(*Instance).init(alloc),
            .deck = try std.ArrayList(*Instance).initCapacity(alloc, templates.len),
            .hand = try std.ArrayList(*Instance).initCapacity(alloc, templates.len),
            .exhaust = try std.ArrayList(*Instance).initCapacity(alloc, templates.len),
        };
        for (templates) |t| {
            const instance = try self.createInstance(t);
            try self.deck.append(alloc, instance);
        }
        return self;
    }
    
    pub fn deinit(self: *Deck) void {
        self.entities.deinit();
        self.deck.deinit(self.alloc);
        self.hand.deinit(self.alloc);
        self.exhaust.deinit(self.alloc);
    }

    fn createInstance(self: *Deck, template: Template) !*Instance {
        var instance = try self.alloc.create(Instance);
        instance.template = template.id;
        const id: EntityID = try self.entities.insert(instance);
        // does this mutation update the inserted instance? don't think so.
        // should this be a SlotMap(*Instance) instead?
        instance.id = id;
        return instance;
    }
};

