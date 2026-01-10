# T045: Fix Audit Script for T044 Weapon Schema Changes
Created: 2026-01-10

## Problem statement / value driver
The audit script (`scripts/cue_to_zig.py --audit-report`) reports false positive warnings for all 12 weapons because it checks old field names that no longer exist after T044.

### Scope - goals
- Update weapon audit checks to match new CUE schema
- Regenerate audit report with accurate data

### Scope - non-goals
- Changing weapon data
- Technique axis_bias warnings (intentional defaults per T037)

## Background
T044 restructured `data/weapons.cue`:
- `length_m` → `length_cm`
- `derived.moment_of_inertia` → `moment_of_inertia` (top-level)
- Same for `effective_mass`, `reference_energy_j`, `geometry_coeff`, `rigidity_coeff`

The audit script still looks for the old field paths, resulting in 72 false warnings (6 per weapon × 12 weapons).

### Key files
- `scripts/cue_to_zig.py` - audit logic in `audit_weapons()` function
- `doc/artefacts/data_audit_report.md` - generated report

## Changes Required
1. Update `audit_weapons()` to check `length_cm` instead of `length_m`
2. Check top-level physics fields instead of `derived.*` subfields
3. Regenerate report with `just audit-data`

## Tasks / Sequence of Work
1. [x] Update field paths in `audit_weapons()`
2. [x] Regenerate audit report
3. [x] Verify 0 weapon warnings

## Test / Verification Strategy
- `just audit-data` produces report with 0 weapon warnings
- Physics values shown correctly in report fields

## Completion Notes
- Removed `phys = data.get("derived", {})` - physics fields now top-level
- Changed `length_m` → `length_cm` (2 occurrences)
- Changed all `phys.get(...)` → `data.get(...)` for physics fields
- Report now shows 14 warnings (all technique axis_bias, expected per T037)
- All 12 weapons show valid physics data in report table
