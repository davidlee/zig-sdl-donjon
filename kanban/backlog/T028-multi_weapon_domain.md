# T028: Multi-Weapon Domain Support
Created: 2026-01-08

## Problem statement / value driver

Domain layer doesn't support weapon selection per play. Techniques are locked to their template's channel, preventing dual-wielding and natural weapon use.

**Blocks**: T027 (Draggable Card Plays)

### Scope - goals

- `Play.channel_override` - allow technique to use different weapon slot
- `move_play` command - reposition plays on timeline (time and/or channel)
- `weaponForChannel()` - resolve which weapon (equipped or natural) serves a channel
- Validation: channel override only between weapon-type channels with weapons equipped
- Range awareness: different weapons have different ranges

### Scope - non-goals

- UI changes (T027)
- Mid-tick armament changes (future)
- Commit phase reorder rules (existing Focus cost system)

## Background

### Relevant documents

- `doc/issues/multi_weapon_combat.md` - original design debt
- `doc/artefacts/draggable_plays_design.md` - full design including UI

### Key files

- `src/domain/combat/plays.zig` - Play, TurnState, getPlayChannels
- `src/domain/combat/agent.zig` - allAvailableWeapons(), WeaponRef
- `src/domain/cards.zig` - ChannelSet
- `src/commands.zig` - Command enum
- `src/domain/apply/command_handler.zig` - command handlers
- `src/domain/tick/resolver.zig` - **getWeaponTemplate() is hardcoded!**
- `src/domain/tick/committed_action.zig` - CommittedAction struct
- `src/domain/resolution/context.zig` - AttackContext.weapon_template

### Existing systems

- `ChannelSet`: weapon, off_hand, footwork, concentration
- `getPlayChannels()`: derives channels from card template
- `allAvailableWeapons()`: yields equipped + natural weapons
- `Timeline.canInsert()`: validates time+channel no-overlap
- `TurnState.addPlayAt()`: exists but unused

### Critical finding (audit 2026-01-08)

**Weapon selection is hardcoded!**

```zig
// src/domain/tick/resolver.zig:305
fn getWeaponTemplate(self: *TickResolver, agent: *Agent) *const weapon.Template {
    // TODO: get from agent's equipped weapon
    // For now, use knight's sword as default
    return &weapon_list.knights_sword;
}
```

Resolution layer doesn't use agent's actual weapon. This is the core bug.

**Data flow**:
1. `Play` → `CommittedAction` (loses channel info)
2. `CommittedAction` → `AttackContext` (weapon hardcoded)
3. `AttackContext` → `resolveTechniqueVsDefense`

## Changes Required

### 1. Play.channel_override

```zig
pub const Play = struct {
    action: entity.ID,
    target: ?entity.ID = null,
    channel_override: ?cards.ChannelSet = null,  // NEW
    // ...
};
```

Update `getPlayChannels()` to respect override.

### 2. move_play command

```zig
move_play: struct {
    card_id: ID,
    new_time_start: f32,
    new_channel: ?cards.ChannelSet = null,
},
```

Handler: find play, remove, validate new position, insert.

### 3. weaponForChannel helper

```zig
pub fn weaponForChannel(self: *const Agent, channel: ChannelSet) ?WeaponRef {
    // Check equipped first, then natural weapons
    // Return weapon that matches the channel
}
```

### 4. Fix CommittedAction / Resolver

**Option A**: Store resolved weapon on CommittedAction during commit phase:
```zig
pub const CommittedAction = struct {
    // existing fields...
    weapon_template: ?*const weapon.Template = null,  // NEW - resolved during commit
};
```

**Option B**: Store channel on CommittedAction, resolve weapon in resolver:
```zig
pub const CommittedAction = struct {
    // existing fields...
    channel: cards.ChannelSet,  // NEW
};
```

Option A is cleaner - resolve once during commit, use in resolution.

### 5. Fix TickResolver.getWeaponTemplate

Replace hardcoded weapon with actual lookup:
```zig
fn getWeaponForAction(self: *TickResolver, action: *const CommittedAction) ?*const weapon.Template {
    return action.weapon_template;  // already resolved during commit
}
```

### 6. Validation rules

- Channel override only for weapon-type channels (weapon ↔ off_hand)
- Target channel must have weapon available (equipped or natural)
- Footwork/concentration channels not switchable

## Tasks / Sequence of Work

1. Add `weaponForChannel()` to Agent (foundation)
2. Add `channel_override` to Play
3. Update `getPlayChannels()` to use override
4. Add `weapon_template` to CommittedAction
5. Update commit phase to resolve weapon → CommittedAction
6. Fix `TickResolver.getWeaponTemplate` to use resolved weapon
7. Add `move_play` command + handler
8. Validation for channel switch
9. Tests for all above

## Test / Verification Strategy

### Unit tests - weaponForChannel

- [ ] Returns equipped weapon for weapon channel
- [ ] Returns equipped off-hand weapon for off_hand channel
- [ ] Returns natural weapon when no equipped weapon
- [ ] Returns null for off_hand with 2h weapon equipped
- [ ] Prioritizes equipped over natural

### Unit tests - Play/channels

- [ ] Play with channel_override uses override in getPlayChannels
- [ ] Play without override uses template channels

### Unit tests - CommittedAction

- [ ] weapon_template populated during commit
- [ ] Correct weapon resolved for weapon channel
- [ ] Correct weapon resolved for off_hand channel

### Unit tests - move_play command

- [ ] Repositions in time (same channel)
- [ ] Changes channel (weapon → off_hand)
- [ ] Rejects invalid channel switch (footwork→weapon)
- [ ] Rejects switch to channel without weapon
- [ ] Rejects move to conflicting time slot

### Integration tests

- [ ] Technique resolves with equipped sword (not hardcoded)
- [ ] Technique resolves with natural weapon when unarmed
- [ ] Dual-wield: main hand attack uses main weapon
- [ ] Dual-wield: off-hand attack uses off-hand weapon

## Progress Log / Notes

### 2026-01-08 - Impact audit

Traced code paths to understand full scope:

1. **getPlayChannels** called by: `canInsert`, `channelsOccupiedAt`, `hasFootworkInTimeline`, `addPlay`, `addPlayAt`, UI `buildPlayViewData` - all internal, should work with override

2. **Play struct** used in: resolution/context, apply/effects (resolve, commit, manoeuvre, positioning), targeting, validation, event_processor - accesses `.action`, `.target`, `.modifiers()` but not channels directly

3. **CommittedAction** built from Play in commit phase, lacks channel/weapon info

4. **Critical**: `TickResolver.getWeaponTemplate()` hardcoded to knight's sword

5. **CommittedAction built in**: `TickResolver.commitPlayerCards()` and `commitSingleMob()` - these iterate over `enc_state.current.slots()` and build CommittedAction from each Play

**Recommendation**: Store `weapon_template` on CommittedAction during commit phase in `commitPlayerCards/commitSingleMob`. Cleaner than passing channel and resolving in resolver.

### 2026-01-08 - Core implementation complete

Implemented the core weapon resolution pipeline:

1. **`Agent.weaponForChannel()`** - Added to `agent.zig:551-570`
   - Returns equipped weapon for `.weapon` channel (primary)
   - Returns equipped weapon for `.off_hand` channel (secondary in dual-wield)
   - Falls back to natural weapon when unarmed
   - Unit tests added

2. **`Play.channel_override`** - Added field to Play struct
   - Allows technique to use different weapon slot than template default
   - `getPlayChannels()` respects override (early return if set)
   - Unit test added

3. **`CommittedAction.weapon_template`** - Added field
   - Stores resolved weapon during commit phase
   - Set in `commitPlayerCards()` and `commitSingleMob()`

4. **Fixed `TickResolver.getWeaponTemplate()`**
   - Now queries agent's primary weapon via `weaponForChannel`
   - Falls back to knight's sword for unarmed (temporary)
   - AttackContext uses `action.weapon_template orelse getWeaponTemplate(actor)`

**Not yet implemented:**
- `move_play` command + handler (step 7)
- Validation for channel switch (step 8)

### 2026-01-09 - Integration tests + event enrichment

1. **Added `weapon_name` to `technique_resolved` event** (`events.zig:128`)
   - Combat logs can now show weapon used in attacks
   - Populated from `AttackContext.weapon_template.name` in `outcome.zig`

2. **Added `Harness.getResolvedWeaponName()`** (`harness.zig:399-412`)
   - Test helper to extract weapon from technique_resolved events

3. **Integration tests** (`weapon_resolution.zig`)
   - ✅ Technique resolves with equipped weapon (not hardcoded)
   - ✅ Dual-wield main hand attack uses primary weapon
   - ⏳ Natural weapon when unarmed - skipped, needs investigation

**Ready for handover. Remaining work:**
- `move_play` command for repositioning plays on timeline
- Validation for channel switch (weapon↔off_hand only)
- Fix natural weapon integration test

### Debug notes: unarmed integration test - ROOT CAUSE FOUND

**The bug is at `resolver.zig:190`:**
```zig
const weapon_mode = action.actor.weapons.getOffensiveMode(attack_mode);
if (weapon_mode) |wm| {
    // ... range check
} else {
    // No weapon for this attack mode - can't attack
    continue;  // <-- SILENTLY SKIPS THE ATTACK
}
```

`Armament.getOffensiveMode()` only checks EQUIPPED weapons, not natural weapons. When unarmed:
- `getOffensiveMode()` returns null
- The attack is silently skipped (no event emitted)

**Fix options:**
1. Update `Armament.getOffensiveMode()` to fall back to natural weapons
2. Or use `action.weapon_template` (already resolved during commit) instead of querying armament
3. Emit an event when attack is skipped due to no weapon mode (for debugging)

**Preferred fix:** Option 2 - we already resolved the weapon during commit, use it:
```zig
// In resolver.resolve(), replace getOffensiveMode call:
const weapon_mode = if (action.weapon_template) |wt|
    switch (attack_mode) {
        .swing => wt.swing,
        .thrust => wt.thrust,
        else => null,
    }
else null;
```

This aligns with T028's goal: weapon is resolved during commit, used during resolve.

