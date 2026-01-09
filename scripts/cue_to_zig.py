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


def zig_string_list(values: List[str]) -> str:
    if not values:
        return "&.{}"
    inner = ", ".join(f"\"{v}\"" for v in values)
    return f"&.{{ {inner} }}"


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


def emit_tissue_templates(templates: Dict[str, Any]) -> str:
    def material_field(layer: Dict[str, Any], key: str, field: str) -> float:
        material = layer.get("material", {})
        section = material.get(key, {})
        return float(section.get(field, 0.0))

    lines: List[str] = []
    lines.append("const TissueLayerDefinition = struct {")
    lines.append("    material_id: []const u8,")
    lines.append("    thickness_ratio: f32,")
    lines.append("    deflection: f32,")
    lines.append("    absorption: f32,")
    lines.append("    dispersion: f32,")
    lines.append("    geometry_threshold: f32,")
    lines.append("    geometry_ratio: f32,")
    lines.append("    momentum_threshold: f32,")
    lines.append("    momentum_ratio: f32,")
    lines.append("    rigidity_threshold: f32,")
    lines.append("    rigidity_ratio: f32,")
    lines.append("};")
    lines.append("")
    lines.append("pub const TissueTemplateDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    notes: []const u8 = \"\",")
    lines.append("    layers: []const TissueLayerDefinition,")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedTissueTemplates = [_]TissueTemplateDefinition{")
    for template_id, template in sorted(templates.items()):
        lines.append("    .{")
        lines.append(f'        .id = "{template_id}",')
        notes = template.get("notes", "")
        if notes:
            lines.append(f'        .notes = "{notes}",')
        layers = template.get("layers", [])
        lines.append("        .layers = &.{")
        for layer in layers:
            lines.append("            .{")
            lines.append(f'                .material_id = "{layer.get("material_id", "")}",')
            lines.append(f'                .thickness_ratio = {zig_float(layer.get("thickness_ratio", 0.0))},')
            lines.append(f'                .deflection = {zig_float(material_field(layer, "shielding", "deflection"))},')
            lines.append(f'                .absorption = {zig_float(material_field(layer, "shielding", "absorption"))},')
            lines.append(f'                .dispersion = {zig_float(material_field(layer, "shielding", "dispersion"))},')
            lines.append(f'                .geometry_threshold = {zig_float(material_field(layer, "susceptibility", "geometry_threshold"))},')
            lines.append(f'                .geometry_ratio = {zig_float(material_field(layer, "susceptibility", "geometry_ratio"))},')
            lines.append(f'                .momentum_threshold = {zig_float(material_field(layer, "susceptibility", "momentum_threshold"))},')
            lines.append(f'                .momentum_ratio = {zig_float(material_field(layer, "susceptibility", "momentum_ratio"))},')
            lines.append(f'                .rigidity_threshold = {zig_float(material_field(layer, "susceptibility", "rigidity_threshold"))},')
            lines.append(f'                .rigidity_ratio = {zig_float(material_field(layer, "susceptibility", "rigidity_ratio"))},')
            lines.append("            },")
        lines.append("        },")
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines)


def format_part_tag(tag: str) -> str:
    return f"body.PartTag.{tag}"


def format_side(side: str) -> str:
    mapping = {
        "left": "body.Side.left",
        "right": "body.Side.right",
        "center": "body.Side.center",
        "none": "body.Side.none",
    }
    return mapping.get(side, "body.Side.center")


def format_tissue_template(tpl: str) -> str:
    return f"body.TissueTemplate.{tpl}"


def format_part_flags(flags: Dict[str, Any]) -> str:
    if not flags:
        return ".{}"
    mapping = [
        ("vital", "vital"),
        ("internal", "internal"),
        ("grasp", "can_grasp"),
        ("stand", "can_stand"),
        ("see", "can_see"),
        ("hear", "can_hear"),
    ]
    entries = []
    for key, field in mapping:
        if flags.get(key, False):
            entries.append(f".{field} = true")
    if not entries:
        return ".{}"
    return ".{ " + ", ".join(entries) + " }"


def emit_body_plans(plans: Dict[str, Any]) -> str:
    lines: List[str] = []
    lines.append("const BodyPartGeometry = struct {")
    lines.append("    thickness_cm: f32,")
    lines.append("    length_cm: f32,")
    lines.append("    area_cm2: f32,")
    lines.append("};")
    lines.append("")
    lines.append("const BodyPartDefinition = struct {")
    lines.append("    name: []const u8,")
    lines.append("    tag: body.PartTag,")
    lines.append("    side: body.Side = body.Side.center,")
    lines.append("    tissue_template: body.TissueTemplate,")
    lines.append("    has_major_artery: bool = false,")
    lines.append("    flags: body.PartDef.Flags = .{},")
    lines.append("    geometry: BodyPartGeometry,")
    lines.append("};")
    lines.append("")
    lines.append("pub const BodyPlanDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    name: []const u8,")
    lines.append("    base_height_cm: f32,")
    lines.append("    base_mass_kg: f32,")
    lines.append("    parts: []const BodyPartDefinition,")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedBodyPlans = [_]BodyPlanDefinition{")
    for plan_id, plan in sorted(plans.items()):
        lines.append("    .{")
        lines.append(f'        .id = "{plan_id}",')
        lines.append(f'        .name = "{plan.get("name", plan_id)}",')
        lines.append(f'        .base_height_cm = {zig_float(plan.get("base_height_cm", 0.0))},')
        lines.append(f'        .base_mass_kg = {zig_float(plan.get("base_mass_kg", 0.0))},')
        parts = plan.get("parts", {})
        lines.append("        .parts = &.{")
        for part_name, part in sorted(parts.items()):
            lines.append("            .{")
            lines.append(f'                .name = "{part_name}",')
            lines.append(f"                .tag = {format_part_tag(part.get('tag', 'torso'))},")
            lines.append(f"                .side = {format_side(part.get('side', 'center'))},")
            lines.append(
                f"                .tissue_template = {format_tissue_template(part.get('tissue_template', 'limb'))},"
            )
            if part.get("has_major_artery"):
                lines.append("                .has_major_artery = true,")
            flags = format_part_flags(part.get("flags", {}))
            lines.append(f"                .flags = {flags},")
            geom = part.get("geometry", {})
            geom_line = (
                "                .geometry = .{ "
                + f".thickness_cm = {zig_float(geom.get('thickness_cm', 0.0))}, "
                + f".length_cm = {zig_float(geom.get('length_cm', 0.0))}, "
                + f".area_cm2 = {zig_float(geom.get('area_cm2', 0.0))} "
                + "},"
            )
            lines.append(geom_line)
            lines.append("            },")
        lines.append("        },")
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines)


def flatten_armour_materials(root: Dict[str, Any]) -> List[Tuple[str, Dict[str, Any]]]:
    """Extract armour materials from materials.armour."""
    armour_mats = root.get("materials", {}).get("armour", {})
    results: List[Tuple[str, Dict[str, Any]]] = []
    for key, value in armour_mats.items():
        if isinstance(value, dict) and "name" in value:
            results.append((key, value))
    return sorted(results, key=lambda x: x[0])


def flatten_armour_pieces(root: Dict[str, Any]) -> List[Tuple[str, Dict[str, Any]]]:
    """Extract armour pieces from armour_pieces."""
    pieces = root.get("armour_pieces", {})
    results: List[Tuple[str, Dict[str, Any]]] = []
    for key, value in pieces.items():
        if isinstance(value, dict) and "id" in value:
            results.append((value["id"], value))
    return sorted(results, key=lambda x: x[0])


def format_totality(totality: str) -> str:
    valid = {"total", "intimidating", "comprehensive", "frontal", "minimal"}
    if totality in valid:
        return f"armour.Totality.{totality}"
    return "armour.Totality.frontal"


def format_armour_layer(layer: str) -> str:
    # Maps CUE layer types to inventory.Layer equipment slots
    mapping = {
        "padding": "Gambeson",
        "outer": "Plate",
        "cloak": "Cloak",
    }
    return f"inventory.Layer.{mapping.get(layer, 'Plate')}"


def emit_armour_materials(materials: List[Tuple[str, Dict[str, Any]]]) -> str:
    lines: List[str] = []
    lines.append("pub const ArmourMaterialDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    name: []const u8,")
    lines.append("    deflection: f32,")
    lines.append("    absorption: f32,")
    lines.append("    dispersion: f32,")
    lines.append("    geometry_threshold: f32,")
    lines.append("    geometry_ratio: f32,")
    lines.append("    momentum_threshold: f32,")
    lines.append("    momentum_ratio: f32,")
    lines.append("    rigidity_threshold: f32,")
    lines.append("    rigidity_ratio: f32,")
    lines.append("    shape_profile: []const u8 = \"solid\",")
    lines.append("    shape_dispersion_bonus: f32 = 0,")
    lines.append("    shape_absorption_bonus: f32 = 0,")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedArmourMaterials = [_]ArmourMaterialDefinition{")
    for mat_id, data in materials:
        shielding = data.get("shielding", {})
        suscept = data.get("susceptibility", {})
        shape = data.get("shape", {})
        lines.append("    .{")
        lines.append(f'        .id = "{mat_id}",')
        lines.append(f'        .name = "{data.get("name", mat_id)}",')
        lines.append(f'        .deflection = {zig_float(shielding.get("deflection", 0.0))},')
        lines.append(f'        .absorption = {zig_float(shielding.get("absorption", 0.0))},')
        lines.append(f'        .dispersion = {zig_float(shielding.get("dispersion", 0.0))},')
        lines.append(f'        .geometry_threshold = {zig_float(suscept.get("geometry_threshold", 0.0))},')
        lines.append(f'        .geometry_ratio = {zig_float(suscept.get("geometry_ratio", 1.0))},')
        lines.append(f'        .momentum_threshold = {zig_float(suscept.get("momentum_threshold", 0.0))},')
        lines.append(f'        .momentum_ratio = {zig_float(suscept.get("momentum_ratio", 1.0))},')
        lines.append(f'        .rigidity_threshold = {zig_float(suscept.get("rigidity_threshold", 0.0))},')
        lines.append(f'        .rigidity_ratio = {zig_float(suscept.get("rigidity_ratio", 1.0))},')
        if shape:
            lines.append(f'        .shape_profile = "{shape.get("profile", "solid")}",')
            lines.append(f'        .shape_dispersion_bonus = {zig_float(shape.get("dispersion_bonus", 0.0))},')
            lines.append(f'        .shape_absorption_bonus = {zig_float(shape.get("absorption_bonus", 0.0))},')
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines)


def emit_armour_pieces(pieces: List[Tuple[str, Dict[str, Any]]]) -> str:
    lines: List[str] = []
    lines.append("pub const ArmourCoverageEntry = struct {")
    lines.append("    part_tags: []const body.PartTag,")
    lines.append("    side: body.Side = body.Side.center,")
    lines.append("    layer: inventory.Layer,")
    lines.append("    totality: armour.Totality,")
    lines.append("};")
    lines.append("")
    lines.append("pub const ArmourPieceDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    name: []const u8,")
    lines.append("    material_id: []const u8,")
    lines.append("    coverage: []const ArmourCoverageEntry,")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedArmourPieces = [_]ArmourPieceDefinition{")
    for piece_id, data in pieces:
        lines.append("    .{")
        lines.append(f'        .id = "{piece_id}",')
        lines.append(f'        .name = "{data.get("name", piece_id)}",')
        lines.append(f'        .material_id = "{data.get("material", "")}",')
        coverage = data.get("coverage", [])
        lines.append("        .coverage = &.{")
        for cov in coverage:
            part_tags = cov.get("part_tags", [])
            tags_str = ", ".join(f"body.PartTag.{t}" for t in part_tags)
            side = format_side(cov.get("side", "center"))
            layer = format_armour_layer(cov.get("layer", "outer"))
            totality = format_totality(cov.get("totality", "frontal"))
            lines.append("            .{")
            lines.append(f"                .part_tags = &.{{ {tags_str} }},")
            lines.append(f"                .side = {side},")
            lines.append(f"                .layer = {layer},")
            lines.append(f"                .totality = {totality},")
            lines.append("            },")
        lines.append("        },")
        lines.append("    },")
    lines.append("};")
    return "\n".join(lines)


def emit_species(species_map: Dict[str, Any]) -> str:
    lines: List[str] = []
    lines.append("pub const NaturalWeaponRef = struct {")
    lines.append("    weapon_id: []const u8,")
    lines.append("    required_part: body.PartTag,")
    lines.append("};")
    lines.append("")
    lines.append("pub const SpeciesDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    name: []const u8,")
    lines.append("    body_plan: []const u8,")
    lines.append("    base_blood: f32,")
    lines.append("    base_stamina: f32,")
    lines.append("    base_focus: f32,")
    lines.append("    stamina_recovery: ?f32 = null,")
    lines.append("    focus_recovery: ?f32 = null,")
    lines.append("    blood_recovery: ?f32 = null,")
    lines.append("    size_height: f32 = 1.0,")
    lines.append("    size_mass: f32 = 1.0,")
    lines.append("    tags: []const []const u8 = &.{},")
    lines.append("    natural_weapons: []const NaturalWeaponRef = &.{},")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedSpecies = [_]SpeciesDefinition{")
    for species_id, entry in sorted(species_map.items()):
        lines.append("    .{")
        lines.append(f'        .id = "{species_id}",')
        lines.append(f'        .name = "{entry.get("name", species_id)}",')
        lines.append(f'        .body_plan = "{entry.get("body_plan", "")}",')
        lines.append(f'        .base_blood = {zig_float(entry.get("base_blood", 0.0))},')
        lines.append(f'        .base_stamina = {zig_float(entry.get("base_stamina", 0.0))},')
        lines.append(f'        .base_focus = {zig_float(entry.get("base_focus", 0.0))},')
        if entry.get("stamina_recovery") is not None:
            lines.append(f'        .stamina_recovery = {zig_float(entry["stamina_recovery"])},')
        if entry.get("focus_recovery") is not None:
            lines.append(f'        .focus_recovery = {zig_float(entry["focus_recovery"])},')
        if entry.get("blood_recovery") is not None:
            lines.append(f'        .blood_recovery = {zig_float(entry["blood_recovery"])},')
        size = entry.get("size_modifiers", {})
        if size.get("height") is not None:
            lines.append(f'        .size_height = {zig_float(size["height"])},')
        if size.get("mass") is not None:
            lines.append(f'        .size_mass = {zig_float(size["mass"])},')
        tags = entry.get("tags", [])
        lines.append(f"        .tags = {zig_string_list(tags)},")
        naturals = entry.get("natural_weapons", [])
        lines.append("        .natural_weapons = &.{")
        for natural in naturals:
            part_expr = format_part_tag(natural.get("required_part", "hand"))
            lines.append(
                "            .{ "
                + f'.weapon_id = "{natural.get("weapon_id", "")}", '
                + f".required_part = {part_expr} "
                + "},"
            )
        lines.append("        },")
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
    armour_materials = flatten_armour_materials(data)
    armour_pieces = flatten_armour_pieces(data)
    output: List[str] = [
        "// AUTO-GENERATED BY scripts/cue_to_zig.py",
        "// DO NOT EDIT MANUALLY.",
        "",
        "const damage = @import(\"../domain/damage.zig\");",
        "const stats = @import(\"../domain/stats.zig\");",
        "const body = @import(\"../domain/body.zig\");",
        "const armour = @import(\"../domain/armour.zig\");",
        "const inventory = @import(\"../domain/inventory.zig\");",
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
        output.append("")
    tissue_templates = data.get("tissue_templates", {})
    if tissue_templates:
        output.append(emit_tissue_templates(tissue_templates))
        output.append("")
    body_plans_root = data.get("body_plans", {})
    if body_plans_root:
        output.append(emit_body_plans(body_plans_root))
        output.append("")
    species_root = data.get("species", {})
    if species_root:
        output.append(emit_species(species_root))
        output.append("")
    if armour_materials:
        output.append(emit_armour_materials(armour_materials))
        output.append("")
    if armour_pieces:
        output.append(emit_armour_pieces(armour_pieces))
    has_data = (
        weapons or techniques or tissue_templates or body_plans_root
        or species_root or armour_materials or armour_pieces
    )
    if not has_data:
        output.append("// No weapons, techniques, biological, or armour data found in input JSON.")
    sys.stdout.write("\n".join(output))


if __name__ == "__main__":
    main()
