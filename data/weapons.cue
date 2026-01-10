package data

import (
  "math"
)

// =============================================================================
// Enums
// =============================================================================

#Reach: "clinch" | "dagger" | "mace" | "sabre" | "longsword" | "spear" | "near" | "medium" | "far"

#DamageType: "slash" | "pierce" | "bludgeon" | "crush"

#Category: "sword" | "axe" | "mace" | "club" | "dagger" | "polearm" | "shield" | "improvised" | "unarmed" | "bow" | "crossbow" | "throwing"

#ProjectileType: "arrow" | "bolt" | "dart" | "bullet" | "stone"

// =============================================================================
// Combat Profile Schemas
// =============================================================================

#DefenderModifiers: {
  reach: #Reach
  parry: float & >=0 & <=2
  deflect: float & >=0 & <=2
  block: float & >=0 & <=2
  fragility: float & >=0 & <=5
}

#OffensiveProfile: {
  name: string
  reach: #Reach
  damage_types: [...#DamageType]
  accuracy: float & >0 & <=1.5
  speed: float & >0 & <=2
  damage: float & >0
  penetration: float & >=0
  penetration_max: float & >=0
  fragility: float & >=0 | *1.0
  defender_modifiers: #DefenderModifiers
}

#DefensiveProfile: {
  name: string
  reach: #Reach
  parry: float & >=0 & <=1.5
  deflect: float & >=0 & <=1.5
  block: float & >=0 & <=1.5
  fragility: float & >=0 | *1.0
}

#Grip: {
  one_handed: bool | *false
  two_handed: bool | *false
  versatile: bool | *false
  bastard: bool | *false
  half_sword: bool | *false
  murder_stroke: bool | *false
}

#Features: {
  hooked: bool | *false
  spiked: bool | *false
  crossguard: bool | *false
  pommel: bool | *false
}

// =============================================================================
// Ranged Schemas
// =============================================================================

#Thrown: {
  throw: #OffensiveProfile
  range: #Reach
}

#Projectile: {
  ammunition: #ProjectileType
  range: #Reach
  accuracy: float & >0 & <=1.5
  speed: float & >0
  reload: float & >=0
}

#Ranged: {
  projectile?: #Projectile
  thrown?: #Thrown
}

// =============================================================================
// Main Weapon Schema
// =============================================================================

#Weapon: {
  name: string
  categories: [...#Category]
  features: #Features | *{}
  grip: #Grip

  // Physical dimensions (all in cm/kg for authoring convenience)
  length_cm: float & >0
  weight_kg: float & >0
  balance: float & >=0 & <=1 // 0 = grip, 1 = tip
  integrity: float & >0 | *100.0

  // Combat profiles
  swing?: #OffensiveProfile
  thrust?: #OffensiveProfile
  defence: #DefensiveProfile
  ranged?: #Ranged

  // Physics - can be explicit or derived
  _effective_radius_m: (length_cm / 100) * (0.3 + 0.7 * balance)
  _moment_inertia: weight_kg * math.Pow(_effective_radius_m, 2)

  moment_of_inertia: float & >=0 | *_moment_inertia
  effective_mass: float & >0 | *weight_kg
  reference_energy_j: float & >=0 | *0.0
  geometry_coeff: float & >=0 & <=1
  rigidity_coeff: float & >=0 & <=1
}

// =============================================================================
// Weapon Definitions
// =============================================================================

weapons: {
  // -------------------------------------------------------------------------
  // Swords
  // -------------------------------------------------------------------------
  swords: {
    knights_sword: #Weapon & {
      name: "knight's sword"
      categories: ["sword"]
      features: {
        crossguard: true
        pommel: true
      }
      grip: {
        one_handed: true
      }
      length_cm: 90.0
      weight_kg: 1.1
      balance: 0.3
      integrity: 100.0

      swing: {
        name: "knight's sword swing"
        reach: "sabre"
        damage_types: ["slash"]
        accuracy: 1.0
        speed: 1.0
        damage: 10.0
        penetration: 0.5
        penetration_max: 4.0
        fragility: 1.0
        defender_modifiers: {
          reach: "sabre"
          parry: 1.0
          deflect: 0.8
          block: 0.6
          fragility: 1.0
        }
      }

      thrust: {
        name: "knight's sword thrust"
        reach: "sabre"
        damage_types: ["pierce"]
        accuracy: 0.95
        speed: 1.1
        damage: 8.0
        penetration: 1.0
        penetration_max: 6.0
        fragility: 1.2
        defender_modifiers: {
          reach: "sabre"
          parry: 1.0
          deflect: 0.9
          block: 0.5
          fragility: 0.5
        }
      }

      defence: {
        name: "knight's sword defence"
        reach: "sabre"
        parry: 1.0
        deflect: 0.9
        block: 0.4
        fragility: 1.0
      }

      // Physics from original weapon_list.zig
      moment_of_inertia: 0.593
      effective_mass: 1.4
      reference_energy_j: 10.7
      geometry_coeff: 0.6
      rigidity_coeff: 0.7
    }

    falchion: #Weapon & {
      name: "falchion"
      categories: ["sword"]
      features: {
        crossguard: true
        pommel: true
      }
      grip: {
        one_handed: true
      }
      length_cm: 80.0
      weight_kg: 1.3
      balance: 0.5
      integrity: 110.0

      swing: {
        name: "falchion swing"
        reach: "sabre"
        damage_types: ["slash"]
        accuracy: 0.9
        speed: 0.95
        damage: 12.0
        penetration: 0.6
        penetration_max: 5.0
        fragility: 0.8
        defender_modifiers: {
          reach: "sabre"
          parry: 0.9
          deflect: 0.7
          block: 0.7
          fragility: 1.5
        }
      }

      thrust: {
        name: "falchion thrust"
        reach: "sabre"
        damage_types: ["pierce"]
        accuracy: 0.7
        speed: 0.9
        damage: 5.0
        penetration: 0.4
        penetration_max: 3.0
        fragility: 1.0
        defender_modifiers: {
          reach: "sabre"
          parry: 1.0
          deflect: 1.0
          block: 0.8
          fragility: 0.5
        }
      }

      defence: {
        name: "falchion defence"
        reach: "sabre"
        parry: 0.8
        deflect: 0.7
        block: 0.5
        fragility: 0.8
      }

      moment_of_inertia: 0.21
      effective_mass: 1.3
      reference_energy_j: 3.7
      geometry_coeff: 0.55
      rigidity_coeff: 0.7
    }
  }

  // -------------------------------------------------------------------------
  // Maces
  // -------------------------------------------------------------------------
  maces: {
    horsemans_mace: #Weapon & {
      name: "horseman's mace"
      categories: ["mace"]
      features: {
        pommel: true
      }
      grip: {
        one_handed: true
      }
      length_cm: 60.0
      weight_kg: 1.2
      balance: 0.7
      integrity: 150.0

      swing: {
        name: "horseman's mace swing"
        reach: "mace"
        damage_types: ["bludgeon", "crush"]
        accuracy: 0.9
        speed: 1.0
        damage: 13.0
        penetration: 0.2
        penetration_max: 1.0
        fragility: 0.2
        defender_modifiers: {
          reach: "mace"
          parry: 0.7
          deflect: 0.5
          block: 0.9
          fragility: 2.5
        }
      }

      defence: {
        name: "horseman's mace defence"
        reach: "mace"
        parry: 0.4
        deflect: 0.3
        block: 0.2
        fragility: 0.3
      }

      moment_of_inertia: 0.21
      effective_mass: 1.2
      reference_energy_j: 3.8
      geometry_coeff: 0.2
      rigidity_coeff: 0.8
    }
  }

  // -------------------------------------------------------------------------
  // Axes
  // -------------------------------------------------------------------------
  axes: {
    footmans_axe: #Weapon & {
      name: "footman's axe"
      categories: ["axe"]
      features: {
        hooked: true
      }
      grip: {
        one_handed: true
        two_handed: true
        versatile: true
      }
      length_cm: 75.0
      weight_kg: 1.8
      balance: 0.75
      integrity: 80.0

      swing: {
        name: "footman's axe swing"
        reach: "sabre"
        damage_types: ["slash"]
        accuracy: 0.85
        speed: 0.9
        damage: 14.0
        penetration: 0.8
        penetration_max: 8.0
        fragility: 1.0
        defender_modifiers: {
          reach: "sabre"
          parry: 0.8
          deflect: 0.6
          block: 0.7
          fragility: 2.5
        }
      }

      defence: {
        name: "footman's axe defence"
        reach: "sabre"
        parry: 0.5
        deflect: 0.4
        block: 0.3
        fragility: 1.1
      }

      moment_of_inertia: 0.57
      effective_mass: 1.8
      reference_energy_j: 10.3
      geometry_coeff: 0.6
      rigidity_coeff: 0.65
    }

    greataxe: #Weapon & {
      name: "greataxe"
      categories: ["axe"]
      features: {
        hooked: true
      }
      grip: {
        two_handed: true
        versatile: true
      }
      length_cm: 140.0
      weight_kg: 3.5
      balance: 0.8
      integrity: 90.0

      swing: {
        name: "greataxe swing"
        reach: "longsword"
        damage_types: ["slash"]
        accuracy: 0.75
        speed: 0.7
        damage: 18.0
        penetration: 1.2
        penetration_max: 12.0
        fragility: 1.0
        defender_modifiers: {
          reach: "longsword"
          parry: 0.6
          deflect: 0.4
          block: 0.6
          fragility: 3.5
        }
      }

      defence: {
        name: "greataxe defence"
        reach: "longsword"
        parry: 0.4
        deflect: 0.3
        block: 0.2
        fragility: 1.1
      }

      moment_of_inertia: 4.39
      effective_mass: 3.5
      reference_energy_j: 79.0
      geometry_coeff: 0.55
      rigidity_coeff: 0.6
    }
  }

  // -------------------------------------------------------------------------
  // Daggers
  // -------------------------------------------------------------------------
  daggers: {
    dirk: #Weapon & {
      name: "dirk"
      categories: ["dagger"]
      features: {
        crossguard: true
        pommel: true
      }
      grip: {
        one_handed: true
      }
      length_cm: 35.0
      weight_kg: 0.4
      balance: 0.25
      integrity: 60.0

      swing: {
        name: "dirk slash"
        reach: "dagger"
        damage_types: ["slash"]
        accuracy: 0.95
        speed: 1.3
        damage: 5.0
        penetration: 0.3
        penetration_max: 2.0
        fragility: 1.0
        defender_modifiers: {
          reach: "dagger"
          parry: 1.2
          deflect: 1.1
          block: 1.0
          fragility: 0.3
        }
      }

      thrust: {
        name: "dirk thrust"
        reach: "dagger"
        damage_types: ["pierce"]
        accuracy: 1.0
        speed: 1.4
        damage: 7.0
        penetration: 1.2
        penetration_max: 8.0
        fragility: 1.0
        defender_modifiers: {
          reach: "dagger"
          parry: 1.1
          deflect: 1.0
          block: 0.8
          fragility: 0.3
        }
      }

      defence: {
        name: "dirk defence"
        reach: "dagger"
        parry: 0.6
        deflect: 0.5
        block: 0.1
        fragility: 1.0
      }

      moment_of_inertia: 0.003
      effective_mass: 0.4
      reference_energy_j: 0.05
      geometry_coeff: 0.7
      rigidity_coeff: 0.6
    }
  }

  // -------------------------------------------------------------------------
  // Polearms
  // -------------------------------------------------------------------------
  polearms: {
    spear: #Weapon & {
      name: "spear"
      categories: ["polearm"]
      grip: {
        two_handed: true
        versatile: true
      }
      length_cm: 200.0
      weight_kg: 2.0
      balance: 0.6
      integrity: 70.0

      thrust: {
        name: "spear thrust"
        reach: "spear"
        damage_types: ["pierce"]
        accuracy: 0.9
        speed: 1.0
        damage: 10.0
        penetration: 1.5
        penetration_max: 10.0
        fragility: 1.0
        defender_modifiers: {
          reach: "spear"
          parry: 0.9
          deflect: 0.7
          block: 0.6
          fragility: 0.8
        }
      }

      defence: {
        name: "spear defence"
        reach: "spear"
        parry: 0.7
        deflect: 0.5
        block: 0.3
        fragility: 1.1
      }

      moment_of_inertia: 2.88
      effective_mass: 2.0
      reference_energy_j: 9.0
      geometry_coeff: 0.75
      rigidity_coeff: 0.5
    }
  }

  // -------------------------------------------------------------------------
  // Shields
  // -------------------------------------------------------------------------
  shields: {
    buckler: #Weapon & {
      name: "buckler"
      categories: ["shield"]
      grip: {
        one_handed: true
      }
      length_cm: 35.0
      weight_kg: 1.5
      balance: 0.5
      integrity: 120.0

      swing: {
        name: "buckler punch"
        reach: "dagger"
        damage_types: ["bludgeon"]
        accuracy: 0.85
        speed: 1.2
        damage: 4.0
        penetration: 0.0
        penetration_max: 0.0
        fragility: 0.2
        defender_modifiers: {
          reach: "dagger"
          parry: 1.0
          deflect: 0.9
          block: 0.8
          fragility: 0.5
        }
      }

      defence: {
        name: "buckler defence"
        reach: "dagger"
        parry: 0.9
        deflect: 1.2
        block: 1.0
        fragility: 0.3
      }

      moment_of_inertia: 0.046
      effective_mass: 1.5
      reference_energy_j: 0.8
      geometry_coeff: 0.1
      rigidity_coeff: 0.8
    }
  }

  // -------------------------------------------------------------------------
  // Improvised
  // -------------------------------------------------------------------------
  improvised: {
    fist_stone: #Weapon & {
      name: "fist stone"
      categories: ["improvised"]
      grip: {
        one_handed: true
      }
      length_cm: 10.0
      weight_kg: 0.5
      balance: 0.5
      integrity: 30.0

      swing: {
        name: "fist stone"
        reach: "clinch"
        damage_types: ["bludgeon"]
        accuracy: 0.75
        speed: 1.1
        damage: 4.0
        penetration: 0.1
        penetration_max: 0.5
        fragility: 1.5
        defender_modifiers: {
          reach: "clinch"
          parry: 1.1
          deflect: 1.0
          block: 0.9
          fragility: 1.5
        }
      }

      defence: {
        name: "fist stone defence"
        reach: "clinch"
        parry: 0.2
        deflect: 0.1
        block: 0.1
        fragility: 1.5
      }

      ranged: {
        thrown: {
          throw: {
            name: "fist stone throw"
            reach: "medium"
            damage_types: ["bludgeon"]
            accuracy: 0.8
            speed: 1.0
            damage: 6.0
            penetration: 0.2
            penetration_max: 1.0
            fragility: 2.0
            defender_modifiers: {
              reach: "medium"
              parry: 0.9
              deflect: 0.8
              block: 0.7
              fragility: 1.0
            }
          }
          range: "medium"
        }
      }

      moment_of_inertia: 0.002
      effective_mass: 0.5
      reference_energy_j: 0.02
      geometry_coeff: 0.25
      rigidity_coeff: 0.4
    }
  }

  // -------------------------------------------------------------------------
  // Natural Weapons
  // -------------------------------------------------------------------------
  natural: {
    fist: #Weapon & {
      name: "fist"
      categories: ["unarmed"]
      grip: {
        one_handed: true
      }
      length_cm: 10.0
      weight_kg: 0.5
      balance: 0.5
      integrity: 50.0

      swing: {
        name: "fist punch"
        reach: "clinch"
        damage_types: ["bludgeon"]
        accuracy: 0.9
        speed: 1.3
        damage: 3.0
        penetration: 0.0
        penetration_max: 0.0
        fragility: 1.0
        defender_modifiers: {
          reach: "clinch"
          parry: 1.2
          deflect: 1.1
          block: 1.0
          fragility: 0.3
        }
      }

      defence: {
        name: "fist defence"
        reach: "clinch"
        parry: 0.3
        deflect: 0.2
        block: 0.1
        fragility: 1.0
      }

      moment_of_inertia: 0.002
      effective_mass: 0.5
      reference_energy_j: 0.5
      geometry_coeff: 0.15
      rigidity_coeff: 0.3
    }

    bite: #Weapon & {
      name: "bite"
      categories: ["unarmed"]
      grip: {}
      length_cm: 5.0
      weight_kg: 0.3
      balance: 0.5
      integrity: 40.0

      thrust: {
        name: "bite"
        reach: "clinch"
        damage_types: ["pierce"]
        accuracy: 0.85
        speed: 1.2
        damage: 5.0
        penetration: 0.8
        penetration_max: 3.0
        fragility: 1.0
        defender_modifiers: {
          reach: "clinch"
          parry: 1.0
          deflect: 0.9
          block: 0.8
          fragility: 0.5
        }
      }

      defence: {
        name: "bite defence"
        reach: "clinch"
        parry: 0.1
        deflect: 0.1
        block: 0.0
        fragility: 1.0
      }

      moment_of_inertia: 0.001
      effective_mass: 0.3
      reference_energy_j: 0.3
      geometry_coeff: 0.45
      rigidity_coeff: 0.45
    }

    headbutt: #Weapon & {
      name: "headbutt"
      categories: ["unarmed"]
      grip: {}
      length_cm: 15.0
      weight_kg: 1.0
      balance: 0.5
      integrity: 60.0

      thrust: {
        name: "headbutt"
        reach: "clinch"
        damage_types: ["bludgeon"]
        accuracy: 0.7
        speed: 0.9
        damage: 6.0
        penetration: 0.0
        penetration_max: 0.0
        fragility: 1.0
        defender_modifiers: {
          reach: "clinch"
          parry: 0.8
          deflect: 0.7
          block: 0.6
          fragility: 0.8
        }
      }

      defence: {
        name: "headbutt defence"
        reach: "clinch"
        parry: 0.0
        deflect: 0.0
        block: 0.0
        fragility: 1.0
      }

      moment_of_inertia: 0.006
      effective_mass: 1.0
      reference_energy_j: 1.0
      geometry_coeff: 0.1
      rigidity_coeff: 0.5
    }
  }
}
