# T029: Ranged Attack Resolution
Created: 2026-01-09

## Problem statement / value driver

Thrown attacks validate correctly (card shows playable when target in range) but don't resolve - no damage, no combat events. First ranged weapon in game (fist stone) needs working attack pipeline.

## Background

### What's working

- `fist_stone` weapon with swing (melee) and thrown (ranged) profiles
- `throw` technique (TechniqueID, TechniqueEntries, attack_mode = .ranged)
- `t_throw` card in BaseAlwaysAvailableTemplates
- Target validation in `isValidTargetForExpression()` - checks `engagement.range <= weapon.thrown.range`
- `Ranged` changed to `union(enum)` for switching
- `getWeaponOffensive()` in damage.zig handles `.ranged` attack mode

### What's broken

Committing a throw attack produces no combat resolution. Melee (slash with same weapon) works fine.

### Key files

- `src/domain/resolution/damage.zig` - `getWeaponOffensive()`, `createDamagePacket()`
- `src/domain/tick/resolver.zig` - `resolveCommittedAction()`, offensive mode checks
- `src/domain/resolution/outcome.zig` - `resolveTechniqueVsDefense()`
- `src/domain/combat/armament.zig` - `getRangedMode()` (new)
- `src/domain/apply/targeting.zig` - validation (fixed)

### Likely culprits

1. **resolver.zig** - may skip ranged techniques or fail to get weapon mode
2. **createDamagePacket** - may not handle ranged damage types properly
3. **Missing events** - technique_resolved event not emitted for ranged

## Tasks / Sequence of Work

1. Trace throw attack through resolver - find where it bails out
2. Fix offensive mode lookup for ranged attacks in resolver
3. Ensure damage packet creation works for thrown weapons
4. Verify events emitted (technique_resolved, damage_applied)
5. Test end-to-end: throw stone at goblin, observe damage

## Test / Verification Strategy

### Integration tests

- [ ] Throw attack resolves and emits technique_resolved event
- [ ] Throw attack applies damage to target
- [ ] Thrown weapon uses correct offensive profile (fist_stone_throw, not swing)

### User acceptance

- [ ] Commit throw card, see combat log entry
- [ ] Target takes damage from thrown rock

## Progress Log / Notes

### 2026-01-09 - Initial setup

Added throw technique and card. Fixed validation (was checking melee reach for all attacks). Validation now passes but resolution silent.

Changes made:
- `TechniqueID.throw` added to cards.zig
- `Ranged` union changed to `union(enum)` in weapon.zig
- `getWeaponOffensive()` handles `.ranged` → extracts `thrown.throw` Offensive
- `getRangedMode()` added to Armament
- `isValidTargetForExpression()` branches on attack_mode for range checking

### 2026-01-09 - Resolution fixed - COMPLETE

**Root cause**: `TickResolver.resolve()` had a switch on attack_mode that returned `null` for `.ranged`, causing the attack to silently skip.

**Fix**: Added explicit `.ranged` branch in resolver (lines 191-208) that:
1. Gets ranged profile from weapon template
2. Extracts max range from thrown/projectile
3. Checks `engagement.range <= max_range`
4. Allows attack to proceed to `resolveTechniqueVsDefense()`

The existing `getWeaponOffensive()` in damage.zig already handled extracting the `Offensive` profile from thrown weapons, so damage calculation worked once the resolver stopped bailing out.

**Verified**: Threw rock at goblin, hit on second throw, head shattered.
