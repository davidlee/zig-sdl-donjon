package data

import (
    "math"
)

#Weapon: {
    name: string
    category: *"sword" | "axe" | "mace" | "club" | "improvised" | "natural"
    weight_kg: float & >0
    length_m: float & >0
    balance: float & >=0 & <=1 // 0 = grip, 1 = tip
    curvature: float // for draw cuts (0 = straight, 1 = fully curved)

    reach: *"clinch" | "short" | "medium" | "long"

    // Offensive profile toggles
    swing: bool | *false
    thrust: bool | *false
    throw?: bool | *false

    // Derived physics
    _effective_radius: length_m * (0.3 + 0.7 * balance)
    _moment_inertia: weight_kg * math.Pow(_effective_radius, 2)
    _effective_mass: weight_kg

    derived: {
        moment_of_inertia: _moment_inertia
        effective_mass: _effective_mass
        reference_energy_j: 0.5 * _moment_inertia * math.Pow(angular_speed_rad_s, 2)
        geometry_coeff: base_geometry + curvature * 0.2
        rigidity_coeff: base_rigidity
    }

    base_geometry: float & >=0
    base_rigidity: float & >=0
    angular_speed_rad_s?: float & >=0 // attacker stat context later
    linear_speed_m_s?: float & >=0
}

weapons: {
    swords: {
        #Base: #Weapon & {
            category: "sword"
            reach: "medium"
            swing: true
            thrust: true
            base_geometry: 0.6
            base_rigidity: 0.7
            angular_speed_rad_s: 6.0
            linear_speed_m_s: 3.0
        }

        knights_sword: #Base & {
            name: "Knight's Sword"
            weight_kg: 1.4
            length_m: 0.95
            balance: 0.55
            curvature: 0.0
        }

        arming_sword: #Base & {
            name: "Arming Sword"
            weight_kg: 1.1
            length_m: 0.85
            balance: 0.50
            curvature: 0.05
        }
    }

    improvised: {
        fist_stone: #Weapon & {
            name: "fist stone"
            category: "improvised"
            weight_kg: 0.5
            length_m: 0.10
            balance: 0.5
            reach: "clinch"
            swing: true
            thrust: false
            curvature: 0.0
            base_geometry: 0.25
            base_rigidity: 0.4
            angular_speed_rad_s: 4.0
            derived: {
                geometry_coeff: base_geometry
                rigidity_coeff: base_rigidity
            }
        }
    }

    natural: {
        fist: #Weapon & {
            name: "Fist"
            category: "natural"
            weight_kg: 0.5
            length_m: 0.10
            balance: 0.5
            reach: "clinch"
            swing: true
            thrust: false
            curvature: 0.0
            base_geometry: 0.15
            base_rigidity: 0.3
            angular_speed_rad_s: 5.5
        }

        bite: #Weapon & {
            name: "Bite"
            category: "natural"
            weight_kg: 0.3
            length_m: 0.05
            balance: 0.5
            reach: "clinch"
            swing: false
            thrust: true
            curvature: 0.0
            base_geometry: 0.45
            base_rigidity: 0.45
            angular_speed_rad_s: 4.0
            linear_speed_m_s: 2.5
        }

        headbutt: #Weapon & {
            name: "Headbutt"
            category: "natural"
            weight_kg: 1.0
            length_m: 0.15
            balance: 0.5
            reach: "clinch"
            swing: false
            thrust: true
            curvature: 0.0
            base_geometry: 0.1
            base_rigidity: 0.5
            angular_speed_rad_s: 3.0
            linear_speed_m_s: 1.5
        }
    }
}
