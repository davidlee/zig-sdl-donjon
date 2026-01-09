package data

#DamageInstance: {
    amount: float
    types: [...string]
}

#Scaling: {
    ratio: float
    stats: {
        stat?: string
        average?: [string, string]
    }
}

#Damage: {
    instances: [...#DamageInstance]
    scaling: #Scaling
}

#AxisBias: {
    geometry_mult?: float
    energy_mult?: float
    rigidity_mult?: float
}

#Technique: {
    id: string
    name: string
    attack_mode: "thrust" | "swing" | "ranged" | "none"
    damage: #Damage
    difficulty: float
    channels: {
        weapon?: bool
        off_hand?: bool
        footwork?: bool
    }
    target_height?: "high" | "mid" | "low"
    secondary_height?: "high" | "mid" | "low"
    guard_height?: "high" | "mid" | "low"
    covers_adjacent?: bool
    deflect_mult: float
    parry_mult: float
    dodge_mult: float
    counter_mult: float
    overlay_bonus?: {
        offensive?: {
            to_hit_bonus?: float
            damage_mult?: float
        }
        defensive?: {
            defense_bonus?: float
        }
    }
    axis_bias?: #AxisBias
}

techniques: {
    thrust: #Technique & {
        id: "thrust"
        name: "thrust"
        attack_mode: "thrust"
        target_height: "mid"
        damage: {
            instances: [{
                amount: 1.0
                types: ["pierce"]
            }]
            scaling: {
                ratio: 0.5
                stats: {
                    average: ["speed", "power"]
                }
            }
        }
        difficulty: 0.7
        channels: { weapon: true }
        deflect_mult: 1.3
        dodge_mult: 0.5
        counter_mult: 1.1
        parry_mult: 1.2
    }

    swing: #Technique & {
        id: "swing"
        name: "swing"
        attack_mode: "swing"
        target_height: "high"
        secondary_height: "mid"
        damage: {
            instances: [{
                amount: 1.0
                types: ["slash"]
            }]
            scaling: {
                ratio: 1.2
                stats: {
                    average: ["speed", "power"]
                }
            }
        }
        difficulty: 1.0
        channels: { weapon: true }
        deflect_mult: 1.0
        dodge_mult: 1.2
        counter_mult: 1.3
        parry_mult: 1.2
    }

    throw: #Technique & {
        id: "throw"
        name: "throw"
        attack_mode: "ranged"
        target_height: "mid"
        damage: {
            instances: [{
                amount: 1.0
                types: ["bludgeon"]
            }]
            scaling: {
                ratio: 0.8
                stats: {
                    average: ["speed", "speed"]
                }
            }
        }
        difficulty: 0.9
        channels: { weapon: true }
        deflect_mult: 0.8
        dodge_mult: 1.0
        counter_mult: 0.0
        parry_mult: 0.7
    }

    block: #Technique & {
        id: "block"
        name: "block"
        attack_mode: "none"
        channels: { off_hand: true }
        guard_height: "mid"
        covers_adjacent: true
        damage: {
            instances: [{
                amount: 0.0
                types: []
            }]
            scaling: {
                ratio: 0.0
                stats: { stat: "power" }
            }
        }
        difficulty: 1.0
        deflect_mult: 1.0
        dodge_mult: 1.0
        counter_mult: 1.0
        parry_mult: 1.0
    }

    riposte: #Technique & {
        id: "riposte"
        name: "riposte"
        attack_mode: "thrust"
        target_height: "mid"
        damage: {
            instances: [{
                amount: 1.2
                types: ["pierce"]
            }]
            scaling: {
                ratio: 0.6
                stats: {
                    average: ["speed", "power"]
                }
            }
        }
        difficulty: 0.5
        channels: { weapon: true }
        deflect_mult: 0.8
        dodge_mult: 0.6
        counter_mult: 1.5
        parry_mult: 0.9
        axis_bias: {
            geometry_mult: 1.1
            energy_mult: 0.9
        }
    }

    deflect: #Technique & {
        id: "deflect"
        name: "deflect"
        attack_mode: "none"
        guard_height: "mid"
        covers_adjacent: true
        damage: {
            instances: [{
                amount: 0.0
                types: []
            }]
            scaling: {
                ratio: 0.0
                stats: { stat: "power" }
            }
        }
        difficulty: 0.8
        channels: { weapon: true }
        deflect_mult: 1.2
        dodge_mult: 1.0
        counter_mult: 0.8
        parry_mult: 1.0
    }

    parry: #Technique & {
        id: "parry"
        name: "parry"
        attack_mode: "none"
        guard_height: "mid"
        damage: {
            instances: [{
                amount: 0.0
                types: []
            }]
            scaling: {
                ratio: 0.0
                stats: { stat: "power" }
            }
        }
        difficulty: 1.2
        channels: { weapon: true }
        deflect_mult: 0.8
        dodge_mult: 1.0
        counter_mult: 1.3
        parry_mult: 1.4
        axis_bias: {
            rigidity_mult: 1.1
        }
    }
}
