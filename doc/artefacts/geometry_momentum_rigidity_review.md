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

## Next Actions

1. Kick off the data audit (Phase 1) with instrumentation to capture current packet values so we can compare recorded Energy/Geometry/Rigidity magnitudes against expectations.
2. Draft the shared material/preset schema (covering shielding vs. self-susceptibility plus geometry-aware modifiers) so armour and tissue authors understand the new declaration flow. Consider leveraging the schema-driven generation approach in `doc/issues/data_generation.md` so weapons/armour/bodies can inherit presets and derived values without repetitive Zig boilerplate.
3. Define and populate the per-part geometry dataset (plan-level defaults, species modifiers, potential per-agent overrides) so axis derivations have concrete path/lever inputs.
4. Schedule a dedicated design session to tackle Phase 2, focusing on formulas for deriving Geometry/Energy/Rigidity from weapon/technique/stat inputs, including corner cases like lunges, half-swording, and natural weapons.

Answering these will position us to draft the full specification confidently instead of refactoring blind.

---

## 9. Data Audit Status Check-in (2026‑01‑09)

### 9.1 Restated Audit Brief
- Phase 1 from Section 8 still anchors this effort: (a) instrument the current combat resolution to log packet amounts/penetration (soon axes) for ground-truth comparisons, (b) catalogue all weapon/armour/tissue templates so we know what physical descriptors exist and where the gaps lie, and (c) capture per-part geometry or scale factors so the forthcoming axis formulas have real lever/path inputs.
- Success criteria: every layer (armour+tissue) should reference a shared material definition with explicit shielding/susceptibility, every offensive profile should expose derived axis magnitudes, and we should have at least a draft dataset describing body-part dimensions so the later formulas are not speculative.

### 9.2 Modelling Implemented So Far
- `doc/artefacts/data_generation_plan.md` and the live CUE files (`data/materials.cue`, `data/weapons.cue`, `data/techniques.cue`, `data/armour.cue`) give us the scaffolding for most of the catalogue work:
  - **Shared materials** – `#Material` now encodes Deflection/Absorption/Dispersion plus per-axis thresholds/ratios for tissues and armour alike, with presets for muscle, bone, fat, steel plate, chain, and gambeson. Shape modifiers create the “geometry-aware” knobs we called for in §5.1.
  - **Armour pieces** – `#ArmourPiece` entries point directly to those materials and define coverage (tags, side, totality, layer), ready to be fed into a unified layer stack once the converter emits them.
  - **Weapons** – the weapon schema derives moment of inertia, effective mass, and reference energy from weight/length/balance; base Geometry/Rigidity coefficients plus curvature adjustments are expressed per template.
  - **Techniques** – techniques now live in data with damage instances, scaling, channels, overlays, and explicit `axis_bias` multipliers, matching the conversion-factor discussion in §4.
  - **Generation pipeline** – `scripts/cue_to_zig.py` already exports the weapon + technique data into `src/gen/generated_data.zig`, and `just generate`/`just check` run it automatically. This satisfies the “catalogue & validate before Zig” requirement and keeps the audit reproducible.

### 9.3 Gaps Blocking the Audit
- **Instrumentation** – we still lack packet logging hooks in the combat resolver, so there is no empirical data to compare against the derived coefficients. Adding temporary logging (even of the current amount/penetration scalars) remains step 1.
- **Tissue/body datasets** – bodies still use hard-coded tables in `src/domain/body.zig`. We need CUE definitions for tissue layers, body plans, and per-part scale factors (thickness, circumference, reach percentages) so the audit can confirm coverage completeness and give the axis formulas real numbers.
- **Armour integration** – the generator has not yet emitted armour stacks or wired them into runtime resolution. Until armour pieces consume the shared material presets in-game, the audit cannot verify that layering matches the design.
- **Species & natural weapons** – species metadata and natural weapons remain in Zig; they should move into CUE alongside weapons so Energy/Geometry/Rigidity derivations apply consistently and can be inspected as part of the audit.
- **Validation tooling** – there is no automated report summarising which templates lack required fields (e.g., missing curvature, absent axis bias, incomplete coverage totals). The audit needs such reporting to prove completeness.

### 9.4 Immediate Follow-ups
1. ✅ **Done** - Add minimal packet logging (`audit_log.zig` exists).
2. ✅ **CUE done, wiring pending** - `data/bodies.cue` complete with tissues/body plans/species. Generates `GeneratedBodyPlans` and `GeneratedTissueTemplates`. Runtime wiring tracked in T035.
3. ✅ **Done** - T033 complete. Armour uses 3-axis model.
4. Produce an audit script/report (likely via the Python converter) that lists every weapon/technique/armour/tissue entry with derived axis values and flags missing parameters.

### 9.5 Event-System Instrumentation Plan
- The existing event bus (`src/domain/events.zig`, see `events_system_overview` memory) already broadcasts key combat resolution milestones (technique resolved, armour deflected, wound inflicted). Rather than inventing a parallel logger, add a new packet-centric event (e.g., `combat_packet_resolved`) carrying the packet inputs/outputs, layer stack summary, and attacker/defender IDs.
- Emit this event at the point in resolution where packets are finalised; subscribers can then fork the stream to: (a) a simple audit drain that writes structured logs for Phase 1 analysis, and (b) the combat-log/UI layer, which is already interested in these details for richer damage numbers.
- Because events are double-buffered, consumers remain decoupled, and we can swap out the audit drain later without touching combat code—keeping instrumentation aligned with the “data-first” architecture while delivering the observability the audit requests.

Capturing this status inside the original geometry/energy/rigidity doc keeps the motivating questions and the data-audit deliverables tied together as we continue Phase 1.

### 9.6 Armour Emission Wired (2026-01-09)

**Completed:** Item #3 from 9.4 - converter now emits armour data.

Changes to `scripts/cue_to_zig.py`:
- Added `flatten_armour_materials()` to extract materials from `materials.armour`
- Added `flatten_armour_pieces()` to extract pieces from `armour_pieces`
- Added `emit_armour_materials()` generating `ArmourMaterialDefinition` structs with full shielding/susceptibility coefficients
- Added `emit_armour_pieces()` generating `ArmourPieceDefinition` structs with coverage entries
- Wired into `main()` so armour data flows through the pipeline

Generated output (`src/gen/generated_data.zig`) now includes:
- `GeneratedArmourMaterials`: chainmail, gambeson, steel_plate with all axis coefficients
- `GeneratedArmourPieces`: gambeson_jacket, steel_breastplate with coverage (part_tags, side, layer, totality)

**Design notes:**
- CUE layer types (`padding`/`outer`/`cloak`) map to `inventory.Layer` slots (`Gambeson`/`Plate`/`Cloak`)
- Coverage uses `body.PartTag` for part identification, `body.Side` for laterality
- Material coefficients include shape modifiers (profile, dispersion_bonus, absorption_bonus)

**Remaining for full wiring:**
- Create `src/domain/armour_list.zig` to build runtime `armour.Template`/`armour.Material` from generated data (following `species.zig` pattern)
- Integrate with equipment system so equipped pieces populate `armour.Stack`
- Enrich `data/armour.cue` with more piece definitions once loader works

### 9.7 Comptime Validation Added (2026-01-09)

Created `src/domain/armour_list.zig` following the pattern from `species.zig` (see data_generation_plan.md 8.5 Option C):

- `resolveMaterial(id)` - comptime lookup with clear error if material_id missing
- `resolvePiece(id)` - comptime lookup with clear error if piece_id missing
- `pieceMaterial(piece_id)` - resolves piece then its material
- `validateAllPieces()` - runs at comptime, validates all piece->material references

If CUE defines a piece referencing a non-existent material, compilation fails with:
```
error: Unknown armour material ID: 'bad_id'. Add it to data/materials.cue under materials.armour or check the piece definition in data/armour.cue.
```

Also made `armour.Totality` public so generated data can reference it.

### 9.8 Status Update (2026-01-09)

**§9.4 #1 - Packet logging:** Already implemented. `src/domain/audit_log.zig` provides `drainPacketEvents()` which is called in the main event loop (`src/main.zig:84`) to capture combat packet data for analysis.

**Remaining from §9.4:**
- #4: Audit script/report (not started)

**§9.6 Completed (2026-01-09):**
- Runtime armour loader implemented in `src/domain/armour_list.zig`
- `armour.Material` updated to 3-axis model (deflection/absorption/dispersion + per-axis susceptibility)
- Generated `Materials`, `Patterns`, `Templates` lookup tables
- Integration tests verify `Instance.init` and `Stack.buildFromEquipped` work with generated data
- See `kanban/T033_armour_3axis_migration.md` for full task tracking

**Remaining:**
- Update `resolveThroughArmour` to use 3-axis model (Phase 4 of T033)
- Remove deprecated fields after resolution migration
