# Impulse / Penetration / Bite - Three-Axis Damage Model

**Related**:
- `doc/artefacts/damage_lethality_analysis.md` (current damage tuning, superseded by this)
- `doc/issues/combat_modifiers_redesign.md` (stakes, modifiers)
- `doc/issues/lethality.md` (original problem statement)
- `doc/issues/data_generation.md` (CUE schema for weapon/armour data)

---

## Motivating Examples

fist vs hammer
sap vs crowbar
elbow vs rock

## IMPULSE vs PENETRATION vs BITE


weapons need 3 dimensions to really articulate their damage:

1. Penetrative/shear coefficient (how well the impact penetrates) - arrows,
   dirks vs axes vs hammers. Rapiers, stilettos, rondel daggers are optimised
   for deep penetration.
2. Impulse/trauma coefficient (overall momentum transfer) - mechanical leverage
   and weight are key here. A truncheon transfers as much kinetic energy as a
   similarly heavy sword.
3. Contact hardness / area – call it “focus” or “pressure multiplier.” or
   "bite"  - High values mean the force is concentrated and structurally
   supported (warhammer, mace), low values mean softer, more distributed
   impacts (sap, padded cudgel). This determines whether the impulse breaks
   bones or just causes soft‑tissue shock.

  With those, the sap would be high trauma, low contact hardness; the warhammer would be high trauma and high hardness
  (plus possibly some penetration if it has a spike). They’d both push trauma resources up, but only the hammer would
  reliably fracture bone because of that hardness/area term.

  So the two original axes are a good foundation, but to separate blunt weapons from each other you need at least one
  more dimension capturing impact concentration / structural support

  ---
once weapons have multiple independent “physics” axes, you do need
  richer armour descriptors than “blunt vs. piercing.” Right now armour just scales one damage number by either “blunt”
  or “pierce,” so adding trauma/impulse/contact hardness would be wasted—the armour couldn’t respond differently.

  A workable approach:

  1. Match armour coefficients to each axis. For the three we’ve been discussing:
      - Shear/penetration resistance – mail and plate high, cloth low.
      - Trauma/impulse absorption – padded armour high (distributes impact), plate moderate (transfers to whole limb),
        mail low (transmits blunt shock).
      - Contact hardness/pressure diffusion – soft armour low (wraps around, concentrates force), rigid armour high
        (spreads force over a plate).

     Armour pieces would carry a tuple like (shear_resist, trauma_absorb, hardness_diffusion), and the body resolution
     would apply the weapon’s matching coefficients before passing anything to tissue layers or trauma resources.
  2. Let armour geometry matter. Beyond coefficients, some armour pieces change contact area themselves. A breastplate
     shouldn’t just resist shear; it should dramatically reduce the “contact hardness” the body experiences by
     spreading force across the plate.
  3. Keep simplified tags for gameplay. You can still categorize armour as “good vs blunt/pierce” for tooltips or quick
     heuristics, but under the hood you’re multiplying against the actual axes. That way, adding a new weapon type
     (sap, chain flail) doesn’t require ad hoc rules; it just plugs different numbers into the same model.

  So yes: with multi-dimensional weapon physics, armour needs corresponding multi-dimensional responses; otherwise you
  lose the nuance you’re introducing. It sounds heavier, but you already have armor layer data—the extra coefficients
  just make the simulation line up better with physical intuition.

---
• If you push weapons/armour toward a unified “physics” model, you can absolutely treat armour + tissue as a single
  stack of layers, each with their own responses to those axes. Right now you already step through armour, then body,
  applying ad‑hoc multipliers at each stage. A more unified approach could look like:

  1. Define every layer (armour plates, padding, skin, fat, muscle, bone) as a MaterialLayer with properties for shear
     resistance, impulse absorption, and pressure diffusion. Armour layers would just be the first entries in that
     stack.
  2. Run the same loop for armour and tissue. For each layer:
      - Reduce the weapon’s shear/penetration energy by the layer’s shear resistance.
      - Apply trauma/impulse absorption (feeding into pain/trauma resources).
      - Adjust contact area/pressure based on the layer’s hardness (spreading out or focusing subsequent forces).
      - Track what makes it through to the next layer.
  3. Let body-specific behavior kick in only when the stack hits biological tissue. e.g. once penetration energy
     reaches muscle, you convert it to wound severity, but the mechanics for energy transfer were the same ones armour
     used.

  The upside: you can remove special cases (“armour does X, body does Y”) and just feed in different material data. A
  sap, mace, plate cuirass, and ribs all use the same math; only their coefficients differ.

  The downside: it’s more data to maintain, and you’ll need to re-tune all layers so armour still feels distinct
  (otherwise padding might feel just like fat). But conceptually it simplifies things: armour is just extra layers
  ahead of skin, not a separate system.

  So yes, there’s a strong argument for unifying the model. If you’re already investing in per-axis weapon physics,
  treating armour and tissue as the same kind of material stack lets those axes pay off everywhere, and you only have
  to reason about “energy moving through layers” once.

---

• Right, the data’s already there: weight, length, balance point—all the ingredients you’d use to estimate kinetic
  energy or angular momentum. Instead of hand-tuning a “damage” scalar, you could derive the impulse axis directly from
  these physical properties plus the attacker’s stats:

  - Moment of inertia for a swing ≈ weight × (effective radius)^2, with
    effective radius based on length and balance (high balance value means more
    mass toward the tip).
  - Kinetic energy ∝ ½ × moment × angular velocity^2; angular velocity comes
    from the attacker’s speed/power stats plus technique modifiers.
  - For thrusts, treat it like a translational mass: weight plus how much mass
    is behind the point (balance), and derive linear KE. (need to factor speed
    here; unless the weapon is uncommonly heavy, thrust speed is probably
    mostly about the combatant's Speed stat + their technique + footwork); some
    "moves" mobilize a lot more of the body's mass behind the point than
    others.

  Once you compute “available energy,” split it into penetrative vs. blunt fractions based on weapon features (edge vs.
  spike vs. flat). That gives you a principled impulse value to feed into the trauma axis, instead of an arbitrary
  damage field.

  Then, armour/body just consume that energy via their layer coefficients. You can still keep a per-weapon modifier to
  account for material quality (steel vs. bronze), but the baseline scales naturally: warhammers hit harder because
  they’re heavy with high tip mass; saps deposit less energy despite similar weight because their effective radius is
  short and the material is compliant.

weapon:
  Penetration, Force, Hardness
  Shear, Impulse, Pressure
  Sharpness, Impact, Density
  Edge, Joules, Temper
  Point, Joules, 

Penetration, Force, Temper
Geometry, Impact, Hardness
Shear, Momentum, Rigidity

Option A: The Physics/Simulationist
(Good for gritty, realistic feel)

    Geometry (The shape of the tool)
    Momentum (The energy input)
    Rigidity (The material efficiency)

Option B: The Visceral/Action
(Good for player feedback)

    Penetration (How deep it goes)
    Impact (How hard it hits)
    Hardness (How solid the hit is)

Option C: The Engineering
(Best for crafting mechanics)

    Shear (Cutting ability)
    Force (Kinetic load)
    Temper (Material quality/shock transfer)