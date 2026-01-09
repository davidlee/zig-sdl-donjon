package data

#CoverageEntry: {
    part_tags: [...string]
    side?: "left" | "right" | "center"
    layer: "padding" | "outer" | "cloak"
    totality: "total" | "intimidating" | "comprehensive" | "frontal" | "minimal"
}

#ArmourPiece: {
    id: string
    name: string
    material: string // reference into materials.cue
    coverage: [...#CoverageEntry]
}

armour_pieces: {
    breastplate: #ArmourPiece & {
        id: "steel_breastplate"
        name: "Steel Breastplate"
        material: "steel_plate"
        coverage: [
            {
                part_tags: ["torso", "abdomen"]
                side: "center"
                layer: "outer"
                totality: "comprehensive"
            },
        ]
    }

    gambeson: #ArmourPiece & {
        id: "gambeson_jacket"
        name: "Gambeson Jacket"
        material: "gambeson"
        coverage: [
            {
                part_tags: ["torso", "abdomen", "shoulder"]
                side: "center"
                layer: "padding"
                totality: "frontal"
            },
        ]
    }
}
