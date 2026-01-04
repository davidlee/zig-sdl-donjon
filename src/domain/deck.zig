const std = @import("std");
const lib = @import("infra");
const damage = @import("damage.zig");
const stats = @import("stats.zig");
const cards = @import("cards.zig");
const card_list = @import("card_list.zig");
const slot_map = @import("slot_map.zig");
const events = @import("events.zig");

const entity = lib.entity;
const world_mod = @import("world.zig");
const World = world_mod.World;
const CardRegistry = world_mod.CardRegistry;
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
    registry: ?*CardRegistry, // External registry for instance storage (null = legacy mode)
    entities: SlotMap(*Instance), // Legacy: entity.ID provider (only used if registry is null)

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
        const i = try Deck.findInternal(id, from);
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

    fn findInternal(id: entity.ID, pile: *std.ArrayList(*Instance)) !usize {
        for (pile.items, 0..) |card, i| {
            if (card.id.eql(id)) return i;
        }
        return DeckError.NotFound;
    }

    fn createInstance(self: *Deck, template: *const Template) !*Instance {
        if (self.registry) |reg| {
            // Use external registry (new system)
            return reg.create(template);
        } else {
            // Legacy: use internal SlotMap
            const instance = try self.alloc.create(Instance);
            instance.template = template;
            const id: entity.ID = try self.entities.insert(instance);
            instance.id = id;
            return instance;
        }
    }

    /// Initialize with external CardRegistry (new system).
    /// Instances are owned by the registry, not this Deck.
    pub fn initWithRegistry(alloc: std.mem.Allocator, registry: *CardRegistry, templates: []const Template) !@This() {
        var self = @This(){
            .alloc = alloc,
            .registry = registry,
            .entities = try SlotMap(*Instance).init(alloc), // unused but required for struct
            .draw = try std.ArrayList(*Instance).initCapacity(alloc, 20),
            .hand = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .discard = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .in_play = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .equipped = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .inventory = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .exhaust = try std.ArrayList(*Instance).initCapacity(alloc, 10),
            .techniques = std.StringHashMap(*const cards.Technique).init(alloc),
        };

        try self.populateFromTemplates(templates);
        return self;
    }

    /// Legacy init without registry (instances owned by this Deck).
    pub fn init(alloc: std.mem.Allocator, templates: []const Template) !@This() {
        var self = @This(){
            .alloc = alloc,
            .registry = null,
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

        try self.populateFromTemplates(templates);
        return self;
    }

    fn populateFromTemplates(self: *Deck, templates: []const Template) !void {
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
                try self.discard.append(self.alloc, instance);
            }
        }
    }

    pub fn allInstances(self: *Deck) []*Instance {
        if (self.registry) |_| {
            // When using registry, we don't have a local list of all instances
            // This is a legacy method - callers should use registry directly
            return &.{};
        }
        return self.entities.items.items;
    }

    /// Get all card IDs from the discard pile (where cards start).
    /// Used to populate Agent.deck_cards for the new card storage system.
    pub fn allCardIds(self: *const Deck) []const entity.ID {
        // Cards start in discard pile after Deck.init
        // Return their IDs as a slice (caller must copy if needed)
        const instances = self.discard.items;
        // We need to extract IDs - but we can't return a slice of IDs easily
        // without allocating. For now, return empty and let caller iterate.
        _ = instances;
        return &.{};
    }

    /// Copy all card IDs from the deck to a target ArrayList.
    /// Used to populate Agent.deck_cards.
    pub fn copyCardIdsTo(self: *const Deck, alloc: std.mem.Allocator, target: *std.ArrayList(entity.ID)) !void {
        // Cards in discard (where they start after init)
        for (self.discard.items) |instance| {
            try target.append(alloc, instance.id);
        }
        // Also include cards in other zones (in case deck was modified)
        for (self.draw.items) |instance| {
            try target.append(alloc, instance.id);
        }
        for (self.hand.items) |instance| {
            try target.append(alloc, instance.id);
        }
        for (self.in_play.items) |instance| {
            try target.append(alloc, instance.id);
        }
        for (self.exhaust.items) |instance| {
            try target.append(alloc, instance.id);
        }
    }

    pub fn deinit(self: *Deck) void {
        // Only free instances if we own them (legacy mode)
        if (self.registry == null) {
            for (self.entities.items.items) |instance| {
                self.alloc.destroy(instance);
            }
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

    pub fn find(self: *Deck, id: entity.ID, zone: Zone) !*Instance {
        const pile = self.pileForZone(zone);
        const i = try Deck.findInternal(id, pile);
        return pile.items[i];
    }

    pub fn instanceInZone(self: *Deck, id: entity.ID, zone: Zone) bool {
        _ = Deck.findInternal(id, self.pileForZone(zone)) catch return false;
        return true;
    }

    /// Fisher-Yates shuffle of the draw pile
    pub fn shuffleDrawPile(self: *Deck, rand: anytype) !void {
        const items = self.draw.items;
        var i = items.len;
        while (i > 1) {
            i -= 1;
            const r = try rand.drawRandom();
            const j: usize = @intFromFloat(r * @as(f32, @floatFromInt(i + 1)));
            std.mem.swap(*Instance, &items[i], &items[j]);
        }
    }
};
