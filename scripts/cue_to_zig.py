#!/usr/bin/env python3
"""
Simple prototype converter that turns CUE-exported JSON into Zig data tables.

Usage:
    cue export data/materials.cue data/weapons.cue --out json | \
        ./scripts/cue_to_zig.py > src/gen/generated_data.zig
"""

import json
import sys
from typing import Any, Dict, List, Tuple, Set

TECHNIQUE_ENUM_PATH = "src/domain/cards.zig"


def load_json() -> Dict[str, Any]:
    if len(sys.argv) == 2:
        path = sys.argv[1]
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    data = sys.stdin.read()
    return json.loads(data)


def flatten_weapons(root: Dict[str, Any]) -> List[Tuple[str, Dict[str, Any]]]:
    results: List[Tuple[str, Dict[str, Any]]] = []

    def visit(prefix: List[str], node: Dict[str, Any]) -> None:
        for key, value in node.items():
            if not isinstance(value, dict):
                continue
            next_prefix = prefix + [key]
            if "name" in value:
                weapon_id = ".".join(next_prefix)
                results.append((weapon_id, value))
            else:
                visit(next_prefix, value)

    visit([], root)
    return results


def zig_bool(value: bool) -> str:
    return "true" if value else "false"


def zig_float(value: float) -> str:
    return f"{value:.4f}".rstrip("0").rstrip(".")


def emit_weapons(weapons: List[Tuple[str, Dict[str, Any]]]) -> str:
    lines: List[str] = []
    lines.append("const WeaponDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    name: []const u8,")
    lines.append("    category: []const u8,")
    lines.append("    weight_kg: f32,")
    lines.append("    length_m: f32,")
    lines.append("    balance: f32,")
    lines.append("    swing: bool,")
    lines.append("    thrust: bool,")
    lines.append("    moment_of_inertia: f32 = 0,")
    lines.append("    effective_mass: f32 = 0,")
    lines.append("    reference_energy_j: f32 = 0,")
    lines.append("    geometry_coeff: f32 = 0,")
    lines.append("    rigidity_coeff: f32 = 0,")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedWeapons = [_]WeaponDefinition{")
    for weapon_id, data in weapons:
        phys = data.get("derived", {})
        lines.append("    .{")
        lines.append(f'        .id = "{weapon_id}",')
        lines.append(f'        .name = "{data.get("name", weapon_id)}",')
        lines.append(f'        .category = "{data.get("category", "unknown")}",')
        lines.append(f'        .weight_kg = {zig_float(data.get("weight_kg", 0.0))},')
        lines.append(f'        .length_m = {zig_float(data.get("length_m", 0.0))},')
        lines.append(f'        .balance = {zig_float(data.get("balance", 0.0))},')
        lines.append(f'        .swing = {zig_bool(bool(data.get("swing", False)))},')
        lines.append(f'        .thrust = {zig_bool(bool(data.get("thrust", False)))},')
        lines.append(f'        .moment_of_inertia = {zig_float(phys.get("moment_of_inertia", 0.0))},')
        lines.append(f'        .effective_mass = {zig_float(phys.get("effective_mass", 0.0))},')
        lines.append(f'        .reference_energy_j = {zig_float(phys.get("reference_energy_j", 0.0))},')
        lines.append(f'        .geometry_coeff = {zig_float(phys.get("geometry_coeff", 0.0))},')
        lines.append(f'        .rigidity_coeff = {zig_float(phys.get("rigidity_coeff", 0.0))},')
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines)


def flatten_techniques(root: Dict[str, Any]) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    for key, value in root.items():
        if isinstance(value, dict):
            entry = dict(value)
            entry.setdefault("id", key)
            results.append(entry)
    return results
def format_height(value: Any) -> str:
    if not value:
        return "null"
    return f"body.Height.{value}"


def format_damage_types(types: List[str]) -> str:
    if not types:
        return "&.{}"
    inner = ", ".join(f"damage.Kind.{t}" for t in types)
    return f"&.{{ {inner} }}"


def format_scaling(scaling: Dict[str, Any]) -> str:
    ratio = zig_float(scaling.get("ratio", 1.0))
    stats = scaling.get("stats", {})
    if "stat" in stats:
        accessor = stats["stat"]
        return f".{{ .ratio = {ratio}, .stats = .{{ .stat = stats.Accessor.{accessor} }} }}"
    average = stats.get("average", [])
    if average and len(average) == 2:
        return (
            ".{ .ratio = "
            + ratio
            + ", .stats = .{ .average = .{ stats.Accessor."
            + average[0]
            + ", stats.Accessor."
            + average[1]
            + " } } }"
        )
    return f".{{ .ratio = {ratio}, .stats = .{{ .stat = stats.Accessor.power }} }}"


def emit_techniques(techniques: List[Dict[str, Any]]) -> str:
    lines: List[str] = []
    lines.append("const TechniqueChannels = struct {")
    lines.append("    weapon: bool = false,")
    lines.append("    off_hand: bool = false,")
    lines.append("    footwork: bool = false,")
    lines.append("};")
    lines.append("")
    lines.append("pub const TechniqueDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    name: []const u8,")
    lines.append("    attack_mode: []const u8,")
    lines.append("    target_height: ?body.Height = null,")
    lines.append("    secondary_height: ?body.Height = null,")
    lines.append("    guard_height: ?body.Height = null,")
    lines.append("    covers_adjacent: bool = false,")
    lines.append("    difficulty: f32 = 0,")
    lines.append("    channels: TechniqueChannels = .{},")
    lines.append("    damage_instances: []const damage.Instance = &.{},")
    lines.append("    scaling: stats.Scaling = .{ .ratio = 1.0, .stats = .{ .stat = stats.Accessor.power } },")
    lines.append("    deflect_mult: f32 = 1.0,")
    lines.append("    parry_mult: f32 = 1.0,")
    lines.append("    dodge_mult: f32 = 1.0,")
    lines.append("    counter_mult: f32 = 1.0,")
    lines.append("    overlay_offensive_to_hit_bonus: f32 = 0,")
    lines.append("    overlay_offensive_damage_mult: f32 = 1,")
    lines.append("    overlay_defensive_defense_bonus: f32 = 0,")
    lines.append("    axis_geometry_mult: f32 = 1,")
    lines.append("    axis_energy_mult: f32 = 1,")
    lines.append("    axis_rigidity_mult: f32 = 1,")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedTechniques = [_]TechniqueDefinition{")
    for entry in techniques:
        lines.append("    .{")
        lines.append(f'        .id = "{entry.get("id", "")}",')
        lines.append(f'        .name = "{entry.get("name", "")}",')
        lines.append(f'        .attack_mode = "{entry.get("attack_mode", "none")}",')
        lines.append(f"        .target_height = {format_height(entry.get('target_height'))},")
        lines.append(f"        .secondary_height = {format_height(entry.get('secondary_height'))},")
        lines.append(f"        .guard_height = {format_height(entry.get('guard_height'))},")
        lines.append(f"        .covers_adjacent = {zig_bool(entry.get('covers_adjacent', False))},")
        lines.append(f"        .difficulty = {zig_float(entry.get('difficulty', 0.0))},")
        channels = entry.get("channels", {})
        lines.append(
            "        .channels = .{ .weapon = "
            + zig_bool(channels.get("weapon", False))
            + ", .off_hand = "
            + zig_bool(channels.get("off_hand", False))
            + ", .footwork = "
            + zig_bool(channels.get("footwork", False))
            + " },"
        )
        damage_block = entry.get("damage", {})
        instances = damage_block.get("instances", [])
        lines.append("        .damage_instances = &.{")
        for inst in instances:
            types = format_damage_types(inst.get("types", []))
            lines.append(
                "            .{ .amount = "
                + zig_float(inst.get("amount", 0.0))
                + ", .types = "
                + types
                + " },"
            )
        lines.append("        },")
        scaling = damage_block.get("scaling", {})
        lines.append(f"        .scaling = {format_scaling(scaling)},")
        lines.append(f'        .deflect_mult = {zig_float(entry.get("deflect_mult", 1.0))},')
        lines.append(f'        .parry_mult = {zig_float(entry.get("parry_mult", 1.0))},')
        lines.append(f'        .dodge_mult = {zig_float(entry.get("dodge_mult", 1.0))},')
        lines.append(f'        .counter_mult = {zig_float(entry.get("counter_mult", 1.0))},')
        overlay = entry.get("overlay_bonus", {})
        offensive = overlay.get("offensive", {})
        defensive = overlay.get("defensive", {})
        lines.append(
            f'        .overlay_offensive_to_hit_bonus = {zig_float(offensive.get("to_hit_bonus", 0.0))},'
        )
        lines.append(
            f'        .overlay_offensive_damage_mult = {zig_float(offensive.get("damage_mult", 1.0))},'
        )
        lines.append(
            f'        .overlay_defensive_defense_bonus = {zig_float(defensive.get("defense_bonus", 0.0))},'
        )
        axis = entry.get("axis_bias", {})
        lines.append(f'        .axis_geometry_mult = {zig_float(axis.get("geometry_mult", 1.0))},')
        lines.append(f'        .axis_energy_mult = {zig_float(axis.get("energy_mult", 1.0))},')
        lines.append(f'        .axis_rigidity_mult = {zig_float(axis.get("rigidity_mult", 1.0))},')
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines)


def load_existing_technique_ids() -> Set[str]:
    ids: Set[str] = set()
    try:
        with open(TECHNIQUE_ENUM_PATH, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return ids
    capture = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("pub const TechniqueID"):
            capture = True
            continue
        if capture:
            if stripped.startswith("};"):
                break
            if stripped.startswith("//") or not stripped:
                continue
            token = stripped.split("//")[0].strip().rstrip(",")
            if token:
                ids.add(token)
    return ids


def main() -> None:
    data = load_json()
    weapons_root = data.get("weapons", {})
    weapons = flatten_weapons(weapons_root)
    techniques_root = data.get("techniques", {})
    techniques_raw = flatten_techniques(techniques_root)
    cue_ids: Set[str] = set(entry.get("id", "") for entry in techniques_raw if entry.get("id"))
    existing_ids = load_existing_technique_ids()
    if existing_ids:
        missing = sorted(existing_ids - cue_ids)
        extra = sorted(cue_ids - existing_ids)
        if missing or extra:
            if missing:
                print("Missing techniques in CUE:", ", ".join(missing), file=sys.stderr)
            if extra:
                print("Unexpected techniques in CUE:", ", ".join(extra), file=sys.stderr)
            sys.exit(1)
    technique_ids: List[str] = sorted(cue_ids)
    output: List[str] = [
        "// AUTO-GENERATED BY scripts/cue_to_zig.py",
        "// DO NOT EDIT MANUALLY.",
        "",
        "const damage = @import(\"../domain/damage.zig\");",
        "const stats = @import(\"../domain/stats.zig\");",
        "const body = @import(\"../domain/body.zig\");",
        "",
    ]
    if technique_ids:
        output.append("pub const GeneratedTechniqueID = enum {")
        for tid in technique_ids:
            output.append(f"    {tid},")
        output.append("};")
        output.append("")
    techniques = techniques_raw
    if weapons:
        output.append(emit_weapons(weapons))
        output.append("")
    if techniques:
        output.append(emit_techniques(techniques))
    if not weapons and not techniques:
        output.append("// No weapons or techniques found in input JSON.")
    sys.stdout.write("\n".join(output))


if __name__ == "__main__":
    main()
