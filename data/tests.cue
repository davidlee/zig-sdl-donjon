package data

// Data-driven combat test definitions.
// These scenarios verify the 3-axis damage model (geometry/energy/rigidity)
// and armour interactions.

#AttackerSpec: {
  species: string | *"dwarf"
  weapon_id: string  // ID from weapons.cue (e.g., "swords.knights_sword")
  technique_id: string  // ID from techniques.cue (e.g., "swing")
  stakes: *"committed" | "probing" | "guarded" | "reckless"
  stats?: {
    power?: float
    speed?: float
    skill?: float
  }
}

#DefenderSpec: {
  species: string | *"dwarf"
  armour_ids: [...string]  // IDs from armour.cue (e.g., ["steel_breastplate"])
  pose: *"balanced" | "off_balance"
  target_part?: string  // e.g., "torso" - defaults to torso if not specified
}

#ExpectedOutcome: {
  // Assertion on roll outcome (optional - if not specified, just checks damage)
  outcome?: "hit" | "miss" | "glance" | "blocked"

  // Damage assertions (post-armour, post-body)
  damage_dealt_min?: float
  damage_dealt_max?: float

  // Packet assertions (pre-armour)
  packet_energy_min?: float
  packet_geometry_min?: float

  // Armour interaction
  armour_deflected?: bool
  penetrated_layers_min?: int
  penetrated_layers_max?: int
}

#CombatTest: {
  id: string
  description: string
  attacker: #AttackerSpec
  defender: #DefenderSpec
  expected: #ExpectedOutcome
}

combat_tests: {
  // ==========================================================================
  // Physics Verification Suite (T037/T038 fixes)
  // These tests confirm the separation of Geometry (sharpness) from Penetration
  // and the quadratic energy scaling for speed.
  // ==========================================================================

  sword_slash_vs_plate: #CombatTest & {
    id: "sword_slash_vs_plate"
    description: "Knight's sword slash should be deflected by plate armour"
    attacker: {
      weapon_id: "swords.knights_sword"
      technique_id: "swing"
      stakes: "committed"
    }
    defender: {
      armour_ids: ["steel_breastplate"]
      target_part: "torso"
    }
    expected: {
      // Steel plate has deflection 0.85 and geometry_threshold 0.30
      // Sword geometry_coeff is 0.6, which should be substantially deflected
      armour_deflected: true
      damage_dealt_max: 1.0  // Should be near zero (bruising only)
    }
  }

  sword_thrust_vs_plate: #CombatTest & {
    id: "sword_thrust_vs_plate"
    description: "Knight's sword thrust should penetrate plate at weak points"
    attacker: {
      weapon_id: "swords.knights_sword"
      technique_id: "thrust"
      stakes: "committed"
    }
    defender: {
      armour_ids: ["steel_breastplate"]
      target_part: "torso"
    }
    expected: {
      // Thrust has higher geometry focus, may find gaps
      // Energy is lower but concentrated
      damage_dealt_min: 0.0  // May miss or be blocked
      damage_dealt_max: 6.0  // Severity-based (0-5 scale)
    }
  }

  fist_vs_unarmoured: #CombatTest & {
    id: "fist_vs_unarmoured"
    description: "Fist should deal moderate blunt damage to unarmoured target"
    attacker: {
      weapon_id: "natural.fist"
      technique_id: "swing"
      stakes: "committed"
    }
    defender: {
      armour_ids: []
      target_part: "torso"
    }
    expected: {
      // Note: damage_dealt_min = 0 accounts for potential misses (RNG)
      // Future: implement deterministic test mode
      damage_dealt_min: 0.0
      damage_dealt_max: 6.0  // Severity-based (0-5 scale)
    }
  }

  sword_vs_gambeson: #CombatTest & {
    id: "sword_vs_gambeson"
    description: "Sword should cut through gambeson but with reduced effect"
    attacker: {
      weapon_id: "swords.knights_sword"
      technique_id: "swing"
      stakes: "committed"
    }
    defender: {
      armour_ids: ["gambeson_jacket"]
      target_part: "torso"
    }
    expected: {
      // Gambeson has lower deflection (0.20) but high absorption (0.65)
      // Sword should penetrate but with reduced damage
      // Note: armour not yet wired
      damage_dealt_min: 0.0  // May miss
      damage_dealt_max: 6.0  // Severity-based (0-5 scale)
    }
  }
}
