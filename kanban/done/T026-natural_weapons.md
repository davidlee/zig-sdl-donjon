# T026: Natural Weapons in Armament
Created: 2026-01-08

## Problem statement / value driver

With Species defined (T023), natural weapons need to integrate into combat. They should be available alongside equipped weapons, but gated by body part integrity (no hand = no punch).

### Scope - goals

- Add `.natural` slots to Armament
- Populate natural slots from Agent.species at init/combat start
- Gate availability on body part state
- Expose unified weapon iteration for combat resolution

### Scope - non-goals

- New combat mechanics using natural weapons
- AI weapon selection logic changes
- Natural weapon damage tuning

## Background

### Relevant documents

- `doc/artefacts/species_design.md` - Armament integration section

### Key files

- `src/domain/combat/armament.zig` - Armament struct
- `src/domain/combat/agent.zig` - Agent.weapons, Agent.body
- `src/domain/body.zig` - Part, PartTag, severity
- `src/domain/species.zig` (T023)

### Existing systems, memories, research, design intent

From design doc:
> Natural weapons merge into Armament with `.natural` slots, populated from species at agent init. Keeps combat resolution unified.
> Natural weapons are gated by body state: no jaw = no bite, no hand = no punch.

## Changes Required

### 1. Body part functional check (reusable)

Add to Body - reusable by conditions, targeting, natural weapon gating:

```zig
pub fn hasFunctionalPart(self: *const Body, tag: PartTag, side: ?Side) bool {
    for (self.parts.items) |part, i| {
        if (part.tag != tag) continue;
        if (side) |s| if (part.side != s) continue;
        const idx: PartIndex = @intCast(i);
        if (!self.isEffectivelySevered(idx) and part.severity != .missing) {
            return true;
        }
    }
    return false;
}
```

The `side` parameter enables future per-side control. Pass `null` for "any functional part with this tag".

### 2. Fixture utility for body damage

Integration tests need to damage specific parts. Add to testing fixtures:

```zig
pub fn damagePartToSeverity(body: *Body, tag: PartTag, severity: Severity) !void {
    // Find part by tag, set severity directly (test utility, not combat simulation)
}
```

### 3. AgentTemplate holds Species reference

Currently `AgentTemplate` holds `body_plan`. Cleaner to hold `*const Species`:

```zig
// Before
body_plan: []const body.PartDef,

// After
species: *const species_mod.Species,
```

Body plan and natural weapons both come from species.

### 4. Agent.init takes species, derives body + resources + natural weapons

Break the init API once - remove body, resources, and armament parameters:

```zig
// Before (10 params)
pub fn init(alloc, slot_map, dr, ds, stat_block, body, stamina, focus, blood, armament)

// After (6 params)
pub fn init(
    alloc: std.mem.Allocator,
    slot_map: *SlotMap(*Agent),
    director: Director,
    draw_style: DrawStyle,
    species: *const Species,
    stat_block: stats.Block,
) !*Agent {
    const bd = try body.Body.fromPlan(alloc, species.body_plan);
    // weapons starts unarmed + natural
    // resources derived from species bases with default recovery
}
```

**Derived from species:**
- `body` from `species.body_plan`
- `weapons.natural` from `species.natural_weapons`
- `stamina` from `species.base_stamina` (with default recovery ~0.5/turn)
- `focus` from `species.base_focus` (with default recovery ~0.3/turn)
- `blood` from `species.base_blood` (no recovery)

**Still passed in:**
- `stat_block` - individual variation (strength, agility, etc.)
- `director`, `draw_style` - behavioural

**Set after init if needed:**
- Equipped weapons via `agent.weapons = agent.weapons.withEquipped(...)`
- Custom resource recovery rates
- Individual stat overrides

This requires updating all Agent.init call sites.

### 5. Restructure Armament (pure data, no back-reference)

Armament becomes a struct with both equipped and natural weapons. **No back-reference to Agent/Body** - keeps Armament testable in isolation:

```zig
pub const Armament = struct {
    equipped: Equipped,
    natural: []const NaturalWeapon,  // from species, immutable

    pub const Equipped = union(enum) {
        unarmed,  // NEW: no equipped weapon, uses natural weapons only
        single: *weapon.Instance,
        dual: struct { primary: *weapon.Instance, secondary: *weapon.Instance },
        compound: [][]*weapon.Instance,
    };

    /// Create Armament with natural weapons only (unarmed).
    pub fn fromSpecies(natural_weapons: []const NaturalWeapon) Armament {
        return .{ .equipped = .unarmed, .natural = natural_weapons };
    }

    /// Create new Armament with different equipped weapons, preserving natural.
    pub fn withEquipped(self: Armament, new_equipped: Equipped) Armament {
        return .{
            .equipped = new_equipped,
            .natural = self.natural,
        };
    }

    // Existing category/mode helpers updated to work with .equipped field
};
```

### 6. Populate natural weapons from species

At Agent.init, populate `armament.natural` from `species.natural_weapons`.

### 7. Availability logic on Agent (not Armament)

Agent has access to both `weapons` and `body`, so filtering logic lives here:

```zig
pub fn availableNaturalWeapons(self: *const Agent) NaturalWeaponIterator {
    return NaturalWeaponIterator.init(self.weapons.natural, &self.body);
}

pub fn allAvailableWeapons(self: *const Agent) AllWeaponsIterator {
    // yields equipped + filtered natural
}
```

This avoids coupling Armament to Agent/Body.

## Design Decisions

### "Any functional" for symmetric parts

For `PartTag` like `.hand` that maps to multiple parts (left/right), we use "any functional" semantics - if either hand works, the agent can punch.

The `side: ?Side` parameter on `hasFunctionalPart` allows future per-side control if species define side-specific natural weapons (e.g., "right claw" vs "left claw"). For now, natural weapons pass `null` for side.

### No back-reference in Armament

Armament stays pure data. Availability filtering happens on Agent, which already holds both `weapons` and `body`. This keeps Armament testable in isolation and avoids tightening coupling.

### Immutable natural weapons slice

Natural weapons are stored as `[]const NaturalWeapon` (immutable slice from species).

**Known limitation**: If species changes mid-combat (polymorph/transform effects), the Armament must be rebuilt. This is acceptable - transform effects would need to rebuild Armament anyway to update natural weapons. Document this if transform effects are added later.

## Tasks / Sequence of Work

1. [x] **Add `Body.hasFunctionalPart(tag, side?)`** + unit tests
2. [x] **Add fixture utility for body damage** (setPartSeverity, severPart)
3. [x] **Restructure Armament** → struct with `equipped: Equipped` + `natural: []const NaturalWeapon`
   - Add `.unarmed` variant to Equipped union
   - Add `fromSpecies()` constructor
   - Add `withEquipped()` convenience
   - Update existing helpers (hasCategory, getOffensiveMode) to use `.equipped`
4. [x] **Refactor AgentTemplate** → hold `*const Species` instead of `body_plan`
5. [x] **Refactor Agent.init** → simplified signature (species + stat_block)
   - Remove: body, stamina, focus, blood, armament params
   - Derive body from species.body_plan
   - Derive resources from species bases (with recovery from species or global defaults)
   - Derive weapons via Armament.fromSpecies(species.natural_weapons)
6. [x] **Update all Agent.init call sites**
   - fixtures.agentFromTemplate → use withEquipped() for weapons
   - player.newPlayer → takes species instead of body
   - harness.setupEncounter → uses GOBLIN species
   - encounter tests, resolution tests (context.zig, damage.zig, outcome.zig)
   - integration/harness.zig - addEnemyFromTemplate, setPlayerFromTemplate
   - positioning.zig tests
7. [x] **Add `Agent.availableNaturalWeapons()`** iterator with body gating
8. [x] **Add `Agent.allAvailableWeapons()`** unified iterator
9. [~] **Integration tests** - unit tests cover body gating thoroughly; integration deferred
10. [~] **Performance check** - not on hot path currently; deferred

## Test / Verification Strategy

### success criteria / ACs

- Natural weapons appear in available weapons when body parts functional
- Natural weapons disappear when required part destroyed
- Combat resolution can iterate all weapons uniformly
- `just check` passes

### unit tests

- `hasFunctionalPart` with healthy/damaged/missing parts, with and without side filter
- `availableNaturalWeapons` filters correctly based on body state
- `allAvailableWeapons` includes both equipped and available natural
- `Armament.withEquipped` preserves natural weapons

### integration tests

Use `src/testing/integration/` harness:
- Agent with species fights using natural weapons
- Destroying required part removes natural weapon from available weapons
- Combat snapshot reflects natural weapon availability

Requires new fixture utility to damage parts to specific severity.

## Quality Concerns / Risks / Potential Future Improvements

- **Performance**: Weapon iteration merges collections and does body lookups. If hot path, consider caching available natural weapons on body state change.
- **Side-specific natural weapons**: Current design supports via `side` parameter but not yet used. Add when species need it.
- **Transform effects**: Rebuilding Armament on species change is the path forward. Document when implementing transforms.
- **Natural weapon techniques**: Future cards can reference natural weapons for special attacks.

## Progress Log / Notes

- 2026-01-08: Task created from species_design.md
- 2026-01-08: Expanded scope - Agent should derive body from species, not take as argument. Armament needs equipped/natural separation with convenience methods.
- 2026-01-08: **Design revision** after review:
  - Removed back-reference from Armament (coupling concern)
  - Body gets `hasFunctionalPart(tag, side?)` - reusable by conditions/targeting
  - Availability logic moves to Agent (has both weapons and body)
  - Added fixture utility for body damage (test dependency)
  - Documented "any functional" decision and transform limitation
  - Resequenced: body helper first, then fixtures, then Agent refactor
- Depends on: T023 (Species Foundation) ✓

### Session 1 Progress (2026-01-08)

**Completed:**
1. ✅ `Body.hasFunctionalPart(tag, side?)` - added to body.zig:510 with 4 unit tests
2. ✅ Fixture utilities - `setPartSeverity()` and `severPart()` in fixtures.zig with 3 tests
3. ✅ Wired testing/mod.zig into main.zig test block (gotcha documented in testing_conventions memory)
4. ✅ Armament restructured:
   - Changed from `union` to `struct { equipped: Equipped, natural: []const NaturalWeapon }`
   - Added `.unarmed` variant to `Equipped`
   - Added `fromSpecies()` and `withEquipped()` methods
   - Updated all call sites (~10 files): player.zig, harness.zig, agent.zig tests, fixtures.zig, positioning.zig, targeting.zig, validation.zig, integration/harness.zig
   - `makeTestAgent` helpers changed to take `Equipped` instead of `Armament`
5. ✅ AgentTemplate refactored:
   - Now holds `species: *const Species` instead of `body_plan`
   - Resource fields now optional (`?stats.Resource`) - null = derive from species
   - All personas updated to use species (DWARF, GOBLIN)
   - Fixtures updated to derive resources from species with default recovery rates

**Remaining:**
5. [ ] Agent.init signature change (species + stat_block only) - THE BIG ONE
   - Currently factories derive body/resources from species, then call old Agent.init
   - Need to move derivation INTO Agent.init, simplify signature
   - Call sites: ~10 files with Agent.init calls
6. [ ] Natural weapon iterators on Agent
7. [ ] Integration tests
8. [ ] Performance check

**Key files touched:**
- `src/domain/body.zig` - hasFunctionalPart
- `src/domain/combat/armament.zig` - major restructure
- `src/data/personas.zig` - AgentTemplate + all personas
- `src/testing/fixtures.zig` - agentFromTemplate + utilities
- `src/testing/integration/harness.zig` - addEnemyFromTemplate, setPlayerFromTemplate
- `src/domain/apply/effects/positioning.zig` - getPrimaryWeaponReach
- `src/domain/apply/targeting.zig` - makeTestAgent
- `src/domain/apply/validation.zig` - makeTestAgent

**All tests passing** - `just check` clean

**Open questions for next session:**
- Default resource recovery rates hardcoded in fixtures (stamina 2.0, focus 1.0, blood 0.0) - move to Species or keep as constants?
- Agent.species field currently defaults to `&DWARF` in struct definition - should be set explicitly in init
- When Agent.init takes species, should it also set `agent.species = species`? (currently not set)

### Session 2 Progress (2026-01-08)

**Resolved open questions:**
- Recovery rates: Global defaults in `species.zig` (DEFAULT_STAMINA_RECOVERY, etc.), Species can optionally override via `?f32` fields, individual variation applied post-init
- Agent.species: Now set explicitly in Agent.init from the species parameter

**Completed:**
1. ✅ Added optional recovery fields to Species (`stamina_recovery`, `focus_recovery`, `blood_recovery`)
   - Global defaults: stamina 2.0, focus 1.0, blood 0.0
   - Species can override; accessor methods use `orelse` for defaults
   - Unit tests for default and override behavior
2. ✅ Refactored Agent.init to simplified signature: `(alloc, slot_map, director, draw_style, species, stat_block)`
   - Derives body from species.body_plan
   - Derives resources from species bases + recovery rates
   - Derives armament via Armament.fromSpecies(species.natural_weapons)
   - Sets agent.species field
3. ✅ Updated all Agent.init call sites (~12 across 9 files)
   - fixtures.zig, player.zig, harness.zig, integration/harness.zig
   - encounter.zig, context.zig, damage.zig, outcome.zig, positioning.zig
4. ✅ Removed optional resource fields from AgentTemplate
   - All personas simplified (just species + base_stats + armament)
   - Updated test to verify resources derive from species
5. ✅ Added `Agent.availableNaturalWeapons()` iterator
   - Filters by body part availability via `hasFunctionalPart()`
   - 4 unit tests covering healthy, damaged, all destroyed cases
6. ✅ Added `Agent.allAvailableWeapons()` unified iterator
   - `WeaponRef` union distinguishes equipped vs natural
   - Yields equipped first (single/dual), then filtered natural
   - 4 unit tests covering unarmed, single, dual wield, WeaponRef.template()
7. ✅ Created `doc/issues/multi_weapon_combat.md` documenting technical debt around dual wielding, natural weapons in combat, ranged weapons, etc.

**Key decisions:**
- Recovery rates hierarchy: global defaults → species override → post-init individual variation
- `WeaponRef` union allows callers to distinguish equipped (has Instance state) from natural
- Skipped integration tests - unit tests thoroughly cover body gating logic
- Skipped performance check - weapon iteration not currently on hot path

**All acceptance criteria met:**
- ✅ Natural weapons appear in available weapons when body parts functional
- ✅ Natural weapons disappear when required part destroyed
- ✅ Combat resolution can iterate all weapons uniformly (via `allAvailableWeapons()`)
- ✅ `just check` passes

**Key files touched this session:**
- `src/domain/species.zig` - recovery rate fields + global defaults
- `src/domain/combat/agent.zig` - init refactor + weapon iterators
- `src/domain/player.zig` - signature change (species instead of body)
- `src/domain/world.zig` - player creation uses species
- `src/data/personas.zig` - removed resource fields from AgentTemplate + personas
- `src/testing/fixtures.zig` - simplified agentFromTemplate
- `src/testing/integration/harness.zig` - simplified addEnemyFromTemplate, setPlayerFromTemplate
- `src/harness.zig` - mobs use GOBLIN species
- `src/domain/combat/encounter.zig` - test helpers
- `src/domain/resolution/*.zig` - test helpers
- `src/domain/apply/effects/positioning.zig` - test helpers
- `doc/issues/multi_weapon_combat.md` - NEW: technical debt tracking
