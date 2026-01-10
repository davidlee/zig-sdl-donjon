 Executive Summary

  The move from "Everything is a Card" (implementation) to "Everything is a Card" (presentation) backed by a Verb (Action) vs. Noun (Item)
  architecture is the correct decision. The original attempt to jam item state into cards.Instance would have created a monolithic,
  difficult-to-maintain struct.

  However, this pivot creates significant immediate architectural debt: you now need an ItemRegistry, a PhysicalProperties standard, and a "Grant"
  system to bridge items to actions. The "No Abstract Carry" goal is high-risk/high-reward—it promises immersive realism but threatens UI tedium if
  container management becomes "Inventory Tetris."

  ---

  1. Inventory System Project (doc/projects/inventory_system.md)
  The "Master Plan"

   * Strengths: The "Consequences Over Constraints" philosophy is excellent. It avoids the frustrating "you cannot do that" blocks common in RPGs,
     replacing them with narrative mechanical penalties (chafing, noise, fatigue). The distinction between Equipment (body-centric) and Inventory
     (container-centric) is a solid UX model.
   * Weaknesses: The UI flow for Stack-based Container Navigation sounds dangerous. If I have a potion in a pouch in a backpack, digging for it
     during combat logic (even if time-costed) is mechanically sound but UI-painful. The plan glosses over the "Move" semantics—moving an item from
     a backpack to a hand is technically an unequip -> equip chain that might drop the item if hands are full.
   * Critical Risk: Zone Management. The doc admits Zone.inventory is a placeholder. Without a robust zone system, you risk items "vanishing" into
     the void when a container is destroyed or dropped.
   * Recommendation: Prioritize the Physical Attachment Model before the UI. You cannot design the screen until you know if a "Backpack" occupies a
     "Back" slot or if it is just a container entity attached to the "Torso" body part.

  2. Verbs vs. Nouns (doc/issues/verbs_vs_nouns.md)
  The "Architectural Pivot"

   * Strengths: This is the strongest piece of design work here. Separating Actions (Verbs)—which are stateless logic rules—from Items
     (Nouns)—which are stateful physical objects—resolves the cognitive dissonance of a sword having a "Trigger." It clarifies cards.zig as
     actions.zig.
   * Weaknesses: It complicates the "everything is a card" promise. Now, the UI must polymorphically handle two distinct types.
   * Implication: You need a Grant System. A Longsword item must dynamically inject Slash, Thrust, and Parry cards into the deck when equipped.
     This "deck composition on the fly" is complex. Does chipping the sword remove the Parry card? Does it modify the Parry card's values?
   * Verdict: Adopt immediately. The alternative (ItemDataModelling) leads to spaghetti code.

  3. Item Data Modelling (doc/issues/item_data_modelling.md)
  The "Road Not Taken"

   * Critique: This document effectively argues against itself when read alongside Verbs vs Nouns. The proposed KindData union is a classic "God
     Struct" anti-pattern.
   * Value: It effectively enumerates the data requirements (Integrity, Quality, Enchantments, Contents). Even if we reject the implementation, we
     should keep the data schema for the new Item struct proposed in Verbs vs Nouns.
   * Verdict: Archive this. Use it only as a requirements list for the new Item entity.

  4. Unified Entity Wrapper (doc/issues/unified_entity_wrapper.md)
  The "Glue"

   * Analysis: This explores how to treat Actions, Items, and Agents uniformly.
   * Critique: The "Middle Ground" (Shared ID space, separate storage) is the only sane engineering choice. Full unification (storing Agents and
     Cards in the same list) is YAGNI and dangerous due to disparate memory needs.
   * Risk: The Presentation-Only Wrapper is a trap. If you only unify at the view layer, you lose the ability to have generic systems like
     "Targeting" or "Events" that can refer to entity.ID regardless of type.
   * Recommendation: Adopt Shared ID Space (EntityID with a kind field). This allows the Event system (target: entity.ID) to work for attacking an
     Agent or sundering an Item without refactoring the entire event bus.

  5. Physical Properties Unification (doc/issues/physical_properties_unification.md)
  The "Physics Standard"

   * Critique: This is a blocking dependency for "No Abstract Carry." You cannot calculate if a dagger fits in a boot without standardizing volume.
   * Risk: Over-simulation. Calculating actual_volume_m3 for a weirdly shaped helmet to see if it fits in a sack is overkill.
   * Recommendation: Stick to Bounding Box (L x W x D) and Mass. Add a flexibility boolean. Do not implement complex volumetric packing algorithms;
     a simple "sum of bounding volumes <= container capacity" is sufficient for an MVP.
   * Integration: Ensure this structure lives in infra or a low-level domain module so Body, Item, and Weapon can all import it without circular
     deps.

  6. Flavor: Shields Splinter, Swords Chip (doc/ideas/shields_splinter_swords_chip.md)
  The "Why"

   * Perspective: This document provides the gameplay justification for the engineering complexity.
   * Critique: It implies a feedback loop: Action (Impact) -> Physics (3-axis) -> Item State (Integrity Loss) -> Action Availability (Card
     Removed/Debuffed).
   * Insight: This confirms that the Verbs vs Nouns split is vital. If the sword chips (Noun state change), the game needs to dynamically update
     the Slash card (Verb) to deal less damage or cost more time. This dynamic linking is the core engineering challenge you face next.

  Synthesis & Next Steps

   1. Refactor `cards.zig`: Rename/scope it to actions.
   2. Define `EntityID`: Create the shared ID type (u64 packed with index + generation + kind).
   3. Implement `PhysicalProperties`: A standalone struct in domain/physics.zig.
   4. Create `Item` Entity: A new registry and struct in domain/item.zig, using the schema from Item Data Modelling but the architecture from Verbs
      vs Nouns.
   5. Build the "Grant" Link: A mechanism for an Item to insert Action cards into the AlwaysAvailable or Hand zones.

  This is a significant refactor, but it moves the codebase from a "Card Game" architecture to a "Simulation" architecture, which aligns with the
  project's "Dwarf Fortress meets Slay the Spire" goal.
