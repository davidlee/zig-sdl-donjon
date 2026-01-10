package data

// taxonomy.cue - Data-driven body part taxonomy
// This file defines valid PartTag values that get generated into Zig enums.
// Adding a new tag here (e.g., "wing", "pseudopod") makes it available for
// use in body plans without modifying engine code.

// Valid body part tags - used in body plans to identify part types.
// The generator produces `pub const PartTag = enum { ... };` from this list.
part_tags: [
  // Humanoid exterior
  "head",
  "eye",
  "nose",
  "ear",
  "neck",
  "torso",
  "abdomen",
  "shoulder",
  "groin",
  "arm",
  "elbow",
  "forearm",
  "wrist",
  "hand",
  "finger",
  "thumb",
  "thigh",
  "knee",
  "shin",
  "ankle",
  "foot",
  "toe",

  // Humanoid organs
  "brain",
  "heart",
  "lung",
  "stomach",
  "liver",
  "intestine",
  "tongue",
  "trachea",
  "spleen",

  // Future: non-humanoid parts can be added here
  // "wing",
  // "tail",
  // "pseudopod",
  // "tentacle",
  // "claw",
  // "beak",
  // "horn",
]
