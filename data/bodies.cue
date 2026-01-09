package data

// Tissue templates, body plan geometry metadata, and species definitions.
// These records extend the shared material schema so tissues and armour
// reference the same presets while giving the data audit concrete per-part
// dimensions to reason about.

#LayerSpec: {
    material_id: string
    thickness_ratio: float & >0
    material: materials.tissues[material_id]
}

#TissueTemplate: {
    id: string
    layers: [...#LayerSpec]
    notes?: string
}

tissue_templates: {
    limb: #TissueTemplate & {
        id: "limb"
        notes: "Bone core wrapped in muscle, tendon, nerves, skin."
        layers: [
            { material_id: "skin", thickness_ratio: 0.05 },
            { material_id: "fat", thickness_ratio: 0.10 },
            { material_id: "muscle", thickness_ratio: 0.40 },
            { material_id: "tendon", thickness_ratio: 0.10 },
            { material_id: "nerve", thickness_ratio: 0.05 },
            { material_id: "bone", thickness_ratio: 0.30 },
        ]
    }

    digit: #TissueTemplate & {
        id: "digit"
        notes: "Minimal soft tissue around slender bones."
        layers: [
            { material_id: "skin", thickness_ratio: 0.10 },
            { material_id: "tendon", thickness_ratio: 0.15 },
            { material_id: "nerve", thickness_ratio: 0.05 },
            { material_id: "bone", thickness_ratio: 0.30 },
            { material_id: "cartilage", thickness_ratio: 0.10 },
        ]
    }

    joint: #TissueTemplate & {
        id: "joint"
        notes: "Bone with cartilage pads and encapsulating ligaments."
        layers: [
            { material_id: "skin", thickness_ratio: 0.08 },
            { material_id: "cartilage", thickness_ratio: 0.15 },
            { material_id: "tendon", thickness_ratio: 0.15 },
            { material_id: "bone", thickness_ratio: 0.40 },
            { material_id: "nerve", thickness_ratio: 0.05 },
        ]
    }

    facial: #TissueTemplate & {
        id: "facial"
        notes: "Cartilage-heavy facial features with light soft tissue."
        layers: [
            { material_id: "skin", thickness_ratio: 0.20 },
            { material_id: "fat", thickness_ratio: 0.15 },
            { material_id: "cartilage", thickness_ratio: 0.35 },
            { material_id: "muscle", thickness_ratio: 0.20 },
        ]
    }

    organ: #TissueTemplate & {
        id: "organ"
        notes: "Soft organ tissue."
        layers: [
            { material_id: "organ", thickness_ratio: 1.0 },
        ]
    }

    core: #TissueTemplate & {
        id: "core"
        notes: "Thick torso sections with ribs, muscle, fat, skin."
        layers: [
            { material_id: "skin", thickness_ratio: 0.05 },
            { material_id: "fat", thickness_ratio: 0.15 },
            { material_id: "muscle", thickness_ratio: 0.35 },
            { material_id: "bone", thickness_ratio: 0.35 },
            { material_id: "cartilage", thickness_ratio: 0.10 },
        ]
    }
}

#Geometry: {
    thickness_cm: number & >0
    length_cm: number & >0
    area_cm2: number & >0
}

#BodyPart: {
    tag: string
    side: *"center" | "left" | "right"
    parent?: string      // part name for attachment chain (null = root)
    enclosing?: string   // part name for containment (organs enclosed by cavity)
    tissue_template: string
    has_major_artery?: bool | *false
    flags?: {
        vital?: bool
        internal?: bool
        grasp?: bool
        stand?: bool
        see?: bool
        hear?: bool
    }
    geometry: #Geometry
}

#BodyPlan: {
    id: string
    name: string
    base_height_cm: float
    base_mass_kg: float
    parts: [string]: #BodyPart
}

body_plans: {
    humanoid: #BodyPlan & {
        id: "humanoid"
        name: "Humanoid Plan"
        base_height_cm: 175.0
        base_mass_kg: 80.0
        parts: {
            torso: #BodyPart & {
                tag: "torso"
                // root part - no parent
                geometry: { thickness_cm: 32, length_cm: 55, area_cm2: 1200 }
                tissue_template: "core"
                flags: { vital: true }
            }
            abdomen: #BodyPart & {
                tag: "abdomen"
                parent: "torso"
                geometry: { thickness_cm: 28, length_cm: 45, area_cm2: 950 }
                tissue_template: "core"
                flags: { vital: true }
            }
            neck: #BodyPart & {
                tag: "neck"
                parent: "torso"
                geometry: { thickness_cm: 14, length_cm: 15, area_cm2: 320 }
                tissue_template: "core"
                has_major_artery: true
                flags: { vital: true }
            }
            head: #BodyPart & {
                tag: "head"
                parent: "neck"
                geometry: { thickness_cm: 20, length_cm: 25, area_cm2: 450 }
                tissue_template: "core"
                flags: { vital: true }
            }
            groin: #BodyPart & {
                tag: "groin"
                parent: "abdomen"
                geometry: { thickness_cm: 18, length_cm: 12, area_cm2: 260 }
                tissue_template: "joint"
                has_major_artery: true
            }
            heart: #BodyPart & {
                tag: "heart"
                parent: "torso"
                enclosing: "torso"
                geometry: { thickness_cm: 8, length_cm: 12, area_cm2: 90 }
                tissue_template: "organ"
                flags: { vital: true, internal: true }
            }
            left_lung: #BodyPart & {
                tag: "lung"
                side: "left"
                parent: "torso"
                enclosing: "torso"
                geometry: { thickness_cm: 10, length_cm: 25, area_cm2: 200 }
                tissue_template: "organ"
                flags: { internal: true }
            }
            right_lung: #BodyPart & {
                tag: "lung"
                side: "right"
                parent: "torso"
                enclosing: "torso"
                geometry: { thickness_cm: 10, length_cm: 25, area_cm2: 220 }
                tissue_template: "organ"
                flags: { internal: true }
            }
            liver: #BodyPart & {
                tag: "liver"
                parent: "abdomen"
                enclosing: "abdomen"
                geometry: { thickness_cm: 9, length_cm: 20, area_cm2: 180 }
                tissue_template: "organ"
                flags: { internal: true }
            }
            stomach: #BodyPart & {
                tag: "stomach"
                parent: "abdomen"
                enclosing: "abdomen"
                geometry: { thickness_cm: 8, length_cm: 18, area_cm2: 150 }
                tissue_template: "organ"
                flags: { internal: true }
            }
            spleen: #BodyPart & {
                tag: "spleen"
                side: "left"
                parent: "abdomen"
                enclosing: "abdomen"
                geometry: { thickness_cm: 6, length_cm: 12, area_cm2: 80 }
                tissue_template: "organ"
                flags: { internal: true }
            }
            intestines: #BodyPart & {
                tag: "intestine"
                parent: "abdomen"
                enclosing: "abdomen"
                geometry: { thickness_cm: 8, length_cm: 35, area_cm2: 250 }
                tissue_template: "organ"
                flags: { internal: true }
            }
            trachea: #BodyPart & {
                tag: "trachea"
                parent: "neck"
                enclosing: "neck"
                geometry: { thickness_cm: 4, length_cm: 12, area_cm2: 60 }
                tissue_template: "facial"
                flags: { internal: true }
            }
            brain: #BodyPart & {
                tag: "brain"
                parent: "head"
                enclosing: "head"
                geometry: { thickness_cm: 6, length_cm: 18, area_cm2: 140 }
                tissue_template: "organ"
                flags: { internal: true, vital: true }
            }
            nose: #BodyPart & {
                tag: "nose"
                parent: "head"
                geometry: { thickness_cm: 4, length_cm: 6, area_cm2: 40 }
                tissue_template: "facial"
            }
            left_eye: #BodyPart & {
                tag: "eye"
                side: "left"
                parent: "head"
                tissue_template: "facial"
                geometry: { thickness_cm: 3, length_cm: 2.5, area_cm2: 15 }
                flags: { see: true }
            }
            right_eye: #BodyPart & {
                tag: "eye"
                side: "right"
                parent: "head"
                tissue_template: "facial"
                geometry: { thickness_cm: 3, length_cm: 2.5, area_cm2: 15 }
                flags: { see: true }
            }
            left_ear: #BodyPart & {
                tag: "ear"
                side: "left"
                parent: "head"
                tissue_template: "facial"
                geometry: { thickness_cm: 2, length_cm: 6, area_cm2: 20 }
                flags: { hear: true }
            }
            right_ear: #BodyPart & {
                tag: "ear"
                side: "right"
                parent: "head"
                tissue_template: "facial"
                geometry: { thickness_cm: 2, length_cm: 6, area_cm2: 20 }
                flags: { hear: true }
            }
            tongue: #BodyPart & {
                tag: "tongue"
                parent: "head"
                geometry: { thickness_cm: 3, length_cm: 12, area_cm2: 60 }
                tissue_template: "facial"
            }

            left_shoulder: #BodyPart & {
                tag: "shoulder"
                side: "left"
                parent: "torso"
                tissue_template: "limb"
                has_major_artery: true
                geometry: { thickness_cm: 18, length_cm: 18, area_cm2: 360 }
            }
            right_shoulder: #BodyPart & {
                tag: "shoulder"
                side: "right"
                parent: "torso"
                tissue_template: "limb"
                has_major_artery: true
                geometry: { thickness_cm: 18, length_cm: 18, area_cm2: 360 }
            }
            left_arm: #BodyPart & {
                tag: "arm"
                side: "left"
                parent: "left_shoulder"
                tissue_template: "limb"
                geometry: { thickness_cm: 12, length_cm: 35, area_cm2: 260 }
            }
            right_arm: #BodyPart & {
                tag: "arm"
                side: "right"
                parent: "right_shoulder"
                tissue_template: "limb"
                geometry: { thickness_cm: 12, length_cm: 35, area_cm2: 260 }
            }
            left_elbow: #BodyPart & {
                tag: "elbow"
                side: "left"
                parent: "left_arm"
                tissue_template: "joint"
                geometry: { thickness_cm: 10, length_cm: 8, area_cm2: 140 }
            }
            right_elbow: #BodyPart & {
                tag: "elbow"
                side: "right"
                parent: "right_arm"
                tissue_template: "joint"
                geometry: { thickness_cm: 10, length_cm: 8, area_cm2: 140 }
            }
            left_forearm: #BodyPart & {
                tag: "forearm"
                side: "left"
                parent: "left_elbow"
                tissue_template: "limb"
                geometry: { thickness_cm: 9, length_cm: 28, area_cm2: 210 }
            }
            right_forearm: #BodyPart & {
                tag: "forearm"
                side: "right"
                parent: "right_elbow"
                tissue_template: "limb"
                geometry: { thickness_cm: 9, length_cm: 28, area_cm2: 210 }
            }
            left_wrist: #BodyPart & {
                tag: "wrist"
                side: "left"
                parent: "left_forearm"
                tissue_template: "joint"
                geometry: { thickness_cm: 7, length_cm: 5, area_cm2: 80 }
            }
            right_wrist: #BodyPart & {
                tag: "wrist"
                side: "right"
                parent: "right_forearm"
                tissue_template: "joint"
                geometry: { thickness_cm: 7, length_cm: 5, area_cm2: 80 }
            }
            left_hand: #BodyPart & {
                tag: "hand"
                side: "left"
                parent: "left_wrist"
                tissue_template: "joint"
                geometry: { thickness_cm: 4, length_cm: 18, area_cm2: 110 }
                flags: { grasp: true }
            }
            right_hand: #BodyPart & {
                tag: "hand"
                side: "right"
                parent: "right_wrist"
                tissue_template: "joint"
                geometry: { thickness_cm: 4, length_cm: 18, area_cm2: 110 }
                flags: { grasp: true }
            }
            left_thumb: #BodyPart & {
                tag: "thumb"
                side: "left"
                parent: "left_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 2.5, length_cm: 6, area_cm2: 18 }
            }
            right_thumb: #BodyPart & {
                tag: "thumb"
                side: "right"
                parent: "right_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 2.5, length_cm: 6, area_cm2: 18 }
            }
            left_index_finger: #BodyPart & {
                tag: "finger"
                side: "left"
                parent: "left_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 2, length_cm: 7, area_cm2: 15 }
            }
            left_middle_finger: #BodyPart & {
                tag: "finger"
                side: "left"
                parent: "left_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 2, length_cm: 8, area_cm2: 16 }
            }
            left_ring_finger: #BodyPart & {
                tag: "finger"
                side: "left"
                parent: "left_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 2, length_cm: 7, area_cm2: 15 }
            }
            left_pinky_finger: #BodyPart & {
                tag: "finger"
                side: "left"
                parent: "left_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 1.8, length_cm: 6, area_cm2: 13 }
            }
            right_index_finger: #BodyPart & {
                tag: "finger"
                side: "right"
                parent: "right_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 2, length_cm: 7, area_cm2: 15 }
            }
            right_middle_finger: #BodyPart & {
                tag: "finger"
                side: "right"
                parent: "right_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 2, length_cm: 8, area_cm2: 16 }
            }
            right_ring_finger: #BodyPart & {
                tag: "finger"
                side: "right"
                parent: "right_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 2, length_cm: 7, area_cm2: 15 }
            }
            right_pinky_finger: #BodyPart & {
                tag: "finger"
                side: "right"
                parent: "right_hand"
                tissue_template: "digit"
                geometry: { thickness_cm: 1.8, length_cm: 6, area_cm2: 13 }
            }

            left_thigh: #BodyPart & {
                tag: "thigh"
                side: "left"
                parent: "groin"
                tissue_template: "limb"
                has_major_artery: true
                geometry: { thickness_cm: 18, length_cm: 45, area_cm2: 320 }
                flags: { stand: true }
            }
            right_thigh: #BodyPart & {
                tag: "thigh"
                side: "right"
                parent: "groin"
                tissue_template: "limb"
                has_major_artery: true
                geometry: { thickness_cm: 18, length_cm: 45, area_cm2: 320 }
                flags: { stand: true }
            }
            left_knee: #BodyPart & {
                tag: "knee"
                side: "left"
                parent: "left_thigh"
                tissue_template: "joint"
                geometry: { thickness_cm: 12, length_cm: 8, area_cm2: 150 }
            }
            right_knee: #BodyPart & {
                tag: "knee"
                side: "right"
                parent: "right_thigh"
                tissue_template: "joint"
                geometry: { thickness_cm: 12, length_cm: 8, area_cm2: 150 }
            }
            left_shin: #BodyPart & {
                tag: "shin"
                side: "left"
                parent: "left_knee"
                tissue_template: "limb"
                geometry: { thickness_cm: 14, length_cm: 40, area_cm2: 260 }
                flags: { stand: true }
            }
            right_shin: #BodyPart & {
                tag: "shin"
                side: "right"
                parent: "right_knee"
                tissue_template: "limb"
                geometry: { thickness_cm: 14, length_cm: 40, area_cm2: 260 }
                flags: { stand: true }
            }
            left_ankle: #BodyPart & {
                tag: "ankle"
                side: "left"
                parent: "left_shin"
                tissue_template: "joint"
                geometry: { thickness_cm: 8, length_cm: 6, area_cm2: 90 }
            }
            right_ankle: #BodyPart & {
                tag: "ankle"
                side: "right"
                parent: "right_shin"
                tissue_template: "joint"
                geometry: { thickness_cm: 8, length_cm: 6, area_cm2: 90 }
            }
            left_foot: #BodyPart & {
                tag: "foot"
                side: "left"
                parent: "left_ankle"
                tissue_template: "joint"
                geometry: { thickness_cm: 5, length_cm: 26, area_cm2: 180 }
                flags: { stand: true }
            }
            right_foot: #BodyPart & {
                tag: "foot"
                side: "right"
                parent: "right_ankle"
                tissue_template: "joint"
                geometry: { thickness_cm: 5, length_cm: 26, area_cm2: 180 }
                flags: { stand: true }
            }
            left_big_toe: #BodyPart & {
                tag: "toe"
                side: "left"
                parent: "left_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 2.2, length_cm: 5, area_cm2: 12 }
            }
            left_second_toe: #BodyPart & {
                tag: "toe"
                side: "left"
                parent: "left_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 2.0, length_cm: 4.5, area_cm2: 11 }
            }
            left_third_toe: #BodyPart & {
                tag: "toe"
                side: "left"
                parent: "left_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 1.9, length_cm: 4.5, area_cm2: 10 }
            }
            left_fourth_toe: #BodyPart & {
                tag: "toe"
                side: "left"
                parent: "left_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 1.8, length_cm: 4, area_cm2: 9 }
            }
            left_pinky_toe: #BodyPart & {
                tag: "toe"
                side: "left"
                parent: "left_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 1.7, length_cm: 3.5, area_cm2: 8 }
            }
            right_big_toe: #BodyPart & {
                tag: "toe"
                side: "right"
                parent: "right_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 2.2, length_cm: 5, area_cm2: 12 }
            }
            right_second_toe: #BodyPart & {
                tag: "toe"
                side: "right"
                parent: "right_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 2.0, length_cm: 4.5, area_cm2: 11 }
            }
            right_third_toe: #BodyPart & {
                tag: "toe"
                side: "right"
                parent: "right_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 1.9, length_cm: 4.5, area_cm2: 10 }
            }
            right_fourth_toe: #BodyPart & {
                tag: "toe"
                side: "right"
                parent: "right_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 1.8, length_cm: 4, area_cm2: 9 }
            }
            right_pinky_toe: #BodyPart & {
                tag: "toe"
                side: "right"
                parent: "right_foot"
                tissue_template: "digit"
                geometry: { thickness_cm: 1.7, length_cm: 3.5, area_cm2: 8 }
            }
        }
    }
}

#NaturalWeaponRef: {
    weapon_id: string
    required_part: string
}

#Species: {
    id: string
    name: string
    body_plan: string
    base_blood: float
    base_stamina: float
    base_focus: float
    stamina_recovery?: float
    focus_recovery?: float
    blood_recovery?: float
    size_modifiers?: {
        height?: float
        mass?: float
    }
    tags: [...string]
    natural_weapons: [...#NaturalWeaponRef]
}

species: {
    dwarf: #Species & {
        id: "dwarf"
        name: "Dwarf"
        body_plan: "humanoid"
        base_blood: 4.5
        base_stamina: 12.0
        base_focus: 8.0
        size_modifiers: { height: 0.9, mass: 1.1 }
        tags: ["humanoid", "mammal"]
        natural_weapons: [
            { weapon_id: "natural.fist", required_part: "hand" },
            { weapon_id: "natural.headbutt", required_part: "head" },
        ]
    }

    goblin: #Species & {
        id: "goblin"
        name: "Goblin"
        body_plan: "humanoid"
        base_blood: 3.5
        base_stamina: 10.0
        base_focus: 6.0
        size_modifiers: { height: 0.8, mass: 0.7 }
        tags: ["humanoid", "mammal", "predator"]
        natural_weapons: [
            { weapon_id: "natural.fist", required_part: "hand" },
            { weapon_id: "natural.bite", required_part: "head" },
        ]
    }
}
