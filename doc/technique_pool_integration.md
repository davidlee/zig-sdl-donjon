# Model B: Technique Pool + Modifier System

## Goal

Refactor card system so:
- Techniques always available from pool (not shuffled)
- Hand contains modifier/tactical cards
- Play = primary action + modifier stack
- System flexible enough for non-technique plays (footwork, reactions, recovery)

## Current State

```
Agent.techniques_known: ArrayList(ID)  // exists, empty
Agent.deck_cards: ArrayList(ID)        // filled with technique-action cards
Play.primary: ID                       // single card with embedded technique
Play.reinforcements_buf: [4]ID         // stacking same card
Play.cost_mult, damage_mult            // stored modifiers (set by commit effects)
```

## Target State

```
Agent.techniques_known: ArrayList(ID)  // core techniques (Thrust, Swing, etc.)
Agent.deck_cards: ArrayList(ID)        // modifier cards (High, Committed, etc.)

Play.action: ID                        // primary action (technique, maneuver, or standalone)
Play.modifier_stack_buf: [4]ID         // modifier cards that enhance the action
// cost_mult, damage_mult computed from modifier_stack
```

## Design Decisions

### 1. Play struct: Generic "action + modifiers" not "technique + modifiers"

The primary card can be:
- A technique (from `techniques_known`) - combat attack/defense
- A maneuver (from hand) - footwork, positioning
- A reaction (from hand) - conditional response
- A utility (from hand) - stamina recovery, focus spend

This keeps the system flexible. Modifiers enhance any primary action.

### 2. PlayableFrom determines source validation

```zig
// Technique card template
playable_from = .{ .techniques_known = true }

// Modifier card template
playable_from = .{ .hand = true }

// Hybrid (can be played standalone OR as modifier)
playable_from = .{ .hand = true, .as_modifier = true }  // new flag needed
```

### 3. Computed vs stored modifiers

**Decision: Keep both.**

- `Play.cost_mult`, `Play.damage_mult` remain (set by commit phase effects like Feint)
- Add computed methods that *start* from modifier_stack, then apply stored overrides
- Reason: Commit phase effects (cancel_play, modify_play) still need to override

```zig
pub fn effectiveCostMult(self: *const Play, registry: *const CardRegistry) f32 {
    var mult: f32 = 1.0;
    for (self.modifiers()) |mod_id| {
        const card = registry.get(mod_id) orelse continue;
        if (card.template.modifier_effects) |fx| {
            mult *= fx.cost_mult orelse 1.0;
        }
    }
    return mult * self.cost_mult;  // apply stored override last
}
```

### 4. Stakes escalation

**Current:** Based on `reinforcements_len` (0→guarded, 1→committed, 2+→reckless)

**New:** Based on `modifier_stack_len` + explicit stakes modifiers
- Modifier cards like `Committed` add +1 to escalation
- `effectiveStakes()` sums base stakes + modifier escalation

### 5. Modifier card template design

Add to `cards.zig`:

```zig
pub const ModifierEffects = struct {
    cost_mult: ?f32 = null,
    damage_mult: ?f32 = null,
    stakes_delta: ?i8 = null,           // +1 committed, +2 reckless
    height_override: ?body.Height = null,
    advantage_override: ?combat.TechniqueAdvantage = null,
    // Future: offhand_action, footwork_distance, etc.
};
```

Add `.modifier` to `Kind` enum (or reuse `.passive`).

### 6. Focus costs

Per `focus_design.md`:

**Template costs:**
- `Cost.focus: f32 = 0` - some cards cost Focus to play (e.g., commit-phase cards)
- Validation: `agent.focus.available >= template.cost.focus`
- Focus is spent immediately via `agent.focus.spend()`, not committed like stamina

**Commit phase actions (1F each):**
| Action | Effect |
|--------|--------|
| Withdraw | Remove play, refund stamina |
| Add | Add modifier from hand (marked `added_in_commit`, can't be stacked) |
| Stack | Attach modifier to existing play (1F for ALL stacking that turn) |

**Modifier Focus costs:**
- Attaching modifiers may have Focus cost defined in template
- Applies on attachment, not on resolution

### 7. New command flow

**Selection phase:**
```
select_action: ID           // technique from pool, or card from hand
attach_modifier: { action_play_index, modifier_id }
```

**Commit phase (existing, reinterpreted):**
```
commit_add      // attach modifier to existing play (1F)
commit_withdraw // remove play entirely
commit_done     // proceed to resolution
```

---

## Implementation Phases

### Phase 0: Modifier infrastructure (no behavior change)

**Files:** `cards.zig`, `card_list.zig`

1. Add `ModifierEffects` struct to `cards.zig`
2. Add `modifier_effects: ?ModifierEffects` to `Template`
3. Add `.modifier` to `Kind` enum (or decide to use `.passive`)
4. Create minimal modifier templates in `card_list.zig`:
   - `high_modifier` - height_override = .high, damage_mult = 1.2
   - `low_modifier` - height_override = .low, cost_mult = 0.8
   - `committed_modifier` - stakes_delta = +1
   - `feint_modifier` - damage_mult = 0.0, advantage_override = favorable

**Test:** Templates compile, no runtime changes.

### Phase 1: Play struct refactor

**Files:** `combat.zig`, `tick.zig`, `apply.zig`

1. Rename Play fields:
   - `primary` → `action`
   - `reinforcements_buf` → `modifier_stack_buf`
   - `reinforcements_len` → `modifier_stack_len`
   - `reinforcements()` → `modifiers()`
   - `addReinforcement()` → `addModifier()`

2. Add computed methods:
   ```zig
   pub fn effectiveCostMult(self: *const Play, registry: *const CardRegistry) f32
   pub fn effectiveDamageMult(self: *const Play, registry: *const CardRegistry) f32
   pub fn effectiveHeight(self: *const Play, registry: *const CardRegistry, base: body.Height) body.Height
   pub fn effectiveStakes(self: *const Play, registry: *const CardRegistry) Stakes
   ```

3. Update `commitPlayerCards()` in tick.zig to use computed methods

4. Update `commitStack()` in apply.zig (now attaches modifiers, not same-card stacking)

**Test:** Existing tests pass with renamed fields. Computed methods have unit tests.

### Phase 2: Populate techniques_known

**Files:** `world.zig`, `card_list.zig`, `combat.zig`

1. Create `BaseTechniques` array with 7 core techniques:
   - Thrust, Swing, Feint, Deflect, Parry, Block, Riposte
   - Each has `playable_from = .{ .techniques_known = true }`

2. In `World.init()`:
   - Create technique instances in card_registry
   - Populate `player.techniques_known` with technique IDs

3. Update `deck_cards` population:
   - Create `StarterModifiers` array (multiple copies of each modifier)
   - Populate `player.deck_cards` from modifier templates

4. Update `isInPlayableSource()` to properly handle techniques_known

**Test:** Player has 7 techniques in pool, modifiers in deck.

### Phase 3: Selection commands

**Files:** `commands.zig`, `apply.zig`

1. Add new commands:
   ```zig
   select_action: ID                              // create play with action
   attach_modifier: struct { play_index: usize, modifier_id: ID }
   ```

2. Command handlers:
   - `select_action`: Validate source (techniques_known or hand), create Play
   - `attach_modifier`: Validate modifier in hand, check Focus cost, add to play's modifier_stack

3. Update validation:
   - Techniques valid from `techniques_known`
   - Modifiers valid from `hand`
   - **Focus cost validation**: `agent.focus.available >= template.cost.focus`
   - **Conflict detection**: prevent attaching two height modifiers to same play

**Test:** Can select technique, attach modifiers. Focus validation rejects when insufficient.

### Phase 4: Resolution integration

**Files:** `tick.zig`, `apply.zig`

1. Update `commitPlayerCards()`:
   - Look up action card from registry
   - Compute all modifiers from stack
   - Create CommittedAction with computed values

2. Update `applyCommittedCosts()`:
   - Action: techniques stay in pool (no zone change), hand cards to discard
   - Modifiers: move from in_play to discard

3. Handle non-technique actions:
   - Footwork/utility cards: no technique, just apply effects
   - Resolution skips damage if no technique present

**Test:** Full combat loop with technique + modifiers.

### Phase 5: Draw and UI

**Files:** `apply.zig`, `views/combat.zig`

1. `shuffleAndDraw()` now draws modifiers (deck_cards contains modifiers)
2. Render technique pool separately from hand
3. Visual feedback for modifier attachment

### Phase 6: Polish

- AI director updates for technique selection
- Commit phase Focus commands with new semantics
- Test coverage for modifier combinations

---

## Critical Files

| File | Changes |
|------|---------|
| `src/domain/cards.zig` | ModifierEffects, .modifier Kind, Template field |
| `src/domain/card_list.zig` | Modifier templates, BaseTechniques array |
| `src/domain/combat.zig` | Play struct refactor, computed methods |
| `src/domain/apply.zig` | New commands, validation, cost application |
| `src/domain/tick.zig` | commitPlayerCards uses computed modifiers |
| `src/domain/world.zig` | Populate techniques_known, deck_cards |
| `src/domain/commands.zig` | New command variants |

---

## Design Decisions (Clarified)

1. **Modifiers can't be standalone** - they always attach to a primary action.

2. **Conflicting overrides disallowed** - can't attach two height modifiers to same play. Validation prevents it.

3. **Same modifier stacks multiplicatively** - two Committed = +2 stakes, two High = 1.44x damage. Encourages specialization.

4. **No detaching once played** - simplifies state management. If playtesting needs it, add later.

---

## Architectural Considerations (Future Scope)

### Multiple Simultaneous Plays

Footwork and offhand actions are **separate plays** that execute simultaneously with technique plays, not modifiers. Example turn:
```
Play 1: Thrust (technique) + High + Committed (modifiers)
Play 2: Sidestep (maneuver) + Press (modifier)
Play 3: Draw dagger (offhand action)
```

**Current Play array supports this** - `TurnState.plays_buf[8]` allows multiple plays per turn. The question is:
- How to mark plays as simultaneous vs sequential?
- How exclusivity constraints interact

`cards.Exclusivity` defines resource slots: `weapon`, `primary`, `hand`, `arms`, `footwork`, `concentration`. Simultaneous plays allowed if they use different slots (e.g., weapon attack + footwork maneuver)

**Deferred:** Current scope treats all plays as sequential. Simultaneous execution is future work.

### Rider/Target Relationships

Some cards need a target card: "Draw weapon" → which weapon from inventory?

This is distinct from modifiers - it's a **targeting relationship**, not enhancement.

**Possible approach:** `Play.target: ?ID` field for rider cards.

**Deferred:** Out of scope for initial implementation.

### Virtual Draw Piles

Pre-commitment via offensive/defensive/restorative piles:
```
Turn start: "Draw 2 offensive, 1 defensive, 1 utility"
Player gets: [High, Committed] + [Block bonus] + [Recover]
```

**Deferred:** Requires deck restructuring, out of scope.

---

## Scope Decision

### MVP (This Implementation)

- Techniques always available from pool
- Modifiers dealt from single deck
- Play = one action + modifier stack
- Multiplicative stacking, conflict prevention
- Sequential play resolution

### Deferred

- Simultaneous plays (footwork + technique)
- Rider/target card relationships
- Virtual draw piles (offensive/defensive/restorative)
- Cooldowns on always-available techniques

---

## Initial Modifier Set (Minimal)

| Card | Focus | cost_mult | damage_mult | stakes_delta | height | advantage |
|------|-------|-----------|-------------|--------------|--------|-----------|
| High | 0 | 1.0 | 1.2 | - | .high | - |
| Low | 0 | 0.8 | 0.9 | - | .low | - |
| Committed | 0 | 1.0 | 1.15 | +1 | - | - |
| Feint | 1 | 0.5 | 0.0 | - | - | favorable |

Notes:
- Feint costs 1F to attach (representing the mental cost of deception)
- All modifiers have stamina cost 0 (cost comes from technique)
- During commit phase: attach modifier costs 1F (first only), Feint adds another 1F from template

Future modifiers: Guarded, Reckless, Press, Withdraw, Offhand, Recovery, Reactions.
