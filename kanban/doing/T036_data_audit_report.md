# T036: Data Audit Report Script

Created: 2026-01-10

## Problem statement / value driver

Phase 1 of the Geometry/Energy/Rigidity migration requires proof that every generated dataset is complete before touching resolution code. We have packet logs (audit_log.zig), wired bodies/armour/tissues, and CUE→Zig generation - but no automated validation that flags missing or inconsistent data.

### Scope - goals

- Extend `scripts/cue_to_zig.py` (or sibling script) to emit a human-readable audit report
- Validate all cross-references between datasets (technique→weapon, armour→material, tissue→material, etc.)
- Flag missing/zeroed required fields
- Wire into `just audit-data` target for CI integration

### Scope - non-goals

- Changing the CUE schemas (only reporting on them)
- Runtime coefficient tuning (audit surfaces gaps; balance is separate)
- Extending packet logging (already done in audit_log.zig)

## Background

### Relevant documents

- `doc/artefacts/geometry_momentum_rigidity_review.md` - §9.4 #4 defines audit requirements
- `doc/artefacts/data_generation_plan.md` - existing CUE→Zig pipeline

### Key files

- `scripts/cue_to_zig.py` - current generator, already has flatten_* functions
- `data/weapons.cue`, `data/techniques.cue` - weapon/technique definitions
- `data/armour.cue`, `data/materials.cue` - armour/material definitions
- `data/bodies.cue` - body plans, tissue templates, species

### Existing systems

- Generator already loads and flattens all CUE data via Python's JSON output
- `flatten_weapons()`, `flatten_techniques()`, `flatten_armour_materials()`, etc. provide structured access
- Comptime validation in `armour_list.zig`, `body_list.zig` catches some reference errors at compile time

## Report Scope

### Per-entry data to emit

| Dataset | Fields to Report | Warnings |
|---------|-----------------|----------|
| **Weapons** | moment_of_inertia, effective_mass, reference_energy, base_geometry, base_rigidity, curvature | Any derived field = 0, missing curvature |
| **Techniques** | damage instances, axis_bias multipliers, scaling, channels | Missing axis_bias, technique→weapon ID mismatch |
| **Armour materials** | deflection/absorption/dispersion, per-axis thresholds/ratios, shape modifiers | Coefficients sum > 1, threshold/ratio inconsistency |
| **Armour pieces** | coverage tags, layer, totality, material_id | References undefined material, empty coverage |
| **Tissue templates** | layers with material_id, thickness_ratio, shielding/susceptibility | Thickness ratios don't sum to ~1.0, undefined material |
| **Body plans** | part count, tissue_template references, geometry per part | Undefined tissue template, missing geometry |

### Validations

1. Every technique ID maps to a known weapon channel (cross-reference check)
2. axis_bias exists for all techniques (flag defaults)
3. Every material used by armour/tissue definitions exists in materials.cue
4. Thickness ratios in tissue templates sum to ~1.0 (warn if delta > 0.05)
5. Armour piece coverage is non-empty
6. Body plan parts reference only defined tissue templates

## Changes Required

### Option A: Extend cue_to_zig.py

Add `--audit-report` flag that:
1. Runs existing flatten_* functions
2. Walks each dataset, collecting stats and warnings
3. Emits Markdown report to `doc/artefacts/data_audit_report.md`
4. Returns non-zero exit code if any critical warnings

Pros: Reuses existing code, single source of truth
Cons: Mixes generation and reporting in one script

### Option B: Sibling script (cue_audit.py)

New script that:
1. Loads same CUE JSON
2. Uses validation-focused functions
3. Emits report only

Pros: Cleaner separation, can run without regenerating Zig
Cons: Duplicates some JSON loading/parsing

**Decision:** Option A - extend existing script. The flatten functions are stable, and a single script reduces drift risk.

## Tasks / Sequence of Work

### Phase 1: Report infrastructure

- [ ] **1.1** Add `--audit-report` CLI flag to cue_to_zig.py
- [ ] **1.2** Create `AuditReport` class to accumulate entries and warnings
- [ ] **1.3** Add `emit_audit_report(path)` function for Markdown output
- [ ] **1.4** Wire into main() to run after flattening, before Zig emission

### Phase 2: Dataset auditing

- [ ] **2.1** `audit_weapons()` - report derived fields, flag zeroes
- [ ] **2.2** `audit_techniques()` - report axis_bias, flag defaults
- [ ] **2.3** `audit_armour_materials()` - report coefficients, flag inconsistencies
- [ ] **2.4** `audit_armour_pieces()` - report coverage, validate material refs
- [ ] **2.5** `audit_tissue_templates()` - report layers, validate thickness sums
- [ ] **2.6** `audit_body_plans()` - report part count, validate tissue refs

### Phase 3: Cross-reference validation

- [ ] **3.1** Build ID sets from each dataset during flattening
- [ ] **3.2** Add cross-reference checks (technique→weapon, piece→material, etc.)
- [ ] **3.3** Report unresolved references as errors

### Phase 4: Just target & CI

- [ ] **4.1** Add `just audit-data` target in justfile
- [ ] **4.2** Make script exit non-zero on critical warnings
- [ ] **4.3** Commit initial report as `doc/artefacts/data_audit_report.md`

## Test / Verification Strategy

### Success criteria

- `just audit-data` generates report without errors
- Report covers all datasets with field breakdown
- Invalid cross-references are flagged and cause non-zero exit
- Report is human-readable Markdown suitable for design review

### Verification

- Manually introduce a bad material reference → script should error
- Manually zero out axis_bias → script should warn
- Compare report against manual inspection of CUE files

## Quality Concerns / Risks

- Report format may need iteration after first real use
- Threshold for "critical" vs "warning" needs tuning
- Thickness ratio tolerance (±0.05) may be too tight/loose

## Progress Log / Notes

**2026-01-10**: Task created from §9.4 #4 of geometry review doc.
