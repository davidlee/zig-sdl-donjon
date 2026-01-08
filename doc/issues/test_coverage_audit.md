# Test Coverage Audit – 2026-01-10

## Scope & Method
- Reviewed every Zig source under `src/` plus `src/testing` harness files.
- Classified coverage as behaviourally meaningful (verifies observable outcomes) vs. structural (local helpers only).
- Flagged tests embedded inside production files that instantiate whole worlds/encounters (integration logic living in unit files).
- Recorded dead or placeholder tests, duplicated fixture code, and areas where tests should live in `src/testing/integration/`.

## Headline Risks
- **Command stack (apply/command_handler + event_processor) has zero tests** even though it mutates state, reserves resources, and emits UI-critical events.
- **World lifecycle (`World.processTick`, FSM transitions, encounter cleanup) only tested via CardRegistry helpers**, so regressions in turn progression or tick cleanup would go unnoticed.
- **Query boundary and presentation cache (`query/combat_snapshot`, coordinator, effects, graphics, views) are almost entirely untested**, risking UI/domain drift.
- **Integration harness covers a single card flow scenario**, leaving commits, cancellations, stacking, turn FSM transitions, and enemy AI untouched.
- **Several inline tests spin up worlds/encounters (`resolution/outcome.zig`, `resolution/context.zig`, `apply/targeting.zig`) instead of using `src/testing/integration`, mixing unit + integration concerns and duplicating fixtures.**

## Domain – Apply
| File | Tests? | Observations / Risks | Recommended Coverage |
| --- | --- | --- | --- |
| `src/domain/apply/command_handler.zig` | None | Core command workflows (`playActionCard`, `cancelActionCard`, `commit*`) mutate stamina/focus, move cards, and emit events with no behavioural tests. | Use integration harness to cover play → pending → cancel, pool clone lifecycle, focus costs for withdraw/add/stack, event emission, and attention updates. |
| `src/domain/apply/event_processor.zig` | None | `dispatchEvent`, `endTurnCleanup`, AI triggers, tick transitions, condition-driven dud card injection all run untested. | Harness-based tests for: entering `in_encounter`, draw_hand pipeline, end-of-turn cleanup (hand discard + timeline cleanup), AI card play trigger, combat termination outcomes, and world-map cleanup. |
| `src/domain/apply/costs.zig` | None | `applyCommittedCosts` finalizes stamina and moves/destroys cards; errors would silently leak stamina or leave cards stranded. | Unit tests simulating committed actions for hand vs. pool cards, exhaust vs. discard destinations, and event emission order. |
| `src/domain/apply/effects/commit.zig` | None | `executeCommitPhaseRules` and `applyCommitPhaseEffect` modify plays, costs, and timeline, yet no coverage exists. | Integration-style tests using persona templates to validate `modify_play`, `cancel_play`, and predicate filtering for `.my_play` / `.opponent_play`. |
| `src/domain/apply/effects/resolve.zig` | None | `executeResolvePhaseRules` + `tickConditions` drive stamina/focus recovery and condition expiration; regressions would desync gameplay and events. | Tests covering stamina/focus modifiers, condition expiration & successor application, and `.all_enemies` resolve expressions. |
| `src/domain/apply/effects/manoeuvre.zig` | Partial | Tests only cover `adjustRange`; the higher-level `executeManoeuvreEffects`, propagation, and event emission remain unverified. | Integration tests for multi-target manoeuvres, propagation rules, position adjustments, and event payloads. |
| `src/domain/apply/effects/positioning.zig` | Partial | Coverage limited to scoring/conflict helpers; `resolvePositioningContests` and `applyContestOutcome` (range floors, range_changed events) lack tests. | Harness tests verifying conflict outcomes per ManoeuvreType, Reach floors, stalemate handling, and emitted `manoeuvre_contest_resolved`. |
| `src/domain/apply/validation.zig` | Yes | Predicate helpers covered, but `validateCardSelection`, `checkOnPlayAttemptBlockers`, and resource gating lack behavioural tests. Duplication: many tests recreate mini templates/registries ad hoc. | Add persona/fixture-backed tests for full validation flows (phase gating, stamina/time costs, predicate failure cases). Centralize template fixtures to cut duplication. |
| `src/domain/apply/targeting.zig` | Partial | Tests only touch `expressionAppliesToTarget` and modifier attachment; `evaluateTargets`, `.single` resolution, range filtering, and `.evaluatePlayTargets` remain untested. Inline tests construct full Worlds instead of using harness. | Unit tests for query permutations and `evaluatePlayTargets`; move world-dependent cases to integration (with fixtures). |
| `src/domain/apply/mod.zig` & `src/domain/apply.zig` | None (aggregation) | Thin re-exports; low risk but no smoke tests ensuring module wiring. | Optional: simple compile/link smoke test (already indirectly covered via inline tests). |

## Domain – Combat
| File | Tests? | Observations / Risks | Recommended Coverage |
| --- | --- | --- | --- |
| `src/domain/combat/agent.zig` | Yes | Covers condition caches/resources, but no tests for `initCombatState`, pool clone handling, or engagement attention logic. Fixtures duplicate SlotMap setup per test. | Add fixture-backed tests for combat state init/cleanup, `inAlwaysAvailable`, and `attention.primary` assignments. Share persona fixtures. |
| `src/domain/combat/armament.zig` | Yes | Basic category tests only; multi-weapon interactions untested. | Extend tests to dual/compound loadouts, verifying coverage and reach lookups. |
| `src/domain/combat/plays.zig` | Yes | Good structural coverage for timeline and slots, yet no behavioural coverage for `getPlayDuration`, `hasFootworkInTimeline`, or `PlaySource` lifecycles. | Add tests for duration calculations (damage modifiers) and footwork detection using sample registry entries. |
| `src/domain/combat/engagement.zig` | Yes | Covers canonicalization and advantage snapshots. | Add tests for `assessFlanking` multi-agent angles (currently only via encounter tests). |
| `src/domain/combat/encounter.zig` | Minimal | Only flanking helper has tests; FSM transitions, turn history, and enemy management untested. | Integration tests for `transitionTurnTo`, `addEnemy`, timeline clearing, and attention propagation between state transitions. |
| `src/domain/combat/advantage.zig` | None | AdvantageEffect.apply/scale directly mutate engagements/balance with zero tests. | Unit tests for clamp behaviour and scaling per stakes. |
| `src/domain/combat/state.zig` | None | Core draw/hand/discard management is untested; bugs would corrupt decks. | Tests for `moveCard`, `shuffleDraw`, cooldown ticking, and pool clone creation. |
| `src/domain/combat/types.zig` | None | `TurnFSM` definitions have no transition tests, so invalid event sequences may go unnoticed. | FSM unit tests covering all event/phase paths. |
| `src/domain/combat/mod.zig` & `combat.zig` | None (aggregation) | Serve as re-export hubs. | N/A. |

## Domain – Tick & Resolution
| File | Tests? | Observations / Risks | Recommended Coverage |
| --- | --- | --- | --- |
| `src/domain/tick/resolver.zig` | Minimal | Only `compareByTime` + `reset` tested; no coverage for `commitPlayerCards`, `commitMobActions`, targeting filters, or resolution loop. | Integration tests covering commit pipelines, defensive overlaps, attention penalties, and multi-target resolution. |
| `src/domain/tick/committed_action.zig` | None | Data structs lack tests for comparison helpers beyond the single `compareByTime` test indirectly. | Unit tests for `TickResult` memory management and `CommittedAction` copy semantics. |
| `src/domain/tick/mod.zig` & `src/domain/tick.zig` | None | Re-export shims. | N/A. |
| `src/domain/resolution/outcome.zig` | Partial | Inline tests bootstrap Worlds/Agents to assert events but mix integration concerns; `test "calculateHitChance base case"` is a placeholder. Duplicated `makeTestWorld`/`makeTestAgent`. | Move scenario tests into integration suite; add true unit tests for math helpers; delete placeholder test. |
| `src/domain/resolution/context.zig` | Partial | Similar to outcome: uses inline `makeTestWorld`, covering overlay bonuses via integration-like setups. | Relocate to integration tests or use fixtures; add pure unit tests for `CombatModifiers` math. |
| `src/domain/resolution/damage.zig` | Minimal | Only `createDamagePacket` tested; other helpers unverified. | Add tests for `getWeaponOffensive`, hit location damage scaling. |
| `src/domain/resolution/height.zig` | Yes | Good coverage for adjacency & hit selection. | Extend to cases with defensive coverage stacks. |
| `src/domain/resolution/advantage.zig` | Minimal | A few tests around `getAdvantageEffect`; `applyAdvantageWithEvents` lacks coverage. | Add tests verifying event emission and stake scaling. |
| `src/domain/resolution/mod.zig` & `src/domain/resolution.zig` | None (aggregation) | Re-exports. | N/A. |

## Domain – Systems, Registries, and Supporting Modules
| File | Tests? | Observations / Risks | Recommended Coverage |
| --- | --- | --- | --- |
| `src/domain/world.zig` | Minimal | Only CardRegistry helpers are tested; FSM transitions, `processTick`, `transitionTo`, RNG emission, and resource cleanup lack coverage. | Integration tests for state transitions, tick pipeline (executeManoeuvreEffects → applyCommittedCosts), and encounter cleanup. |
| `src/domain/events.zig` | None | Large event union lacks validation; no tests ensure tags round-trip or new events are consumed. | Add snapshot tests verifying serialization/tag coverage and EventSystem queue behaviour. |
| `src/domain/random.zig` | None | Random stream + event emission untested; missing coverage increases determinism risk. | Unit tests verifying stream seeding, `drawRandom` event payloads, and `RandomSource` wrappers. |
| `src/domain/card_list.zig` | None | Compile-time template repository has no smoke tests for `byName` or `hashName`. | Add comptime tests ensuring names resolve and duplicates detected. |
| `src/domain/cards.zig` | Partial | Only ChannelSet/TagSet helpers tested; Template methods (`getTechniqueWithExpression`, cost helpers) untested. | Unit tests covering template queries, triggers, and TagSet operations with realistic templates. |
| `src/domain/weapon_list.zig` | Yes | Verifies profile sanity. | Add reach/grip compatibility checks for new entries. |
| `src/domain/weapon.zig` | None | Core weapon templates & instances untested. | Tests for `Offensive`/`Defensive` invariants (e.g., default fragility, grip flags). |
| `src/domain/slot_map.zig` | None | Generational map critical for IDs yet unverified. | Tests for insert/remove/get semantics, generation bumping, and freelist reuse. |
| `src/domain/player.zig` | None | Player bootstrap sets up stats/weapons with zero checks. | Unit test ensuring `newPlayer` equips default buckler and resources. |
| `src/domain/inventory.zig` | None | Armour layering definitions untested. | Add coverage verifying coverage arrays + layer enums. |
| `src/domain/rules.zig` | None (stub) | Placeholder – low impact. | N/A. |
| `src/domain/ai.zig` | None | AI directors (`SimpleDeckDirector`, `PoolDirector`) execute untested loops, risking crashes. | Harness-based tests ensuring AI respects draw styles, cooldowns, and handles empty decks. |
| `src/domain/apply/mod.zig`, `src/domain/combat/mod.zig`, `src/domain/mod.zig` | None | Aggregators. | N/A, but consider compile smoke tests. |
| `src/domain/body.zig`, `src/domain/armour.zig`, `src/domain/stats.zig`, `src/domain/damage.zig`, `src/domain/condition.zig` | Yes | Rich behavioural coverage, but `damage.zig` has an empty `test "Kind"{}` that should either assert something or be removed. | Extend `damage.zig` tests to cover more functions; delete placeholder. |

## Domain – Query & Data
| File | Tests? | Observations / Risks | Recommended Coverage |
| --- | --- | --- | --- |
| `src/domain/query/combat_snapshot.zig` | Minimal | Three tests only cover empty snapshot lookups; no validation that snapshots mirror world state or modifier attachability. | Integration tests capturing `buildSnapshot` output before & after plays, primary target changes, modifier attachment rules, and `.playTarget` resolution. |
| `src/domain/query/mod.zig` | None | Re-export. | N/A. |
| `src/data/personas.zig` | Compile-only | Tests merely assert the personas compile; behaviour/use with fixtures untested. | Unit tests verifying fixtures integrate with `fixtures.agentFromTemplate` and encounter templates. |

## Presentation Layer
| File | Tests? | Observations / Risks | Recommended Coverage |
| --- | --- | --- | --- |
| `src/presentation/coordinator.zig` | None | Routes SDL input, caches combat snapshots, and orchestrates view selection; regressions could desync UI from world. | Headless tests for `getSnapshot` invalidation, `handleInput`, and chrome activation gating. |
| `src/presentation/graphics.zig` | None | `UX` owns textures, fonts, and coordinate transforms with no verification of layout math. | Unit tests for coordinate translation, asset loading fallbacks, and log texture cache invalidation. |
| `src/presentation/effects.zig` | None | EffectMapper/System translate domain events to animations; untested mapping risks missing visual cues. | Tests covering event→effect mapping and Tween lifecycle. |
| `src/presentation/card_renderer.zig` | None | Renders cards from DTOs; layout and layering logic unverified. | Snapshot tests for mana cost layout, selection highlights, and hover states. |
| `src/presentation/view_state.zig` | None | Centralized cursor/viewport math lacks safety net. | Tests for viewport translation, scroll bounds, and combat UI state transitions. |
| `src/presentation/combat_log.zig` | Yes | Tests cover append/scroll but not event formatting coverage breadth. | Extend tests for formatting branch coverage and localization edge cases. |
| `src/presentation/mod.zig` | None | Re-export; low risk. | Optional smoke test. |
| `src/presentation/controls.zig` | None | Maps SDL events to commands with zero tests. | Unit tests for button binding, mouse wheel handling, and command routing. |
| `src/presentation/views/view.zig` | None | Defines renderable union + asset IDs; no regression guard on view switching. | Tests ensuring new view variants register assets/renderables correctly. |
| `src/presentation/views/types.zig` | None | DTO definitions for views; no validation of defaults. | Tests for default struct initializations. |
| `src/presentation/views/card/mod.zig` | None | Aggregator for card views. | Smoke test hooking submodules. |
| `src/presentation/views/card/model.zig` | None | Builds card view models from domain/primitives. | Tests verifying DTOs react to CombatSnapshot statuses (playable, targeting). |
| `src/presentation/views/card/zone.zig` | None | Computes layout per zone; no coverage of zone-specific offsets. | Unit tests for zone rectangle math and selection states. |
| `src/presentation/views/card/data.zig` | None | Translates domain data to view data; untested conversions risk stale UI. | Tests for mapping card templates and modifier stacks to descriptors. |
| `src/presentation/views/menu.zig` | None | Menu view logic untested. | Snapshot tests verifying menu state transitions and command outputs. |
| `src/presentation/views/summary.zig` | None | Presents encounter summary; zero assurance. | Tests for summary data binding (loot, outcome). |
| `src/presentation/views/chrome.zig` | None | Surround UI (timeline, log) is untested. | Tests verifying chrome toggles, viewport offsets, and log integration. |
| `src/presentation/views/combat/mod.zig` | None | Aggregator for combat views. | Smoke test hooking submodules. |
| `src/presentation/views/combat/view.zig` | None | Main combat view builder lacking coverage for layout or selection cues. | Tests for selection highlight logic, snapshot-driven state. |
| `src/presentation/views/combat/avatar.zig` | None | Renders avatars/conditions; untested composition. | Tests for condition badge stacking and engagement indicators. |
| `src/presentation/views/combat/conditions.zig` | Yes | Tests cover categorization/priority; no DTO binding tests. | Extend tests for real combat snapshots and localization strings. |
| `src/presentation/views/combat/hit.zig` | None | Displays hit log entries without tests. | Tests for formatting (damage types, severity). |
| `src/presentation/views/combat/play.zig` | None | Renders timeline plays; no assurance on stacking visuals. | Tests verifying status icons, modifier badges, and primary target markers. |
| `src/presentation/views/title.zig` | None | Title screen view untested. | Tests for state transitions and button layout. |

## Testing Infrastructure
| File | Tests? | Observations / Risks | Recommended Coverage |
| --- | --- | --- | --- |
| `src/testing/fixtures.zig` | Minimal | Tests cover only agent creation; other helpers (encounter/world builders) absent. | Expand tests for encounter/world helpers once implemented to ensure teardown safety. |
| `src/testing/integration/harness.zig` | Minimal | Only init/deinit/enemy addition are tested; the majority of API (phase control, play helpers, expectation helpers) lacks coverage. | Add harness self-tests for `beginSelection`, `giveCard`, `commitPlays`, `resolveTick`, and event assertions to catch regressions. |
| `src/testing/integration/domain/card_flow.zig` | Minimal | Three scenarios cover single-card flow. Cancel/commit stack, multi-card timeline, and modifier scenarios missing. | Broaden integration tests to include cancel/commit workflows, modifier stacking, event processor triggers, and world cleanup. |
| `src/testing/system/mod.zig` | Placeholder | Contains a dummy test. | Replace with actual system-level smoke test or remove placeholder. |
| `src/testing/integration/mod.zig`, `domain/mod.zig`, `src/testing/mod.zig` | None | Re-export harness modules. | Ensure Zig build target enumerates all suites (already via root test). |

## Quality Issues to Address
- **Integration logic embedded in unit files**: `src/domain/resolution/outcome.zig` and `src/domain/resolution/context.zig` define `makeTestWorld`/`makeTestAgent` helpers and run full-world tests inline. Move these cases into `src/testing/integration/...` and keep unit files focused on pure logic.
- **Placeholder / dead tests**: `src/domain/resolution/outcome.zig` contains `test "calculateHitChance base case"` with a TODO body, and `src/domain/damage.zig` has `test "Kind" {}` with no assertions. Either implement meaningful checks or delete them to avoid false confidence.
- **Duplicated fixtures**: Multiple files (`combat/agent.zig`, `apply/validation.zig`, `resolution/*`) hand-roll SlotMaps, card templates, and world instances. Introduce shared helpers under `src/testing/fixtures.zig` (or personas) to cut duplication and make tests intention-revealing.
- **Missing integration coverage for AI and world transitions**: No existing test exercises `ai.SimpleDeckDirector`, `EventProcessor.dispatchEvent`, or `World.transitionTo`. These remain high-risk because they orchestrate multi-module flows.
- **Presentation snapshot drift risk**: `coordinator.getSnapshot` caches `query.buildSnapshot` results, but without tests the UI could silently fall out of sync with domain events.

## Recommended Next Steps
1. **Stabilize the command stack**: Write integration tests (using harness/personas) for `CommandHandler` play/cancel/commit flows and `EventProcessor` transitions before modifying these files.
2. **Cover world lifecycle**: Add tests that drive `World.transitionTo` → `processTick` → cleanup, ensuring events and registries stay consistent.
3. **Expand query/presentation assurance**: Build tests for `query/combat_snapshot` plus coordinator/effects mapping so UI-facing DTOs stay aligned with domain state.
4. **Refactor integration-heavy inline tests** into `src/testing/integration/` and consolidate shared fixtures to remove duplication.
5. **Fill glaring unit gaps** such as `combat/state`, `slot_map`, `random`, and `ai` before tackling new features, as regressions there would cascade across the system.
