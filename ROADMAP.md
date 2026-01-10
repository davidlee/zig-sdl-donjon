 Roadmap Update (2026-01-10 -- 00afff742653da099a04866bda5748624b6f1673)

   1. T044: CUE Weapon Unification (PRIORITY)
       * Goal: Unify weapon_list.zig and CUE physics.
       * Implementation: Extend the #Weapon schema in CUE to include all combat stats (reach, accuracy, speed, damage). Update the generator to emit
         the full nested Offensive and Defensive profiles for the weapon.Template struct.
   2. T043: JSON Event Logger (In Progress)
       * Architectural Fit: This is the perfect companion to the combat_packet_resolved event. By serializing the full Event union to JSON, you can
         use external tools (or even CUE) to audit entire combat logs against expected physics traces.
       * Suggestion: Ensure the logger handles the AgentMeta and entity.ID fields consistently so they can be cross-referenced back to the initial
         game state.
   3. T042: Generalized Physiology & Scaling
       * Unlock non-humanoids by generating the PartTag enum from CUE data.
   4. T039: Severity Volume Thresholds
       * Move from scalar thresholds to volume-aware severity mapping.

  Architectural Recommendation for T044
  As you move into T044, aim to make weapon_list.zig strictly a Registry that maps named IDs to the GeneratedWeapons constants. This will allow the
  game to remain fully data-driven while keeping the ease of access in the Zig code.

  I have moved T040 and T041 to `done/` in my internal tracking and marked them as complete in the design doc. Standing by for the JSON Logger
  implementation or the start of T044.