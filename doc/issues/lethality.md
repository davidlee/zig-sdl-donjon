Yeah, the weapon templates are tuned like every fight is mortal-combat ultra mode. A few quick observations from the
  data:

  - Swing and thrust techniques both default to damage.instances = &.{.{ .amount = 1.0 … }} but then scale by stats
    with ratios ≥ 1.0 (card_list.zig:255+). Combine that with armour/bone absorption that hasn’t been tuned down, and
    even the humble thrown rock (weapon_list) ends up pumping enough blunt damage to blow through cartilage and bone
    (src/domain/body.zig:1448-1488 test cases show how slash/pierce/bludgeon push wounds straight to severe/missing
    when amount ≥1.0).
  - The wound severities are discrete: hitting the “broken” or “missing” thresholds instantly wrecks a part, and the
    default weapon profiles already meet those thresholds. There aren’t many intermediate effects (bruises, cuts)
    because the damage falloff is almost nonexistent.

  Options to dial lethality back:

  1. Re-scale weapon damage – drop damage.instances[*].amount and the damage_scaling.ratio for most templates. Rocks
     shouldn’t share the same base amount as a claymore; right now they do. Even halving blunt damage would push
     outcomes into “inhibited/broken” instead of “missing.”
  2. Adjust tissue absorbtion/penetration – in body.zig the tissue layers don’t mitigate much. Increase the default
     absorption for skin/muscle/bone or clamp per-hit contributions so multiple hits are required to sever.
  3. Introduce graze/partial hit states – let resolveTechniqueVsDefense roll produce partial effects (light trauma,
     condition penalties) instead of full limb destruction every time. That might mean capping damage_mult until stakes
     escalate.

  If you want to start light, tweak the weapon templates (especially blunt ones like thrown_rock) to have lower base
  amounts and reduce the damage_scaling ratios; the rest of the system will follow. But in the long run we probably
  need a broader retune of tissue thresholds or a new “minor wound” tier so every contact isn’t catastrophic.