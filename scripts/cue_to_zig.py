#!/usr/bin/env python3
"""
Simple prototype converter that turns CUE-exported JSON into Zig data tables.

Usage:
    cue export data/materials.cue data/weapons.cue --out json | \
        ./scripts/cue_to_zig.py > src/gen/generated_data.zig
"""

import json
import sys
from typing import Any, Dict, List, Tuple


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
def emit_techniques(techniques: List[Dict[str, Any]]) -> str:
    lines: List[str] = []
    lines.append("const DamageInstance = struct {")
    lines.append("    amount: f32,")
    lines.append("    types: []const []const u8 = &.{},")
    lines.append("};")
    lines.append("")
    lines.append("const TechniqueDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    name: []const u8,")
    lines.append("    attack_mode: []const u8,")
    lines.append("    target_height: ?[]const u8 = null,")
    lines.append("    secondary_height: ?[]const u8 = null,")
    lines.append("    guard_height: ?[]const u8 = null,")
    lines.append("    deflect_mult: f32 = 1.0,")
    lines.append("    parry_mult: f32 = 1.0,")
    lines.append("    dodge_mult: f32 = 1.0,")
    lines.append("    counter_mult: f32 = 1.0,")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedTechniques = [_]TechniqueDefinition{")
    for entry in techniques:
        lines.append("    .{")
        lines.append(f'        .id = "{entry.get("id", "")}",')
        lines.append(f'        .name = "{entry.get("name", "")}",')
        lines.append(f'        .attack_mode = "{entry.get("attack_mode", "none")}",')
        for field in ("target_height", "secondary_height", "guard_height"):
            value = entry.get(field)
            if value:
                lines.append(f'        .{field} = "{value}",')
            else:
                lines.append(f"        .{field} = null,")
        lines.append(f'        .deflect_mult = {zig_float(entry.get("deflect_mult", 1.0))},')
        lines.append(f'        .parry_mult = {zig_float(entry.get("parry_mult", 1.0))},')
        lines.append(f'        .dodge_mult = {zig_float(entry.get("dodge_mult", 1.0))},')
        lines.append(f'        .counter_mult = {zig_float(entry.get("counter_mult", 1.0))},')
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines)


def main() -> None:
    data = load_json()
    weapons_root = data.get("weapons", {})
    weapons = flatten_weapons(weapons_root)
    techniques_root = data.get("techniques", {})
    techniques = flatten_techniques(techniques_root)
    output: List[str] = [
        "// AUTO-GENERATED BY scripts/cue_to_zig.py",
        "// DO NOT EDIT MANUALLY.",
        "",
    ]
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
