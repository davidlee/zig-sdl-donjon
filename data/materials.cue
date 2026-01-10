package data

// Shared material definitions for armour, tissue, and weapon durability.
//
// Derived combat coefficients (Geometry, Momentum, Rigidity) reference these
// values to stay consistent across bodies and equipment.

#Material: {
    name: string
    category: *"tissue" | "armour" | "weapon"

    // Whether this material provides structural integrity (bone, cartilage).
    // Structural layers use volume-based severity thresholds; non-structural
    // layers cannot escalate to Severity.missing on their own.
    is_structural: bool | *false

    // How well the layer shields what lies beneath it.
    shielding: {
        // Fraction of incoming Geometry it can redirect outright.
        deflection: float & >=0 & <=1
        // Proportion of incoming Momentum it can soak internally.
        absorption: float & >=0
        // Ability to spread Rigidity-driven force across area (0 = none).
        dispersion: float & >=0
    }

    // Susceptibility of the layer itself to damage from each axis.
    susceptibility: {
        geometry_threshold: float & >=0
        geometry_ratio: float & >0
        energy_threshold: float & >=0
        energy_ratio: float & >0
        rigidity_threshold: float & >=0
        rigidity_ratio: float & >0
    }

    // Optional geometry-aware modifiers (quilted padding vs. plate).
    shape?: {
        profile: *"solid" | "quilted" | "mesh" | "lamellar"
        dispersion_bonus: float
        absorption_bonus: float
    }

    density?: float
    notes?: string
}

// Presets compose #Material and can be re-used by tissues or armour pieces.

materials: {
    tissues: {
        muscle: #Material & {
            name: "muscle"
            category: "tissue"
            shielding: {
                deflection: 0.05
                absorption: 0.45
                dispersion: 0.15
            }
            susceptibility: {
                geometry_threshold: 0.05
                geometry_ratio: 0.7
                energy_threshold: 0.10
                energy_ratio: 0.6
                rigidity_threshold: 0.05
                rigidity_ratio: 0.8
            }
            density: 1.06
            notes: "Skeletal muscle tissue"
        }

        bone: #Material & {
            name: "bone"
            category: "tissue"
            is_structural: true
            shielding: {
                deflection: 0.25
                absorption: 0.10
                dispersion: 0.35
            }
            susceptibility: {
                geometry_threshold: 0.20
                geometry_ratio: 0.4
                energy_threshold: 0.35
                energy_ratio: 0.3
                rigidity_threshold: 0.30
                rigidity_ratio: 0.2
            }
            density: 1.90
            notes: "Cortical bone"
        }

        fat: #Material & {
            name: "fat"
            category: "tissue"
            shielding: {
                deflection: 0.02
                absorption: 0.55
                dispersion: 0.10
            }
            susceptibility: {
                geometry_threshold: 0.02
                geometry_ratio: 0.9
                energy_threshold: 0.05
                energy_ratio: 0.8
                rigidity_threshold: 0.02
                rigidity_ratio: 0.9
            }
            density: 0.90
            notes: "Adipose tissue"
        }

        skin: #Material & {
            name: "skin"
            category: "tissue"
            shielding: {
                deflection: 0.10
                absorption: 0.25
                dispersion: 0.10
            }
            susceptibility: {
                geometry_threshold: 0.02
                geometry_ratio: 0.85
                energy_threshold: 0.05
                energy_ratio: 0.9
                rigidity_threshold: 0.02
                rigidity_ratio: 0.95
            }
            density: 1.0
            notes: "Dermis and epidermis layers"
        }

        cartilage: #Material & {
            name: "cartilage"
            category: "tissue"
            is_structural: true
            shielding: {
                deflection: 0.15
                absorption: 0.35
                dispersion: 0.15
            }
            susceptibility: {
                geometry_threshold: 0.10
                geometry_ratio: 0.6
                energy_threshold: 0.20
                energy_ratio: 0.5
                rigidity_threshold: 0.15
                rigidity_ratio: 0.55
            }
            density: 1.1
            notes: "Elastic cartilage"
        }

        tendon: #Material & {
            name: "tendon"
            category: "tissue"
            shielding: {
                deflection: 0.20
                absorption: 0.20
                dispersion: 0.10
            }
            susceptibility: {
                geometry_threshold: 0.08
                geometry_ratio: 0.7
                energy_threshold: 0.18
                energy_ratio: 0.6
                rigidity_threshold: 0.15
                rigidity_ratio: 0.5
            }
            density: 1.1
            notes: "Dense collagen bundles"
        }

        nerve: #Material & {
            name: "nerve"
            category: "tissue"
            shielding: {
                deflection: 0.05
                absorption: 0.30
                dispersion: 0.05
            }
            susceptibility: {
                geometry_threshold: 0.01
                geometry_ratio: 0.95
                energy_threshold: 0.03
                energy_ratio: 0.9
                rigidity_threshold: 0.01
                rigidity_ratio: 0.95
            }
            density: 1.0
            notes: "Peripheral nerve bundle"
        }

        organ: #Material & {
            name: "organ"
            category: "tissue"
            shielding: {
                deflection: 0.05
                absorption: 0.60
                dispersion: 0.10
            }
            susceptibility: {
                geometry_threshold: 0.02
                geometry_ratio: 0.9
                energy_threshold: 0.08
                energy_ratio: 0.7
                rigidity_threshold: 0.03
                rigidity_ratio: 0.85
            }
            density: 1.05
            notes: "Generic soft organ tissue"
        }
    }

    armour: {
        steel_plate: #Material & {
            name: "steel plate"
            category: "armour"
            shielding: {
                deflection: 0.85
                absorption: 0.25
                dispersion: 0.35
            }
            susceptibility: {
                geometry_threshold: 0.30
                geometry_ratio: 0.3
                energy_threshold: 0.50
                energy_ratio: 0.4
                rigidity_threshold: 0.45
                rigidity_ratio: 0.3
            }
            shape: {
                profile: "solid"
                dispersion_bonus: 0.10
                absorption_bonus: -0.05
            }
            notes: "Tempered steel plate cuirass"
        }

        chainmail: #Material & {
            name: "chainmail"
            category: "armour"
            shielding: {
                deflection: 0.55
                absorption: 0.30
                dispersion: 0.20
            }
            susceptibility: {
                geometry_threshold: 0.15
                geometry_ratio: 0.5
                energy_threshold: 0.25
                energy_ratio: 0.6
                rigidity_threshold: 0.25
                rigidity_ratio: 0.5
            }
            shape: {
                profile: "mesh"
                dispersion_bonus: -0.05
                absorption_bonus: 0.05
            }
            notes: "Interlocking riveted rings"
        }

        gambeson: #Material & {
            name: "gambeson"
            category: "armour"
            shielding: {
                deflection: 0.20
                absorption: 0.65
                dispersion: 0.40
            }
            susceptibility: {
                geometry_threshold: 0.05
                geometry_ratio: 0.8
                energy_threshold: 0.15
                energy_ratio: 0.5
                rigidity_threshold: 0.10
                rigidity_ratio: 0.7
            }
            shape: {
                profile: "quilted"
                dispersion_bonus: 0.20
                absorption_bonus: 0.10
            }
            notes: "Layered linen/cotton padding"
        }
    }
}
