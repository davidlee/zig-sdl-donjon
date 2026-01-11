# Cards Data Model Overview

## File Structure
- **`src/domain/cards.zig`**: Shared card infrastructure (Rarity, Zone) common to all card types
- **`src/domain/actions.zig`**: Action-specific types for playable cards (Template, Instance, rules, TagSet, techniques, etc.)
- **`src/domain/action_list.zig`**: Curated action template lists (BeginnerDeck, TechniqueEntries, modifier templates, condition dud cards)

## Core Types (in actions.zig)
- `Template` holds identity (`id`, `rarity`, `tags`, `cost`), playability metadata (`PlayableFrom`, `combat_playable`, `cooldown`, optional rune icon), and a list of `Rule`s.
- A `Rule` couples a `Trigger` with a `Predicate` and one or more `Expression`s. Triggers cover lifecycle hooks (`on_play`, `on_draw`, `on_tick`, `on_commit`, `on_resolve`), event subscriptions via `on_event: EventTag`, and dud-card support via `while_in_hand` (continuous effect) and `on_play_attempt` (fires when any card play is attempted, enabling blocking via `cancel_play` effect).
- `Predicate` union encodes validity/gating conditions: tag requirements, weapon reach, range, advantage thresholds, condition presence/absence, composable via `not`, `all`, `any`.
- Each `Expression` describes work to perform: the `Effect` union carries payloads for combat techniques, resource modifications, card movement, condition changes, emitting events, play modification/cancellation, range/position adjustments, etc. Expressions also carry optional `filter: ?Predicate` guards and `target: TargetQuery` descriptors so targeting stays data-driven.

## TagSet
- `TagSet` is a packed bitset (u32 with padding for alignment) supporting queries (`hasTag`, `hasAnyTag`, `canPlayInPhase`).
- Tags include: melee, ranged, offensive, defensive, spell, item, buff, debuff, reaction, power, skill, meta, manoeuvre, phase_selection, phase_commit, precision, finesse, involuntary, and **modifier** (replaces the removed `Kind.modifier` enum value).
- **Modifier detection**: Use `template.tags.modifier` instead of the removed `Kind` enum.

## Design Principles
- Because every card behavior flows through this rules→predicates→expressions pipeline, new mechanics (e.g., condition-triggered cards, hand auras) should extend the existing unions/enums so they can be represented as data; bespoke imperative handling is discouraged.
- Helper structs (`ChannelSet`, `Technique`, `ModifyPlay`, `TargetQuery`, etc.) keep card behavior modular and allow new cards/mechanics to be composed by assembling data rather than branching logic.

## Dud Cards
Involuntary status cards injected when conditions are gained. Templates define behavior (time cost, blocking via `on_play_attempt`/`cancel_play`), while injection is handled by `EventProcessor.injectDudCardIfMapped()` when `condition_applied` events fire. Mapping from `Condition` to `Template` is in `action_list.condition_dud_cards`. Cards use `.cost.exhausts = true` for auto-exhaust. The `involuntary` tag prevents withdrawal via Focus during commit phase (`canWithdrawPlay` checks this). Zone.limbo represents cards injected from nowhere.
