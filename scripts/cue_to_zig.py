#!/usr/bin/env python3
"""
Simple prototype converter that turns CUE-exported JSON into Zig data tables.

Usage:
    cue export data/materials.cue data/weapons.cue --out json | \
        ./scripts/cue_to_zig.py > src/gen/generated_data.zig

    # Generate audit report only:
    cue export data/*.cue --out json | \
        ./scripts/cue_to_zig.py --audit-report doc/artefacts/data_audit_report.md
"""

import argparse
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Dict, List, Tuple, Set, Optional

TECHNIQUE_ENUM_PATH = "src/domain/cards.zig"


@dataclass
class AuditEntry:
    """A single entry in the audit report."""
    dataset: str
    id: str
    fields: Dict[str, Any] = field(default_factory=dict)
    warnings: List[str] = field(default_factory=list)
    errors: List[str] = field(default_factory=list)


@dataclass
class AuditReport:
    """Accumulates audit entries and produces a report."""
    entries: List[AuditEntry] = field(default_factory=list)
    cross_ref_errors: List[str] = field(default_factory=list)
    summary: Dict[str, Dict[str, int]] = field(default_factory=dict)

    # ID sets for cross-reference validation
    weapon_ids: Set[str] = field(default_factory=set)
    technique_ids: Set[str] = field(default_factory=set)
    armour_material_ids: Set[str] = field(default_factory=set)
    armour_piece_ids: Set[str] = field(default_factory=set)
    tissue_template_ids: Set[str] = field(default_factory=set)
    tissue_material_ids: Set[str] = field(default_factory=set)
    body_plan_ids: Set[str] = field(default_factory=set)

    def add_entry(self, entry: AuditEntry) -> None:
        self.entries.append(entry)
        ds = entry.dataset
        if ds not in self.summary:
            self.summary[ds] = {"total": 0, "warnings": 0, "errors": 0}
        self.summary[ds]["total"] += 1
        if entry.warnings:
            self.summary[ds]["warnings"] += 1
        if entry.errors:
            self.summary[ds]["errors"] += 1

    def add_cross_ref_error(self, msg: str) -> None:
        self.cross_ref_errors.append(msg)

    def has_errors(self) -> bool:
        for entry in self.entries:
            if entry.errors:
                return True
        return bool(self.cross_ref_errors)

    def warning_count(self) -> int:
        return sum(1 for e in self.entries if e.warnings)

    def error_count(self) -> int:
        return sum(1 for e in self.entries if e.errors) + len(self.cross_ref_errors)

    def to_markdown(self) -> str:
        lines: List[str] = []
        lines.append("# Data Audit Report")
        lines.append("")
        lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append("")

        # Summary
        lines.append("## Summary")
        lines.append("")
        lines.append("| Dataset | Total | With Warnings | With Errors |")
        lines.append("|---------|-------|---------------|-------------|")
        for ds, counts in sorted(self.summary.items()):
            lines.append(f"| {ds} | {counts['total']} | {counts['warnings']} | {counts['errors']} |")
        lines.append("")

        total_warnings = self.warning_count()
        total_errors = self.error_count()
        if total_errors > 0:
            lines.append(f"**STATUS: FAILED** - {total_errors} error(s), {total_warnings} warning(s)")
        elif total_warnings > 0:
            lines.append(f"**STATUS: PASSED with warnings** - {total_warnings} warning(s)")
        else:
            lines.append("**STATUS: PASSED** - All validations passed")
        lines.append("")

        # Cross-reference errors
        if self.cross_ref_errors:
            lines.append("## Cross-Reference Errors")
            lines.append("")
            for err in self.cross_ref_errors:
                lines.append(f"- {err}")
            lines.append("")

        # Per-dataset details
        datasets_order = [
            "weapons", "techniques", "armour_materials",
            "armour_pieces", "tissue_templates", "body_plans"
        ]
        for ds in datasets_order:
            ds_entries = [e for e in self.entries if e.dataset == ds]
            if not ds_entries:
                continue

            lines.append(f"## {ds.replace('_', ' ').title()}")
            lines.append("")

            # Entries with issues first
            issues = [e for e in ds_entries if e.warnings or e.errors]
            clean = [e for e in ds_entries if not e.warnings and not e.errors]

            if issues:
                lines.append("### Issues")
                lines.append("")
                for entry in issues:
                    lines.append(f"#### `{entry.id}`")
                    lines.append("")
                    if entry.errors:
                        for err in entry.errors:
                            lines.append(f"- **ERROR**: {err}")
                    if entry.warnings:
                        for warn in entry.warnings:
                            lines.append(f"- WARNING: {warn}")
                    lines.append("")
                    # Show relevant fields
                    if entry.fields:
                        lines.append("Fields:")
                        lines.append("```")
                        for k, v in entry.fields.items():
                            lines.append(f"  {k}: {v}")
                        lines.append("```")
                        lines.append("")

            # Summary table for clean entries
            if clean:
                lines.append("### Valid Entries")
                lines.append("")
                lines.append(self._format_dataset_table(ds, clean))
                lines.append("")

        return "\n".join(lines)

    def _format_dataset_table(self, dataset: str, entries: List[AuditEntry]) -> str:
        """Format a summary table for valid entries."""
        if not entries:
            return "_None_"

        lines: List[str] = []
        if dataset == "weapons":
            lines.append("| ID | MoI | Eff.Mass | RefEnergy | Geometry | Rigidity |")
            lines.append("|----|-----|----------|-----------|----------|----------|")
            for e in entries:
                f = e.fields
                lines.append(f"| {e.id} | {f.get('moment_of_inertia', 0):.3f} | {f.get('effective_mass', 0):.2f} | {f.get('reference_energy_j', 0):.1f} | {f.get('geometry_coeff', 0):.2f} | {f.get('rigidity_coeff', 0):.2f} |")
        elif dataset == "techniques":
            lines.append("| ID | Mode | Geo | Energy | Rigid | Channels |")
            lines.append("|----|------|-----|--------|-------|----------|")
            for e in entries:
                f = e.fields
                ch = f.get('channels', {})
                ch_str = ",".join(k for k, v in ch.items() if v)
                lines.append(f"| {e.id} | {f.get('attack_mode', '-')} | {f.get('axis_geometry_mult', 1):.2f} | {f.get('axis_energy_mult', 1):.2f} | {f.get('axis_rigidity_mult', 1):.2f} | {ch_str or '-'} |")
        elif dataset == "armour_materials":
            lines.append("| ID | Defl | Abs | Disp | GeoThr | EnerThr | RigThr |")
            lines.append("|----|------|-----|------|--------|---------|--------|")
            for e in entries:
                f = e.fields
                lines.append(f"| {e.id} | {f.get('deflection', 0):.2f} | {f.get('absorption', 0):.2f} | {f.get('dispersion', 0):.2f} | {f.get('geometry_threshold', 0):.1f} | {f.get('energy_threshold', 0):.1f} | {f.get('rigidity_threshold', 0):.1f} |")
        elif dataset == "armour_pieces":
            lines.append("| ID | Material | Coverage Count |")
            lines.append("|----|----------|----------------|")
            for e in entries:
                f = e.fields
                lines.append(f"| {e.id} | {f.get('material_id', '-')} | {f.get('coverage_count', 0)} |")
        elif dataset == "tissue_templates":
            lines.append("| ID | Layers | Thickness Sum |")
            lines.append("|----|--------|---------------|")
            for e in entries:
                f = e.fields
                lines.append(f"| {e.id} | {f.get('layer_count', 0)} | {f.get('thickness_sum', 0):.3f} |")
        elif dataset == "body_plans":
            lines.append("| ID | Parts | Height | Mass |")
            lines.append("|----|-------|--------|------|")
            for e in entries:
                f = e.fields
                lines.append(f"| {e.id} | {f.get('part_count', 0)} | {f.get('base_height_cm', 0):.0f}cm | {f.get('base_mass_kg', 0):.1f}kg |")
        else:
            lines.append(f"_{len(entries)} entries_")

        return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert CUE-exported JSON to Zig data tables, with optional audit report."
    )
    parser.add_argument(
        "input_file",
        nargs="?",
        help="JSON input file (reads from stdin if not provided)"
    )
    parser.add_argument(
        "--audit-report",
        metavar="PATH",
        help="Generate audit report to specified path (skips Zig generation)"
    )
    parser.add_argument(
        "--audit-only",
        action="store_true",
        help="Only run audit, don't generate Zig (report goes to stdout if --audit-report not set)"
    )
    return parser.parse_args()


def load_json(args: argparse.Namespace) -> Dict[str, Any]:
    if args.input_file:
        with open(args.input_file, "r", encoding="utf-8") as f:
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
    lines.append("pub const TissueLayerDefinition = struct {")
    lines.append("    material_id: []const u8,")
    lines.append("    thickness_ratio: f32,")
    lines.append("    deflection: f32,")
    lines.append("    absorption: f32,")
    lines.append("    dispersion: f32,")
    lines.append("    geometry_threshold: f32,")
    lines.append("    geometry_ratio: f32,")
    lines.append("    energy_threshold: f32,")
    lines.append("    energy_ratio: f32,")
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
            lines.append(f'                .energy_threshold = {zig_float(material_field(layer, "susceptibility", "energy_threshold"))},')
            lines.append(f'                .energy_ratio = {zig_float(material_field(layer, "susceptibility", "energy_ratio"))},')
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


def format_tissue_template_string(tpl: str) -> str:
    """Return tissue template as string ID for lookup in generated tables."""
    return f'"{tpl}"'


def format_optional_string(value: str | None) -> str:
    """Format an optional string field for Zig."""
    if value is None:
        return "null"
    return f'"{value}"'


def format_part_flags(flags: Dict[str, Any]) -> str:
    if not flags:
        return ".{}"
    mapping = [
        ("vital", "is_vital"),
        ("internal", "is_internal"),
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


def topological_sort_parts(parts: Dict[str, Any]) -> List[tuple]:
    """Sort body parts so parents come before children."""
    # Build adjacency: child -> parent
    result = []
    remaining = set(parts.keys())

    while remaining:
        # Find parts whose parent is already emitted (or has no parent)
        ready = []
        for name in remaining:
            parent = parts[name].get("parent")
            if parent is None or parent not in remaining:
                ready.append(name)

        if not ready:
            # Cycle or missing parent - fall back to alphabetical for remaining
            ready = sorted(remaining)

        # Add ready parts in alphabetical order for determinism
        for name in sorted(ready):
            result.append((name, parts[name]))
            remaining.discard(name)

    return result


def emit_body_plans(plans: Dict[str, Any]) -> str:
    lines: List[str] = []
    lines.append("pub const BodyPartGeometry = struct {")
    lines.append("    thickness_cm: f32,")
    lines.append("    length_cm: f32,")
    lines.append("    area_cm2: f32,")
    lines.append("};")
    lines.append("")
    lines.append("pub const BodyPartDefinition = struct {")
    lines.append("    name: []const u8,")
    lines.append("    tag: body.PartTag,")
    lines.append("    side: body.Side = body.Side.center,")
    lines.append("    parent: ?[]const u8 = null,")
    lines.append("    enclosing: ?[]const u8 = null,")
    lines.append("    tissue_template_id: []const u8,")
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
        for part_name, part in topological_sort_parts(parts):
            lines.append("            .{")
            lines.append(f'                .name = "{part_name}",')
            lines.append(f"                .tag = {format_part_tag(part.get('tag', 'torso'))},")
            lines.append(f"                .side = {format_side(part.get('side', 'center'))},")
            parent = part.get("parent")
            if parent is not None:
                lines.append(f'                .parent = "{parent}",')
            enclosing = part.get("enclosing")
            if enclosing is not None:
                lines.append(f'                .enclosing = "{enclosing}",')
            lines.append(
                f"                .tissue_template_id = {format_tissue_template_string(part.get('tissue_template', 'limb'))},"
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
    lines.append("    energy_threshold: f32,")
    lines.append("    energy_ratio: f32,")
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
        lines.append(f'        .energy_threshold = {zig_float(suscept.get("energy_threshold", 0.0))},')
        lines.append(f'        .energy_ratio = {zig_float(suscept.get("energy_ratio", 1.0))},')
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


def flatten_combat_tests(root: Dict[str, Any]) -> List[Tuple[str, Dict[str, Any]]]:
    """Extract combat tests from combat_tests."""
    tests = root.get("combat_tests", {})
    results: List[Tuple[str, Dict[str, Any]]] = []
    for key, value in tests.items():
        if isinstance(value, dict) and "id" in value:
            results.append((value["id"], value))
    return sorted(results, key=lambda x: x[0])


def format_optional_float(value: Any) -> str:
    """Format an optional float field for Zig."""
    if value is None:
        return "null"
    return zig_float(value)


def format_optional_bool(value: Any) -> str:
    """Format an optional bool field for Zig."""
    if value is None:
        return "null"
    return zig_bool(value)


def format_optional_int(value: Any) -> str:
    """Format an optional int field for Zig."""
    if value is None:
        return "null"
    return str(int(value))


def emit_combat_tests(tests: List[Tuple[str, Dict[str, Any]]]) -> str:
    lines: List[str] = []
    lines.append("pub const AttackerSpec = struct {")
    lines.append("    species: []const u8 = \"dwarf\",")
    lines.append("    weapon_id: []const u8,")
    lines.append("    technique_id: []const u8,")
    lines.append("    stakes: []const u8 = \"committed\",")
    lines.append("    power: ?f32 = null,")
    lines.append("    speed: ?f32 = null,")
    lines.append("    skill: ?f32 = null,")
    lines.append("};")
    lines.append("")
    lines.append("pub const DefenderSpec = struct {")
    lines.append("    species: []const u8 = \"dwarf\",")
    lines.append("    armour_ids: []const []const u8 = &.{},")
    lines.append("    pose: []const u8 = \"balanced\",")
    lines.append("    target_part: []const u8 = \"torso\",")
    lines.append("};")
    lines.append("")
    lines.append("pub const ExpectedOutcome = struct {")
    lines.append("    outcome: ?[]const u8 = null,")
    lines.append("    damage_dealt_min: ?f32 = null,")
    lines.append("    damage_dealt_max: ?f32 = null,")
    lines.append("    packet_energy_min: ?f32 = null,")
    lines.append("    packet_geometry_min: ?f32 = null,")
    lines.append("    armour_deflected: ?bool = null,")
    lines.append("    penetrated_layers_min: ?u8 = null,")
    lines.append("    penetrated_layers_max: ?u8 = null,")
    lines.append("};")
    lines.append("")
    lines.append("pub const CombatTestDefinition = struct {")
    lines.append("    id: []const u8,")
    lines.append("    description: []const u8,")
    lines.append("    attacker: AttackerSpec,")
    lines.append("    defender: DefenderSpec,")
    lines.append("    expected: ExpectedOutcome,")
    lines.append("};")
    lines.append("")
    lines.append("pub const GeneratedCombatTests = [_]CombatTestDefinition{")
    for test_id, data in tests:
        attacker = data.get("attacker", {})
        defender = data.get("defender", {})
        expected = data.get("expected", {})
        attacker_stats = attacker.get("stats", {})
        armour_ids = defender.get("armour_ids", [])
        armour_str = ", ".join(f'"{aid}"' for aid in armour_ids)

        lines.append("    .{")
        lines.append(f'        .id = "{test_id}",')
        lines.append(f'        .description = "{data.get("description", "")}",')
        lines.append("        .attacker = .{")
        lines.append(f'            .species = "{attacker.get("species", "dwarf")}",')
        lines.append(f'            .weapon_id = "{attacker.get("weapon_id", "")}",')
        lines.append(f'            .technique_id = "{attacker.get("technique_id", "")}",')
        lines.append(f'            .stakes = "{attacker.get("stakes", "committed")}",')
        if attacker_stats.get("power") is not None:
            lines.append(f'            .power = {zig_float(attacker_stats["power"])},')
        if attacker_stats.get("speed") is not None:
            lines.append(f'            .speed = {zig_float(attacker_stats["speed"])},')
        if attacker_stats.get("skill") is not None:
            lines.append(f'            .skill = {zig_float(attacker_stats["skill"])},')
        lines.append("        },")
        lines.append("        .defender = .{")
        lines.append(f'            .species = "{defender.get("species", "dwarf")}",')
        lines.append(f"            .armour_ids = &.{{ {armour_str} }},")
        lines.append(f'            .pose = "{defender.get("pose", "balanced")}",')
        lines.append(f'            .target_part = "{defender.get("target_part", "torso")}",')
        lines.append("        },")
        lines.append("        .expected = .{")
        if expected.get("outcome") is not None:
            lines.append(f'            .outcome = "{expected["outcome"]}",')
        if expected.get("damage_dealt_min") is not None:
            lines.append(f'            .damage_dealt_min = {zig_float(expected["damage_dealt_min"])},')
        if expected.get("damage_dealt_max") is not None:
            lines.append(f'            .damage_dealt_max = {zig_float(expected["damage_dealt_max"])},')
        if expected.get("packet_energy_min") is not None:
            lines.append(f'            .packet_energy_min = {zig_float(expected["packet_energy_min"])},')
        if expected.get("packet_geometry_min") is not None:
            lines.append(f'            .packet_geometry_min = {zig_float(expected["packet_geometry_min"])},')
        if expected.get("armour_deflected") is not None:
            lines.append(f'            .armour_deflected = {zig_bool(expected["armour_deflected"])},')
        if expected.get("penetrated_layers_min") is not None:
            lines.append(f'            .penetrated_layers_min = {int(expected["penetrated_layers_min"])},')
        if expected.get("penetrated_layers_max") is not None:
            lines.append(f'            .penetrated_layers_max = {int(expected["penetrated_layers_max"])},')
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


# =============================================================================
# Audit Functions
# =============================================================================


def audit_weapons(
    weapons: List[Tuple[str, Dict[str, Any]]], report: AuditReport
) -> None:
    """Audit weapon definitions for missing/zero derived fields."""
    for weapon_id, data in weapons:
        report.weapon_ids.add(weapon_id)
        phys = data.get("derived", {})

        entry = AuditEntry(
            dataset="weapons",
            id=weapon_id,
            fields={
                "name": data.get("name", ""),
                "weight_kg": data.get("weight_kg", 0),
                "length_m": data.get("length_m", 0),
                "balance": data.get("balance", 0),
                "moment_of_inertia": phys.get("moment_of_inertia", 0),
                "effective_mass": phys.get("effective_mass", 0),
                "reference_energy_j": phys.get("reference_energy_j", 0),
                "geometry_coeff": phys.get("geometry_coeff", 0),
                "rigidity_coeff": phys.get("rigidity_coeff", 0),
            },
        )

        # Check for zero derived fields
        if phys.get("moment_of_inertia", 0) == 0:
            entry.warnings.append("moment_of_inertia is 0")
        if phys.get("effective_mass", 0) == 0:
            entry.warnings.append("effective_mass is 0")
        if phys.get("reference_energy_j", 0) == 0:
            entry.warnings.append("reference_energy_j is 0")
        if phys.get("geometry_coeff", 0) == 0:
            entry.warnings.append("geometry_coeff is 0")
        if phys.get("rigidity_coeff", 0) == 0:
            entry.warnings.append("rigidity_coeff is 0")

        # Check for missing base data
        if data.get("weight_kg", 0) == 0:
            entry.warnings.append("weight_kg is 0 (base data)")
        if data.get("length_m", 0) == 0:
            entry.warnings.append("length_m is 0 (base data)")

        report.add_entry(entry)


def audit_techniques(
    techniques: List[Dict[str, Any]], report: AuditReport
) -> None:
    """Audit technique definitions for axis_bias and channel validity."""
    for tech in techniques:
        tech_id = tech.get("id", "")
        report.technique_ids.add(tech_id)

        axis = tech.get("axis_bias", {})
        channels = tech.get("channels", {})

        entry = AuditEntry(
            dataset="techniques",
            id=tech_id,
            fields={
                "name": tech.get("name", ""),
                "attack_mode": tech.get("attack_mode", "none"),
                "axis_geometry_mult": axis.get("geometry_mult", 1.0),
                "axis_energy_mult": axis.get("energy_mult", 1.0),
                "axis_rigidity_mult": axis.get("rigidity_mult", 1.0),
                "channels": channels,
            },
        )

        # Check if axis_bias is explicitly defined or using defaults
        if not axis:
            entry.warnings.append("axis_bias not defined (using defaults)")
        else:
            # Check if all three axes are explicitly set
            if "geometry_mult" not in axis:
                entry.warnings.append("axis_bias.geometry_mult not set (default 1.0)")
            if "energy_mult" not in axis:
                entry.warnings.append("axis_bias.energy_mult not set (default 1.0)")
            if "rigidity_mult" not in axis:
                entry.warnings.append("axis_bias.rigidity_mult not set (default 1.0)")

        # Check channels - at least one should be true for combat techniques
        attack_mode = tech.get("attack_mode", "none")
        if attack_mode != "none":
            has_channel = any(channels.values())
            if not has_channel:
                entry.warnings.append("No channels defined for combat technique")

        report.add_entry(entry)


def audit_armour_materials(
    materials: List[Tuple[str, Dict[str, Any]]], report: AuditReport
) -> None:
    """Audit armour materials for coefficient consistency."""
    for mat_id, data in materials:
        report.armour_material_ids.add(mat_id)

        shielding = data.get("shielding", {})
        suscept = data.get("susceptibility", {})

        deflection = shielding.get("deflection", 0)
        absorption = shielding.get("absorption", 0)
        dispersion = shielding.get("dispersion", 0)

        entry = AuditEntry(
            dataset="armour_materials",
            id=mat_id,
            fields={
                "name": data.get("name", ""),
                "deflection": deflection,
                "absorption": absorption,
                "dispersion": dispersion,
                "geometry_threshold": suscept.get("geometry_threshold", 0),
                "geometry_ratio": suscept.get("geometry_ratio", 1),
                "energy_threshold": suscept.get("energy_threshold", 0),
                "energy_ratio": suscept.get("energy_ratio", 1),
                "rigidity_threshold": suscept.get("rigidity_threshold", 0),
                "rigidity_ratio": suscept.get("rigidity_ratio", 1),
            },
        )

        # Check for suspicious coefficient values
        shield_sum = deflection + absorption + dispersion
        if shield_sum > 1.5:
            entry.warnings.append(
                f"Shielding coefficients sum to {shield_sum:.2f} (deflection+absorption+dispersion > 1.5)"
            )

        # Check for zero thresholds with non-zero ratios (may be intentional)
        for axis in ["geometry", "energy", "rigidity"]:
            thr = suscept.get(f"{axis}_threshold", 0)
            ratio = suscept.get(f"{axis}_ratio", 1)
            if thr == 0 and ratio < 1:
                entry.warnings.append(
                    f"{axis}_threshold=0 with {axis}_ratio={ratio:.2f} means all damage is reduced"
                )

        report.add_entry(entry)


def audit_armour_pieces(
    pieces: List[Tuple[str, Dict[str, Any]]], report: AuditReport
) -> None:
    """Audit armour pieces for coverage and material references."""
    for piece_id, data in pieces:
        report.armour_piece_ids.add(piece_id)

        material_id = data.get("material", "")
        coverage = data.get("coverage", [])

        entry = AuditEntry(
            dataset="armour_pieces",
            id=piece_id,
            fields={
                "name": data.get("name", ""),
                "material_id": material_id,
                "coverage_count": len(coverage),
            },
        )

        # Check material reference
        if not material_id:
            entry.errors.append("No material specified")

        # Check coverage
        if not coverage:
            entry.errors.append("No coverage entries defined")
        else:
            for i, cov in enumerate(coverage):
                tags = cov.get("part_tags", [])
                if not tags:
                    entry.warnings.append(f"Coverage entry {i} has no part_tags")

        report.add_entry(entry)


def audit_tissue_templates(
    templates: Dict[str, Any], report: AuditReport
) -> None:
    """Audit tissue templates for layer completeness and thickness sums."""
    for tpl_id, tpl in templates.items():
        report.tissue_template_ids.add(tpl_id)

        layers = tpl.get("layers", [])
        thickness_sum = sum(layer.get("thickness_ratio", 0) for layer in layers)

        entry = AuditEntry(
            dataset="tissue_templates",
            id=tpl_id,
            fields={
                "notes": tpl.get("notes", ""),
                "layer_count": len(layers),
                "thickness_sum": thickness_sum,
                "materials": [layer.get("material_id", "") for layer in layers],
            },
        )

        # Collect material IDs
        for layer in layers:
            mat_id = layer.get("material_id", "")
            if mat_id:
                report.tissue_material_ids.add(mat_id)

        # Check thickness sum
        if abs(thickness_sum - 1.0) > 0.05:
            entry.warnings.append(
                f"Thickness ratios sum to {thickness_sum:.3f} (expected ~1.0, tolerance ±0.05)"
            )

        # Check for empty layers
        if not layers:
            entry.errors.append("No layers defined")

        # Check each layer has a material
        for i, layer in enumerate(layers):
            if not layer.get("material_id"):
                entry.errors.append(f"Layer {i} has no material_id")

        report.add_entry(entry)


def audit_body_plans(
    plans: Dict[str, Any],
    report: AuditReport,
) -> None:
    """Audit body plans for tissue template references and geometry."""
    for plan_id, plan in plans.items():
        report.body_plan_ids.add(plan_id)

        parts = plan.get("parts", {})

        entry = AuditEntry(
            dataset="body_plans",
            id=plan_id,
            fields={
                "name": plan.get("name", ""),
                "base_height_cm": plan.get("base_height_cm", 0),
                "base_mass_kg": plan.get("base_mass_kg", 0),
                "part_count": len(parts),
            },
        )

        # Check each part
        missing_geometry = []
        missing_tissue = []
        tissue_refs: Set[str] = set()

        for part_name, part in parts.items():
            tissue_tpl = part.get("tissue_template", "")
            if tissue_tpl:
                tissue_refs.add(tissue_tpl)
            else:
                missing_tissue.append(part_name)

            geom = part.get("geometry", {})
            if not geom or geom.get("thickness_cm", 0) == 0:
                missing_geometry.append(part_name)

        if missing_tissue:
            entry.errors.append(
                f"Parts missing tissue_template: {', '.join(missing_tissue[:5])}"
                + (f" (+{len(missing_tissue)-5} more)" if len(missing_tissue) > 5 else "")
            )

        if missing_geometry:
            entry.warnings.append(
                f"Parts with zero/missing geometry: {', '.join(missing_geometry[:5])}"
                + (f" (+{len(missing_geometry)-5} more)" if len(missing_geometry) > 5 else "")
            )

        entry.fields["tissue_templates_used"] = list(tissue_refs)

        report.add_entry(entry)


def validate_cross_references(report: AuditReport) -> None:
    """Check cross-references between datasets."""
    # Armour pieces -> materials
    for entry in report.entries:
        if entry.dataset == "armour_pieces":
            mat_id = entry.fields.get("material_id", "")
            if mat_id and mat_id not in report.armour_material_ids:
                report.add_cross_ref_error(
                    f"Armour piece '{entry.id}' references unknown material '{mat_id}'"
                )

    # Body plans -> tissue templates
    for entry in report.entries:
        if entry.dataset == "body_plans":
            for tpl_id in entry.fields.get("tissue_templates_used", []):
                if tpl_id not in report.tissue_template_ids:
                    report.add_cross_ref_error(
                        f"Body plan '{entry.id}' references unknown tissue template '{tpl_id}'"
                    )

    # Future: techniques -> weapons (when technique defines weapon requirements)


def run_audit(data: Dict[str, Any]) -> AuditReport:
    """Run full audit on loaded CUE data."""
    report = AuditReport()

    # Flatten data
    weapons = flatten_weapons(data.get("weapons", {}))
    techniques = flatten_techniques(data.get("techniques", {}))
    armour_materials = flatten_armour_materials(data)
    armour_pieces = flatten_armour_pieces(data)
    tissue_templates = data.get("tissue_templates", {})
    body_plans = data.get("body_plans", {})

    # Run audits
    audit_weapons(weapons, report)
    audit_techniques(techniques, report)
    audit_armour_materials(armour_materials, report)
    audit_armour_pieces(armour_pieces, report)
    audit_tissue_templates(tissue_templates, report)
    audit_body_plans(body_plans, report)

    # Cross-reference validation
    validate_cross_references(report)

    return report


# =============================================================================
# Main
# =============================================================================


def generate_zig(data: Dict[str, Any]) -> str:
    """Generate Zig code from CUE data."""
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
        output.append("")
    combat_tests = flatten_combat_tests(data)
    if combat_tests:
        output.append(emit_combat_tests(combat_tests))
    has_data = (
        weapons or techniques or tissue_templates or body_plans_root
        or species_root or armour_materials or armour_pieces or combat_tests
    )
    if not has_data:
        output.append("// No weapons, techniques, biological, armour, or test data found in input JSON.")
    return "\n".join(output)


def main() -> None:
    args = parse_args()
    data = load_json(args)

    # Audit mode
    if args.audit_report or args.audit_only:
        report = run_audit(data)
        markdown = report.to_markdown()

        if args.audit_report:
            with open(args.audit_report, "w", encoding="utf-8") as f:
                f.write(markdown)
                f.write("\n")
            print(f"Audit report written to: {args.audit_report}", file=sys.stderr)
        else:
            print(markdown)

        # Exit with error code if there are errors
        if report.has_errors():
            print(
                f"Audit failed: {report.error_count()} error(s), {report.warning_count()} warning(s)",
                file=sys.stderr
            )
            sys.exit(1)
        elif report.warning_count() > 0:
            print(
                f"Audit passed with {report.warning_count()} warning(s)",
                file=sys.stderr
            )
        else:
            print("Audit passed: all validations succeeded", file=sys.stderr)

        # If audit-only, don't generate Zig
        if args.audit_only or args.audit_report:
            return

    # Generate Zig code
    zig_code = generate_zig(data)
    sys.stdout.write(zig_code)


if __name__ == "__main__":
    main()
