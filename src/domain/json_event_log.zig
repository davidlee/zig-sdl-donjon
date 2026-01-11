const std = @import("std");
const events = @import("events.zig");

const default_path = "events.log.json";

pub const JsonEventLog = struct {
    file: ?std.fs.File,
    frame_number: u64,

    pub fn init(path: ?[]const u8) JsonEventLog {
        const file = std.fs.cwd().createFile(path orelse default_path, .{ .truncate = true }) catch |err| {
            std.log.warn("json_event_log: failed to open {s}: {}", .{ path orelse default_path, err });
            return .{ .file = null, .frame_number = 0 };
        };

        return .{ .file = file, .frame_number = 0 };
    }

    pub fn deinit(self: *JsonEventLog) void {
        if (self.file) |f| f.close();
    }

    pub fn drainAllEvents(self: *JsonEventLog, event_system: *events.EventSystem) void {
        const file = self.file orelse return;
        if (event_system.current_events.items.len == 0) return;

        var buf: [4096]u8 = undefined;
        for (event_system.current_events.items) |event| {
            const len = writeEventJson(&buf, self.frame_number, event);
            if (len > 0) {
                file.writeAll(buf[0..len]) catch {};
            }
        }
    }

    pub fn advanceFrame(self: *JsonEventLog) void {
        self.frame_number += 1;
    }
};

fn writeEventJson(buf: []u8, frame: u64, event: events.Event) usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.print("{{\"frame\":{d},\"type\":\"{s}\"", .{ frame, @tagName(event) }) catch return 0;

    switch (event) {
        .entity_died => |id| w.print(",\"id\":{d}}}\n", .{id}) catch return 0,
        .mob_died => |id| w.print(",\"id\":{{\"index\":{d},\"gen\":{d}}}}}\n", .{ id.index, id.generation }) catch return 0,

        .played_action_card => |d| w.print(",\"template\":{d},\"actor\":{{\"id\":{d},\"player\":{}}}}}\n", .{ d.template, d.actor.id.index, d.actor.player }) catch return 0,
        .card_moved => |d| w.print(",\"from\":\"{s}\",\"to\":\"{s}\",\"actor\":{d}}}\n", .{ @tagName(d.from), @tagName(d.to), d.actor.id.index }) catch return 0,
        .card_cancelled => |d| w.print(",\"actor\":{d}}}\n", .{d.actor.id.index}) catch return 0,

        .game_state_transitioned_to => |s| w.print(",\"state\":\"{s}\"}}\n", .{@tagName(s)}) catch return 0,
        .turn_phase_transitioned_to => |p| w.print(",\"phase\":\"{s}\"}}\n", .{@tagName(p)}) catch return 0,

        .wound_inflicted => |d| w.print(",\"agent\":{d},\"part\":{d},\"tag\":\"{s}\",\"severity\":{d}}}\n", .{ d.agent_id.index, d.part_idx, @tagName(d.part_tag), @intFromEnum(d.wound.worstSeverity()) }) catch return 0,
        .body_part_severed => |d| w.print(",\"agent\":{d},\"part\":{d},\"tag\":\"{s}\"}}\n", .{ d.agent_id.index, d.part_idx, @tagName(d.part_tag) }) catch return 0,
        .hit_major_artery => |d| w.print(",\"agent\":{d},\"part\":{d}}}\n", .{ d.agent_id.index, d.part_idx }) catch return 0,

        .armour_deflected => |d| w.print(",\"agent\":{d},\"part\":{d},\"layer\":{d}}}\n", .{ d.agent_id.index, d.part_idx, d.layer }) catch return 0,
        .armour_absorbed => |d| w.print(",\"agent\":{d},\"reduced\":{d:.2},\"layers\":{d}}}\n", .{ d.agent_id.index, d.damage_reduced, d.layers_hit }) catch return 0,
        .armour_layer_destroyed => |d| w.print(",\"agent\":{d},\"layer\":{d}}}\n", .{ d.agent_id.index, d.layer }) catch return 0,
        .attack_found_gap => |d| w.print(",\"agent\":{d},\"layer\":{d}}}\n", .{ d.agent_id.index, d.layer }) catch return 0,

        .technique_resolved => |d| w.print(",\"attacker\":{d},\"defender\":{d},\"technique\":\"{s}\",\"outcome\":\"{s}\",\"hit_chance\":{d:.2},\"roll\":{d:.2}}}\n", .{ d.attacker_id.index, d.defender_id.index, @tagName(d.technique_id), @tagName(d.outcome), d.hit_chance, d.roll }) catch return 0,

        .contested_roll_resolved => |d| w.print(",\"attacker\":{d},\"defender\":{d},\"technique\":\"{s}\",\"outcome\":\"{s}\",\"margin\":{d:.3},\"dmg_mult\":{d:.2},\"atk_raw\":{d:.3},\"def_raw\":{d:.3}}}\n", .{ d.attacker_id.index, d.defender_id.index, @tagName(d.technique_id), @tagName(d.outcome_type), d.margin, d.damage_mult, d.attack.raw(), d.defense.raw() }) catch return 0,

        .combat_packet_resolved => |d| w.print(",\"attacker\":{d},\"defender\":{d},\"technique\":\"{s}\",\"init_geo\":{d:.2},\"init_en\":{d:.1},\"init_rig\":{d:.2},\"post_geo\":{d:.2},\"post_en\":{d:.1},\"deflected\":{},\"wound\":{?d}}}\n", .{ d.attacker_id.index, d.defender_id.index, @tagName(d.technique_id), d.initial_geometry, d.initial_energy, d.initial_rigidity, d.post_armour_geometry, d.post_armour_energy, d.armour_deflected, d.wound_severity }) catch return 0,

        .manoeuvre_contest_resolved => |d| w.print(",\"aggressor\":{d},\"defender\":{d},\"outcome\":\"{s}\"}}\n", .{ d.aggressor_id.index, d.defender_id.index, @tagName(d.outcome) }) catch return 0,

        .advantage_changed => |d| w.print(",\"agent\":{d},\"axis\":\"{s}\",\"old\":{d:.2},\"new\":{d:.2}}}\n", .{ d.agent_id.index, @tagName(d.axis), d.old_value, d.new_value }) catch return 0,
        .range_changed => |d| w.print(",\"actor\":{d},\"old\":\"{s}\",\"new\":\"{s}\"}}\n", .{ d.actor_id.index, @tagName(d.old_range), @tagName(d.new_range) }) catch return 0,
        .position_changed => |d| w.print(",\"actor\":{d},\"old\":{d:.2},\"new\":{d:.2}}}\n", .{ d.actor_id.index, d.old_position, d.new_position }) catch return 0,

        .stamina_deducted => |d| w.print(",\"agent\":{d},\"amount\":{d:.2},\"new\":{d:.2}}}\n", .{ d.agent_id.index, d.amount, d.new_value }) catch return 0,
        .stamina_recovered => |d| w.print(",\"agent\":{d},\"amount\":{d:.2},\"new\":{d:.2}}}\n", .{ d.agent_id.index, d.amount, d.new_value }) catch return 0,
        .focus_recovered => |d| w.print(",\"agent\":{d},\"amount\":{d:.2},\"new\":{d:.2}}}\n", .{ d.agent_id.index, d.amount, d.new_value }) catch return 0,
        .blood_drained => |d| w.print(",\"agent\":{d},\"amount\":{d:.2},\"new\":{d:.2}}}\n", .{ d.agent_id.index, d.amount, d.new_value }) catch return 0,

        .condition_applied => |d| w.print(",\"agent\":{d},\"condition\":\"{s}\"}}\n", .{ d.agent_id.index, @tagName(d.condition) }) catch return 0,
        .condition_expired => |d| w.print(",\"agent\":{d},\"condition\":\"{s}\"}}\n", .{ d.agent_id.index, @tagName(d.condition) }) catch return 0,
        .cooldown_applied => |d| w.print(",\"agent\":{d},\"ticks\":{d}}}\n", .{ d.agent_id.index, d.ticks }) catch return 0,

        .combat_ended => |outcome| w.print(",\"outcome\":\"{s}\"}}\n", .{@tagName(outcome)}) catch return 0,

        .player_turn_ended, .player_committed, .tick_ended => w.writeAll("}\n") catch return 0,

        .card_cloned,
        .play_moved,
        .card_cost_reserved,
        .card_cost_returned,
        .attack_out_of_range,
        .primary_target_changed,
        .played_reaction,
        .equipped_item,
        .unequipped_item,
        .equipped_spell,
        .unequipped_spell,
        .equipped_passive,
        .unequipped_passive,
        .draw_random,
        .play_sound,
        => w.writeAll("}\n") catch return 0,
    }

    return fbs.pos;
}
