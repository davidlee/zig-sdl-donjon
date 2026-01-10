# Geometry / Energy / Rigidity – Conceptual Review

**Related:** `doc/issues/impulse_penetration_bite.md`, `doc/issues/combat_modifiers_redesign.md`, `doc/artefacts/damage_lethality_analysis.md`

This note maps the current combat pipeline to the proposed three-axis “physics” model, raises naming and conceptual concerns, and outlines the additional design work required before rewriting armour, weapon, and body interactions.

---

## 1. Purpose & Scope

- Capture what the present systems already express (and where they fall short) so we do not duplicate existing concepts under new labels.
- Stress-test the Geometry/Energy/Rigidity framing against diverse scenarios (weapons, grips, physiologies, non-physical damage).
- Surface naming/terminology questions before hard-coding them into data schemas.
- Lay out a *plan for the plan*: concrete research/design checkpoints needed before touching code.

---

## 2. Present-State Snapshot

| System | Current Data | Observations |
| --- | --- | --- |
| Damage packet creation | `createDamagePacket()` sums technique instances, multiplies by a stat ratio, weapon `.damage`, and stakes, then assigns a single `damage.Kind` and `penetration` value (`src/domain/resolution/damage.zig:34-86`). | Only two scalar outputs survive: `amount` and `penetration`. Weapon reach/weight/balance never appear in this function even though `weapon.Template` stores them. |
| Armour | `armour.LayerProtection` holds material, coverage totality, and integrity pointer; resolution iterates outer→inner, running gap, hardness, threshold, and ratio checks per layer (`src/domain/armour.zig:164-328`). | Materials already expose `thickness`, `hardness`, `flexibility`, resistances, and vulnerabilities (`src/domain/armour.zig:36-52`, `487-520`). These are single-value scalars per damage type, so armour cannot yet respond to multiple orthogonal axes. |
| Tissue layers | Biological layers are enumerated, but their behaviour is defined by per-damage-kind absorption fractions (`src/domain/body.zig:146-176`, `759-807`). | Tissue absorbs a percentage of the current packet and reduces `penetration`, echoing armour but with hard-coded tables per `damage.Kind`. |
| Body/species scaling | Species choose a `body_plan` (e.g. `HumanoidPlan`) and set base blood/stamina/focus (`src/domain/species.zig:182-207`, `src/domain/combat/agent.zig:98-154`). | Plans do not encode explicit dimensions or thickness per part; they rely on templates and per-part `base_durability`/`trauma_mult`. |

**Takeaway:** We already march through a stack of layers (armour → tissue) reducing `amount` and `penetration`, but the math is specialised for blunt/pierce/slash. Extending to three axes means generalising the per-layer logic rather than bolting on more ad-hoc scalars.

---

## 3. Axis Candidates & Naming

Based on the latest discussion, we can align the physics-centric terminology with player-facing names as follows:

| Internal Term | Player-Facing Weapon Stat | Physical Meaning | Notes / Devil’s Advocate |
| --- | --- | --- | --- |
| **Geometry** | **Penetration** | How well the impact maintains stress along a narrow contact and continues cutting/piercing deeper (shear efficiency + supported edge geometry). | Replaces the ambiguous “penetration cm” scalar with a dimensionless coefficient that can still be multiplied by path length when converting to `damage.Packet.penetration`. Mixed weapons need clear rules for allocating energy between Geometry and Rigidity. |
| **Energy (Joules)** | **Impact** | Total mechanical energy available from swing or thrust after accounting for weapon mass distribution, grip, and attacker stats. | Provides a principled joule value (½ Iω² or ½ m v²) that can feed trauma/pain systems. When an actual momentum/impulse figure is required (kg·m/s), derive it from the same mass/velocity inputs so terminology stays consistent. |
| **Rigidity** | **Hardness** | Ability of the striking surface to remain structurally supported, concentrating force instead of deforming. Governs whether Impact fractures bone or diffuses as bruising. | “Rigidity” is descriptive internally, while “Hardness” reads better in UI. Must handle negative cases (saps, padded weapons) that intentionally *lack* rigidity. |

Defensive layers would counter these axes via:

| Defensive Behaviour | Player-Facing Resistance | Description |
| --- | --- | --- |
| Geometry resistance | **Deflection** | Tendency to redirect or blunt penetrating edges/spikes before they enter the layer (driven by shape, polish, hardness). |
| Energy resistance | **Absorption** | Capacity to soak Impact energy into the layer’s own structure (padding, yielding materials) rather than passing it inward. |
| Rigidity response | **Dispersion** | Ability to spread residual force across a larger area before it reaches deeper layers. This is *not* self-resistance: very rigid materials (plate) may score low here, meaning they transmit hammer blows even though they themselves remain intact. |

> **Important:** Dispersion only describes how well a layer protects what lies beneath it. A breastplate can have high Geometry resistance (great at deflection) yet poor Dispersion, so hammer blows still rattle the ribs even though the plate itself suffers no damage. That distinction needs to be preserved in tooling and documentation to avoid designers mistakenly “maxing Dispersion” whenever a material is durable.

Energy is the scalar quantity we track internally; when designers or logs need momentum/impulse, convert the same underlying mass/velocity inputs into kg·m/s. This keeps the axis definition clean (energy drives trauma budgets) while still letting us expose momentum-style numbers when narratively useful.

**Recommendation:** Treat Geometry, Energy, and Rigidity as independent internal axes, with Penetration/Impact/Hardness surfacing to players on weapon stats, and Deflection/Absorption/Dispersion doing the same for armour/body layers. This clear mapping keeps the simulation vocabulary precise while keeping UI phrasing intuitive.

---

## 4. Weapon, Grip, and Technique Interplay

1. **Template-level data** (`src/domain/weapon.zig:118-135`) already stores `length`, `weight`, `balance`, `features`, and grip flags (one-/two-handed, half-sword, murder-stroke). These are the raw ingredients for deriving Energy, Geometry, and Rigidity:
   - *Energy derivation:* compute rotational inertia for swings (weight × effective radius²) and linear kinetic energy for thrusts. Balance determines effective radius; grip (two hands vs. half-sword) alters the usable radius and therefore inertia.
   - *Geometry derivation:* start from `features` (spiked, hooked), blade curvature, and `damage_types`. e.g. a warhammer spike has high Geometry; murder-stroke inverts the sword, changing edge support.
2. **Technique modifiers** (`card_list.zig:50-113`) distinguish swing/thrust/throw via `attack_mode` but currently only tweak the stat ratio. A three-axis model requires techniques to provide *conversion factors*: e.g. a “lunge” might allocate more of the available Energy into Geometry (tip-first), whereas a “murder stroke” shifts Rigidity upward by bracing the blade with the off-hand.
   - *Draw cuts:* low relative angular energy yet high slicing efficiency. Techniques should explicitly trade Impact energy for boosted Geometry (Penetration) when edge alignment and blade curvature support sliding cuts, producing nasty wounds without inflating joule totals.
   - *Serrated edges:* rare but useful edge cases. Model with a tag that adds trauma/pain bonuses (sawing action) while slightly reducing Geometry to reflect poorer clean penetration; Rigidity stays determined by blade build.
   - *Hooks & beaks:* hook geometry excels at converting tangential motion into concentrated shear after the point “sets.” Once engaged, they often pull rather than strike, so large energy spikes are unnecessary but Geometry remains high. Techniques need to reflect the multi-stage action (impact → catch → yank) and the fact that hooks can apply leverage to joints/armor gaps instead of just slicing. Rigidity depends on the reinforced beak; large hooks also demand rules for snag risk (failure modes when the hook sticks). Armour coverage (`Totality` in `src/domain/armour.zig:54-79`) already models weaker zones (open backs, mail gaps), so hooks should interact with coverage by increasing the chance to exploit low-totality areas instead of inventing a new bypass mechanic.
3. **Natural weapons** (`src/domain/species.zig:91-176`) will need bespoke coefficients: fists have low Geometry/high Energy, bites have high Geometry + Rigidity but limited Energy. Their anatomical constraints (jaw strength, skull rigidity) substitute for `features`.
4. **Physiology & species**: since species already provide a body plan and base stats, we can derive organism-specific caps (e.g., Dwarves have shorter reach but higher power → lower effective radius but higher torque). Individual agents (Gog the Tall) could add per-body scaling factors (limb length) without rewriting the plan; we only need to tag which parts act as lever arms for techniques.

**Edge Cases:** Half-swording and pommel strikes are essentially new offensives defined per weapon/grip. We must allow offensive profiles to override the derived coefficients so designers can express “reverse grip thrust” without reinventing a weapon template.

---

## 5. Armour & Body Layer Implications

1. **Unified material layers:** Armour resolution already loops through a stack (`src/domain/armour.zig:242-328`), and tissue uses similar logic (`src/domain/body.zig:838-855`). To realise the design doc’s vision we should represent every layer (cloak, gambeson, plate, skin, fat, bone) via the *same shared material definition* that encodes both shielding behaviour (Deflection/Absorption/Dispersion) **and** the layer’s own susceptibility to damage (threshold/ratio per axis). That way:
   - Plate can shrug off punches (Energy below threshold) but still dent under large Impact because its material self-resistance expresses that relationship.
   - Body parts inherit behaviour from their constituent materials (bone vs. muscle) without authoring one-off tables per part.
   Existing fields map as follows:
   - `armour.Material.{thickness, hardness, flexibility}` become inputs for Deflection and Dispersion coefficients, but note that some properties (especially absorption) depend on geometry (e.g., quilted gambeson vs. solid plate). We may need per-layer shape modifiers or templated presets to capture those interactions without forcing authors to re-enter raw numbers every time.
   - Tissue absorption tables should be re-expressed as per-axis coefficients tied to material definitions like “muscle tissue,” “cortical bone,” etc., so both armour and bodies compose layers from the same library. Declaring presets (e.g., “standard limb muscle”) can prevent data entry from becoming tedious.
   - Weapon durability can reuse these materials when modelling self-damage (e.g., brittle hooks with low Rigidity thresholds).
   - **Processing order:** when a packet enters a layer, first apply shielding (deflection/absorption/dispersion) to compute the residual axes that continue inward. Only after that step do we test the residual axes against the layer’s own susceptibility thresholds to determine whether the layer itself deforms, fractures, or survives intact. Dispersion therefore never contradicts the self-resistance values: plate can have low dispersion (transmits force) yet high thresholds (hard to dent), while padding has high dispersion but low thresholds (protects what’s beneath while getting chewed up).
2. **Geometry & coverage:** We currently encode coverage via `Totality` (“frontal”, “minimal”) and per-part templates, but there is no explicit area or thickness per part. We must decide whether to introduce scale factors (e.g., humerus circumference) or treat everything relative to a reference limb. If species introduce non-humanoid plans, these scalars need to live on the plan entries themselves. Example: Gog the Tall could be represented by scaling limb lengths (affects Energy leverage) and tissue thickness (affects Geometry path) via per-agent modifiers layered over the shared plan.
3. **Armour-body integration:** Instead of two separate systems (armour first, then tissue), we can compose a single ordered list of layers: `[cloak padding][mail][plate][skin][fat][muscle][bone]`. Each layer consumes the three axes and emits:
   - Residual axes for the next layer.
   - Local trauma (for pain/trauma resources).
   - Structural damage increments (for severity).
   - Armour integrity loss (where applicable).
   This change implies refactoring `damage.Packet` to carry the three axes plus metadata (damage kind, hit quality). We still need `damage.Kind` for resistances, bleed effects, and conditions.

---

## 6. Non-Physical & Hybrid Damage

- **Existing taxonomy:** `damage.Kind` already enumerates elemental, energy, biological, and magical damage (`src/domain/damage.zig:301-359`). Resistances are keyed by kind (`src/domain/damage.zig:21-33`), so non-physical interactions can remain in that layer.
- **Proposal:** Keep Geometry/Energy/Rigidity as *physical subcomponents* that only apply when `kind.kind() == .physical`. Non-physical kinds opt into whichever subset makes sense:
  - Fire/corrosion: skip penetration mechanics, act directly on tissue layers via resistances and DoT.
  - Lightning/radiation: bypass physical armour entirely and instead couple to conductance/immunity systems.
  - Hybrid attacks (e.g., flaming sword) can carry both physical axes and an elemental payload.
- **Avoid coefficient explosion:** Do not introduce “fire bite” etc. Instead, use existing resistance tables plus new layer metadata like `thermal_diffusion` or `conductivity` only if we truly need them. The key is to keep the physical axes orthogonal and let other systems piggyback where appropriate.

---

## 7. Devil’s Advocate & Open Questions

1. **Axis independence:** With Geometry / Energy / Rigidity terminology, the conceptual split is clearer, but we still need formal proofs that these axes aren’t redundant when reduced to formulas. The design needs to show how, for example, curved draw cuts (high Geometry, low Energy) and maces (high Energy, high Rigidity, moderate Geometry) both exist without conflating axes.
2. **Technique variability:** How do we represent techniques that dynamically change axes during resolution (half-sword thrust after an initial swing)? Do we support multi-stage packets or require designers to script them as separate techniques?
3. **Stat interaction:** Current stats feed directly into damage. In the new model, do stats increase available Energy, improve control over Geometry (edge alignment), or influence Rigidity (through grip strength)? Power vs. speed might map differently across axes.
4. **Armour data burden:** Designers must now specify three coefficients per material instead of a single threshold/ratio per damage kind. We need tooling or derived defaults so armour creation does not become intractable.
5. **Body diversity:** Without explicit limb lengths/thicknesses, deriving Energy leverage and Geometry paths for non-humanoids is speculative. Do we attach physical dimensions to part definitions (in `body.HumanoidPlan`) or compute them from species-level scale factors?
6. **Non-physical spillover:** If the axes only matter for physical kinds, how do we avoid “dead code” when a fight features elemental weapons? Perhaps trauma/pain resources should accept contributions from non-physical hits even if armour bypasses the physical axes.
7. **Weapon durability coupling:** Rigidity vs. Geometry may diverge further once we consider weapon self-damage (e.g., brittle spikes with great Geometry but low structural Rigidity). We need to plan how applying damage to weapons feeds back into these axes without mixing the concepts again.

---

## 8. Roadmap – Plan for the Plan

1. **Data Audit & Instrumentation**
   - Catalogue all weapon templates, armour materials, and tissue templates, documenting available fields and identifying gaps (thickness per part, grip modifiers).
   - Prototype logging hooks to capture real combat packets, so we can sanity-check derived axes against observed wounds.
   - Define the data model for per-part geometry (length, thickness, area). Capture baseline values on body plans (e.g., `HumanoidPlan`) and specify how species/individuals override them. Without this deliverable the later derivations have nothing to consume.
2. **Axis Specification**
   - Formal definitions (units, ranges, baseline) for Geometry, Energy, and Rigidity.
   - Mapping formulas from weapon/technique/species data to axis magnitudes, including special cases (thrust vs. swing vs. throw).
   - Naming decision with supporting rationale.
3. **Layer Interaction Design**
   - Unified material schema with per-axis coefficients plus geometry-aware modifiers/presets so armour, tissue, and weapons reuse the same data without tedious hand-tuning.
   - Conversion rules from layer outputs to wounds, pain, trauma, and armour integrity.
   - Strategy for representing geometry/thickness at the part level or via scale factors.
4. **Modifier & System Integration**
   - Reconcile with `doc/issues/combat_modifiers_redesign.md`: ensure stakes/commitment only affect hit quality or axis allocation, not raw energy.
   - Determine how conditions, events, and cards reference the new axes (e.g., a modifier that increases bite temporarily).
5. **Pilot Implementation Plan**
   - Select a narrow scenario (e.g., hammer vs. gambeson vs. unarmoured) to implement end-to-end.
   - Define validation tests mirroring the ones in `doc/artefacts/damage_lethality_analysis.md`.
   - Outline migration steps for data files (weapons, armour, bodies) and backward-compatibility strategy for existing saves/tests.

Each phase should end with a written artefact (audit results, formal spec, interaction design, integration notes, pilot report) to keep the conceptual model honest before code churn begins.

---

## Status & Checklist (2026‑01‑10)

Latest implementation review: `doc/reviews/geometry_momentum_rigidity_implementation_review.md` (2026‑01‑10) validates the progress below and calls out the follow-ups now tracked in the checklist.

### Completed Work
- [x] **T033 – Armour 3-axis integration.** Armour stacks now consume generated materials, run deflection/absorption/dispersion per layer, and pass residual packets inward (`src/domain/armour.zig`). Converter emits `ArmourMaterialDefinition`/`ArmourPieceDefinition`, and `armour_list.zig` validates IDs at comptime.
- [x] **T035 Phases 0‑3 – Data-driven bodies/tissues.** `data/bodies.cue` defines tissue stacks, body plans, and species; `body_list.zig` builds runtime `TissueStacks`/`BodyPlans`; `Body.fromPlan` now sources its parts, hierarchy, and tissue composition from generated data.
- [x] **Instrumentation & audit logging.** Minimal packet logging landed in `audit_log.zig`, `event.log` captures combat packets, and §9.5’s event-hook plan remains optional for richer telemetry.
- [x] **Data audit tooling.** `doc/artefacts/data_audit_report.md` plus `just audit-data` enumerate every weapon/technique/armour/tissue entry, emit derived axis values, and flag missing coefficients (currently 17 warnings: technique axis defaults + tissue thickness sums).

### Outstanding / Next Steps
- [x] **T035 Phase 3.3 – Body part geometry.** Extend `PartDef`/`Part` with `BodyPartGeometry`, copy from generated plans, and pass into `applyDamage(...)`. Unlocks penetration path-length math without inventing placeholder numbers.
- [x] **T035 Phase 4 polish – Tissue resolution (complete 2026-01-10).**  
  • consume `layer.thickness_ratio × part_geometry.thickness_cm` when reducing Geometry;  
  • add a physical-only guard (non-physical packets bypass the 3-axis pipeline);  
  • remove the slash/pierce “geometry==0 stops everything” coupling so Energy/Rigidity still propagate;  
  • revisit severity mapping/tests once the per-axis contributions replace the legacy scalar thresholds.
- [x] **Damage-packet axis export (T037 complete).** `damage.Packet` now carries `geometry`/`energy`/`rigidity` fields. `createDamagePacket` derives axes from weapon physics × technique multipliers × stats × stakes. Armour/tissue consumers use packet axes with legacy fallback for backward compat.
- [x] **Technique axis coverage (T037 decision).** Allow 1.0/1.0/1.0 defaults. Weapon geometry/rigidity coefficients already differentiate swing vs thrust; technique-specific bias can refine later. No enforcement in generator.
- [ ] **Tissue thickness normalisation (subtask under T035).** `digit`, `joint`, and `facial` templates sum to <0.95. Either adjust the ratios or annotate the intended scaling so audits stop flagging them.
- [ ] **Event instrumentation (optional follow-up).** If `event.log` proves insufficient, revisit §9.5’s `combat_packet_resolved` event so audits and UI can subscribe to the same structured payloads.
- [ ] **Shared rigidity helper.** Armour and tissue each define `deriveRigidityFromKind`; move the helper into `damage.zig` (per implementation review §3.1) so future tuning stays consistent.
- [ ] **Generated-data integration test.** Add a “knight’s sword vs. plate” style integration using generated IDs only (implementation review §3.3) to validate the data+runtime path before broader migration.

### Decisions & References
- **CUE-first data authoring is the baseline.** Continue expanding schemas instead of reintroducing ad-hoc Zig tables; converter validation remains the guardrail.
- **Shared material model is canonical.** Armour, tissue, and eventually weapon durability all reference the same shielding + susceptibility coefficients.
- **Audit warnings are tracked inputs.** Treat the outstanding axis_bias entries and thickness mismatches as blocking data debt for Phase 4 validation rather than cosmetic clean-up.

### Open Questions / Risks
- [ ] **Per-part scale derivation.** Where do limb thickness/length/area values originate (plan defaults vs. species modifiers vs. agent overrides)? Needed before we compute lever arms and path lengths for axis derivation.
- [x] **Non-physical packet handling.** T037 decision: zero out geometry/energy/rigidity when `kind.isPhysical() == false`. Armour/tissue short-circuit 3-axis logic on that guard. Thermal/conductive fields remain anchored to existing `damage.Kind` resistances for now.
- [x] **Weapon/technique axis formulas.** T037 implements reference-energy scaling: `actual_energy = reference_energy_j × stat_scaling × stakes`. Full kinematic derivation (computing ω/v from stats, then ½Iω² or ½mv²) deferred as future calibration work. Technique axis multipliers (geometry/energy/rigidity) default to 1.0; weapon coefficients provide differentiation.
- [x] **Test coverage (complete 2026-01-10).** Integration tests in `damage_resolution.zig` cover pierce/slash/bludgeon through armour→tissue pipeline. Unit tests in body.zig and armour.zig validate 3-axis mechanics.

Future edits should tick the checkboxes above (with kanban references such as T033, T035, forthcoming packet-axis task) instead of appending new ad-hoc status sections.

### 9.9 Phase 3.3 Body Part Geometry - Complete (2026-01-10)

Geometry is fully wired through the body system:
- `BodyPartGeometry` (thickness_cm, length_cm, area_cm2) defined in generated data
- `body_list.zig:19` re-exports from generated
- `body.PartDef` and `body.Part` carry `.geometry` field
- `body.zig:602` passes geometry to `applyDamage(packet, tissue, geometry)`
- Generated humanoid plan includes per-part geometry values

**Remaining (Phase 4 polish):**
- `body.zig:904` TODO – use `layer.thickness_ratio * geometry.thickness_cm` for path-length reduction of geometry axis in tissue resolution.
- Enforce the topological assumption called out in `doc/reviews/body_hierarchy_validation.md`: add assertions/validation so `Body.computeEffectiveIntegrities` only runs on parent-before-child order.

### 9.10 Armour Runtime Loader - Complete (2026-01-10)

`armour_list.zig` now provides full comptime-built runtime types:
- `Materials` array: runtime `armour.Material` built from generated definitions
- `Templates` array: runtime `armour.Template` with material + pattern refs
- `getMaterial(id)` / `getTemplate(id)`: comptime lookup by ID
- Integration tested: `getTemplate("steel_breastplate")` → `Instance.init()` → `Stack.buildFromEquipped()` works end-to-end

### 9.11 Audit Script - Complete (2026-01-10)

`scripts/cue_to_zig.py` now supports `--audit-report` and `--audit-only` flags:
- Validates weapons, techniques, armour materials/pieces, tissue templates, body plans
- Cross-reference checks (pieces→materials, body plans→tissue templates)
- Generates markdown report with summary tables and issue details
- Usage: `cue export data/*.cue --out json | ./scripts/cue_to_zig.py --audit-report doc/artefacts/data_audit_report.md`
