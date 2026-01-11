# Contested Roll Event Instrumentation

**Goal:** Instrument contested roll calculations with detailed events so combat logs can show all mathematical components for tuning.

**Date:** 2026-01-11

---

## Design Decisions

- **Detail level:** Full breakdown - every component (base, technique, weapon, stakes, engagement, balance, conditions, stance) shown separately
- **Presentation:** Summary in sidebar combat log; full detail in console via `std.debug.print`
- **Event strategy:** New `contested_roll_resolved` event; skip `technique_resolved` when in contested mode
- **Manoeuvres:** Separate - can adopt similar pattern later if needed
- **Console formatter location:** In `contested.zig`, called from event processor

---

## Data Structures

### AttackBreakdown

```zig
pub const AttackBreakdown = struct {
    base: f32,
    technique: f32,      // negative = difficulty penalty
    weapon: f32,
    stakes: f32,
    engagement: f32,
    balance: f32,
    condition_mult: f32,
    stance_mult: f32,
    roll: f32,

    pub fn raw(self: AttackBreakdown) f32 {
        return self.base + self.technique + self.weapon +
               self.stakes + self.engagement + self.balance;
    }

    pub fn final(self: AttackBreakdown) f32 {
        return (self.raw() + self.roll) * self.condition_mult * self.stance_mult;
    }
};
```

### DefenseBreakdown

```zig
pub const DefenseBreakdown = struct {
    base: f32,
    technique: f32,
    weapon_parry: f32,
    parry_scaling: f32,  // 1.0 active, 0.5 passive, 0.25 attacking
    balance: f32,
    condition_mult: f32,
    stance_mult: f32,
    roll: f32,

    pub fn raw(self: DefenseBreakdown) f32 {
        return self.base + self.technique +
               (self.weapon_parry * self.parry_scaling) + self.balance;
    }

    pub fn final(self: DefenseBreakdown) f32 {
        return (self.raw() + self.roll) * self.condition_mult * self.stance_mult;
    }
};
```

### Updated ContestedResult

```zig
pub const ContestedResult = struct {
    attack: AttackBreakdown,
    defense: DefenseBreakdown,
    margin: f32,
    outcome_type: OutcomeType,
    damage_mult: f32,

    pub const OutcomeType = enum {
        critical_hit,
        solid_hit,
        partial_hit,
        miss,
    };
};
```

---

## Event Structure

In `events.zig`:

```zig
contested_roll_resolved: struct {
    attacker_id: entity.ID,
    defender_id: entity.ID,
    technique_id: cards.TechniqueID,
    weapon_name: []const u8,
    attack: resolution.contested.AttackBreakdown,
    defense: resolution.contested.DefenseBreakdown,
    margin: f32,
    outcome_type: resolution.contested.ContestedResult.OutcomeType,
    damage_mult: f32,
},
```

---

## Console Output Format

```
── Contested Roll ─────────────────────────
  You vs Goblin (slash)

  ATTACK  [1.23]
    base +0.50 | tech -0.10 | weapon +0.15
    stakes +0.00 | engage +0.05 | balance +0.00
    × cond 1.00 × stance 1.20 + roll 0.45

  DEFENSE [0.98]
    base +0.50 | tech +0.00 | parry +0.30 (×0.50)
    balance -0.05
    × cond 1.00 × stance 0.80 + roll 0.38

  MARGIN +0.25 → solid_hit (×1.00 dmg)
───────────────────────────────────────────
```

---

## Sidebar Format

Concise single line:
```
You slash Goblin: hit (+0.18)
```

Outcome strings: `CRIT`, `hit`, `graze`, `miss`

---

## Implementation Tasks

### Task 1: Add breakdown structs to contested.zig
- Add `AttackBreakdown` and `DefenseBreakdown` structs with `raw()` and `final()` methods
- Update `ContestedResult` to use breakdown structs

### Task 2: Refactor score calculation functions
- `calculateAttackScore` returns `AttackBreakdown` instead of `f32`
- `calculateDefenseScore` returns `DefenseBreakdown` instead of `f32`
- Update `resolveContested` to use breakdowns

### Task 3: Add event type
- Add `contested_roll_resolved` to `events.zig` Event union
- Import necessary types from resolution module

### Task 4: Emit event from outcome.zig
- Emit `contested_roll_resolved` in `resolveOutcomeContested`
- Skip `technique_resolved` emission when `contested_roll_mode != .single`

### Task 5: Add console formatter
- Add `formatForConsole` function to `contested.zig`
- Handle `contested_roll_resolved` in `event_processor.zig` switch

### Task 6: Add combat log formatting
- Handle `contested_roll_resolved` in `combat_log.zig` format function
- Summary line with outcome and margin

### Task 7: Test and verify
- Run `just check`
- Manual playtest to verify console and sidebar output

---

## Files Changed

| File | Change |
|------|--------|
| `src/domain/resolution/contested.zig` | Add breakdown structs, refactor calculations, add `formatForConsole` |
| `src/domain/events.zig` | Add `contested_roll_resolved` event |
| `src/domain/resolution/outcome.zig` | Emit new event, conditionally skip `technique_resolved` |
| `src/domain/apply/event_processor.zig` | Handle new event, call formatter |
| `src/presentation/combat_log.zig` | Format new event for sidebar |
