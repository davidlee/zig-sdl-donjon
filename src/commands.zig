// const std = @import("std");
// const events= @import("events.zig");
// const Event = events.Event;
// const CardWithSlot= events.CardWithSlot;
// const CardWithEvent= events.CardWithEvent;
// const EntityID = @import("entity.zig").EntityID;
// const World = @import("world.zig").World;
//
//
// const Command = union(enum) {
//     play_action: EntityID,
//     play_reaction: struct { card: EntityID, event: Event },
//     equip_item: CardWithSlot,
//     unequip_item: CardWithSlot,
//
//     equip_spell: CardWithSlot,
//     unequip_spell: CardWithSlot,
//
//     equip_passive: CardWithSlot,
//     unequip_passive: CardWithSlot,
//
//     end_turn: void,
// };
//
// const CommandHandler = struct {
//     world: *World,
//
//     pub fn resolve(self: *CommandHandler, cmd: Command) ![]Event {
//         switch(cmd) {
//             .play_action => |data| {
//                 if(true) {
//                     return .{ Event{ .played_card = data }};
//                 }
//             },
//             .play_reaction => |data| {
//                 if (true) {
//                     return .{ Event { .played_reaction = CardWithEvent{ card: data.card, event: data.event }}}
//                 }
//             },
//             else => {
//                 std.logger.debug("unhandled command: {}", .{cmd});
//             }
//         }
//     }
// };
