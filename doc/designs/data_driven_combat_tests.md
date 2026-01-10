# Design: Data-Driven Combat Testing

**Goal**: Validate the complex 3-axis damage model and outcome resolution logic using declarative, data-driven scenarios. This ensures that "a sword hitting plate armour" behaves as designed without hard-coding brittle assumptions into unit tests.

## 1. Concept

We will define combat scenarios in CUE (`data/tests.cue`), generate them into a Zig struct, and execute them using a specialized test runner that leverages the Integration Harness.

### Use Cases
*   **Tuning**: Tweaking weapon energy or armour absorption in CUE and immediately seeing if it breaks expected outcomes (e.g., "Dagger should no longer penetrate Plate").
*   **Regression**: Ensuring that refactors (like the 3-axis migration) don't silently change damage values.
*   **Coverage**: Rapidly defining a matrix of Weapon x Armour interactions.

## 2. Data Schema (`data/tests.cue`)

We define a `#CombatTest` schema that describes a single interaction.

```cue
#CombatTest: {
    id: string
    description: string
    
    attacker: {
        species: "dwarf" | "goblin" | ...
        stats: { power: float | *5.0, speed: float | *5.0, ... }
        weapon: string // ID from weapons.cue
        technique: string // ID from techniques.cue
        stakes: "probing" | "guarded" | "committed" | "reckless" | *"committed"
    }

    defender: {
        species: "dwarf" | "goblin" | ...
        stats: { ... }
        armour: [...string] // IDs from armour.cue (e.g. ["gambeson", "chainmail"])
        pose: "balanced" | "off_balance" | *"balanced"
    }

    expected: {
        // Assertions (all optional, checked if present)
        outcome?: "hit" | "miss" | "glance" | "bounce" | "shatter"
        
        // Damage packet checks (pre-mitigation)
        packet_energy_min?: float
        packet_geometry_min?: float

        // Resolution checks (post-mitigation)
        damage_dealt_min?: float
        damage_dealt_max?: float
        
        // Wound checks
        target_part?: string // e.g. "torso"
        wound_severity?: "none" | "minor" | "inhibited" | "disabled" | "broken" | "missing"
    }
}

tests: {
    sword_vs_plate: #CombatTest & {
        description: "Knight's sword slash should glance off plate"
        attacker: {
            weapon: "swords.knights_sword"
            technique: "swing"
        }
        defender: {
            armour: ["armour.plate_cuirass"]
        }
        expected: {
            outcome: "glance"
            damage_dealt_max: 0.5 // Minimal bruising
        }
    }
}
```

## 3. Pipeline Integration

1.  **Source**: `data/tests.cue` imports `weapons.cue`, `armour.cue`, etc. to validate IDs.
2.  **Generator**: Update `scripts/cue_to_zig.py`:
    *   Add handler for `tests` root key.
    *   Emit `pub const CombatTestDefinition = struct { ... }`.
    *   Emit `pub const GeneratedCombatTests = [_]CombatTestDefinition{ ... }`.
    *   Output file: `src/gen/test_data.zig` (or appended to `generated_data.zig`).

## 4. Zig Test Runner (`src/testing/data_driven.zig`)

This module will iterate over `GeneratedCombatTests` and execute them.

```zig
test "data driven combat tests" {
    for (gen.GeneratedCombatTests) |test_def| {
        // 1. Setup Harness
        var h = try Harness.init(alloc);
        defer h.deinit();

        // 2. Configure Attacker (Player)
        try h.setPlayerFromSpec(test_def.attacker);
        
        // 3. Configure Defender (Enemy)
        const enemy = try h.addEnemyFromSpec(test_def.defender);

        // 4. Force specific engagement parameters if needed
        // (e.g. range, balance)

        // 5. Execute Attack
        // Use a specialized "forceAttack" helper in Harness that bypasses 
        // card selection UI and directly invokes resolution.
        const result = try h.forceResolveAttack(
            h.player(), 
            enemy, 
            test_def.attacker.technique_id,
            test_def.attacker.stakes
        );

        // 6. Assertions
        if (test_def.expected.outcome) |exp| {
            try testing.expectEqual(exp, result.outcome);
        }
        if (test_def.expected.damage_dealt_min) |min| {
            try testing.expect(result.damage >= min);
        }
        // ... etc
    }
}
```

### Harness Extensions
We need to extend `Harness` to support "Spec-based" setup (mapping string IDs to runtime assets) and "Forced Resolution" (skipping the game loop for direct logic testing).

*   `setPlayerFromSpec(spec)`: Looks up weapon ID -> Template -> Equip.
*   `forceResolveAttack(...)`: Calls `domain.resolution.outcome.resolveTechniqueVsDefense` directly, constructing contexts manually. This avoids the overhead of the full turn loop when we just want to test physics.

## 5. Implementation Plan

1.  **Schema**: Create `data/tests.cue`.
2.  **Generator**: Update `scripts/cue_to_zig.py`.
3.  **Harness**: Add `forceResolveAttack` to `src/testing/integration/harness.zig`.
4.  **Runner**: Create `src/testing/data_driven_runner.zig` and wire it into `src/main.zig`.
5.  **Pilot**: Add the "Sword vs Plate" test case and verify it fails (due to the unit mismatch bug) or passes (once fixed).

## 6. Benefits for Tuning
This system allows us to "calibrate" the game. We can write a test:
*   `dagger_vs_eye`: Expect `severity: missing`.
*   `dagger_vs_plate`: Expect `damage: 0`.

If a refactor breaks `dagger_vs_eye`, we know we broke lethality. If it breaks `dagger_vs_plate`, we broke armour.
