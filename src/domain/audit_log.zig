/// Simple audit logger that writes combat packet events to a file.
/// Used for Phase 1 data audit (geometry/energy/rigidity analysis).
const std = @import("std");
const events = @import("events.zig");

const log_path = "./event.log";

pub fn drainPacketEvents(event_system: *events.EventSystem) void {
    var has_packet_events = false;
    for (event_system.current_events.items) |event| {
        if (event == .combat_packet_resolved) {
            has_packet_events = true;
            break;
        }
    }
    if (!has_packet_events) return;

    const file = std.fs.cwd().createFile(log_path, .{ .truncate = false }) catch |err| {
        std.log.warn("audit_log: failed to open {s}: {}", .{ log_path, err });
        return;
    };
    defer file.close();

    // Seek to end for append
    file.seekFromEnd(0) catch {};

    var buf: [512]u8 = undefined;
    for (event_system.current_events.items) |event| {
        switch (event) {
            .combat_packet_resolved => |data| {
                const line = std.fmt.bufPrint(&buf, "[packet] atk={d} def={d} tech={s} part={d} | " ++
                    "init amt={d:.1} pen={d:.1} geo={d:.2} en={d:.1}J rig={d:.2} | " ++
                    "post amt={d:.1} pen={d:.1} geo={d:.2} en={d:.1}J rig={d:.2} | " ++
                    "layers={d} defl={} gap={} wound={?d}\n", .{
                    data.attacker_id.index,
                    data.defender_id.index,
                    @tagName(data.technique_id),
                    data.target_part,
                    data.initial_amount,
                    data.initial_penetration,
                    data.initial_geometry,
                    data.initial_energy,
                    data.initial_rigidity,
                    data.post_armour_amount,
                    data.post_armour_penetration,
                    data.post_armour_geometry,
                    data.post_armour_energy,
                    data.post_armour_rigidity,
                    data.armour_layers_hit,
                    data.armour_deflected,
                    data.gap_found,
                    data.wound_severity,
                }) catch continue;
                file.writeAll(line) catch {};
            },
            else => {},
        }
    }
}
