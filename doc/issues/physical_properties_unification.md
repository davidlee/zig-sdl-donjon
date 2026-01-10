# Physical Properties Unification

**Solution:** [Physical Interface Design](../artefacts/physical_interface_design.md)

## Context

Multiple systems model physical properties of things:

- **Weapons**: mass, length, balance point, moment of inertia
- **Body parts**: area, length, thickness (via `BodyPartGeometry`)
- **Armour**: coverage, thickness, material density (implicit in Material)
- **Future items**: containers (volume, weight capacity), generic objects

If inventory needs to reason about weight, volume, or dimensions (and it would be
strange if it didn't), we need a coherent universal model for physical properties.

## The Problem

Currently, physical properties are scattered and inconsistent:

**weapon.Template:**
```zig
weight: f32,           // kg
length: f32,           // m (blade + handle)
balance_point: f32,    // m from guard
moment_of_inertia: f32,// kg·m²
effective_mass: f32,   // kg
```

**body.BodyPartGeometry:**
```zig
area_cm2: f32,
length_cm: f32,
circumference_cm: f32,
```

**armour.Material:**
```zig
thickness: f32,        // mm
density: f32,          // kg/m³ (implicit in physics)
```

Different units (m vs cm vs mm), different property sets, no shared abstraction.

## Why This Matters

1. **Inventory constraints**: Can this sword fit in this scabbard? Does this backpack
   have room? How much can I carry before I'm encumbered?

2. **Physical interactions**: Picking up a severed limb - what does it weigh? What's
   its volume?

3. **Item composition**: Add a basket hilt to a sword - how does that change weight
   and balance?

4. **Container capacity**: A quiver holds arrows by count AND by volume. A backpack
   has weight AND volume limits.

5. **Consistency**: If body parts, weapons, and armour all have mass, they should
   express it the same way.

## Proposed: PhysicalProperties Struct

A shared struct for anything with physical presence.

### Design Choice: Length + Volume over Bounding Box

Full bounding box (L×W×D) invites awkward questions: "Can I fit this sideways?"
"What about diagonal?" Orientation-aware packing is complex and probably not fun.

**Preferred heuristic: length + volume.**

- **Length**: longest dimension. "Does it stick out?" A greatsword won't fit in a
  belt pouch regardless of volume because it's too long.
- **Volume**: total space occupied. "Is there room?" Sum of item volumes vs
  container capacity.

This sidesteps rotation questions while capturing the two things that actually
matter for inventory constraints.

```zig
pub const PhysicalProperties = struct {
    // Mass in kg
    mass_kg: f32,

    // Longest dimension in meters (for "does it fit lengthwise" checks)
    length_m: f32,

    // Total volume in liters (for capacity checks)
    // Using liters rather than m³ for human-readable numbers
    volume_l: f32,

    // For "can X fit in Y" checks
    pub fn fitsIn(self: PhysicalProperties, container: ContainerProperties) bool {
        return self.length_m <= container.max_length_m and
               self.volume_l <= container.available_volume_l;
    }
};

pub const ContainerProperties = struct {
    // Internal length (longest item that fits)
    max_length_m: f32,

    // Total internal volume in liters
    capacity_l: f32,

    // Maximum weight container can hold
    max_mass_kg: f32,

    // Can it flex to accommodate odd shapes?
    flexible: bool,
};
```

## Integration Points

### Weapons

`weapon.Template` gains `physical: PhysicalProperties`:

```zig
pub const Template = struct {
    physical: PhysicalProperties,

    // Combat-specific properties derived from physical
    moment_of_inertia: f32,  // could compute from mass + length
    balance_point: f32,
    // ...
};
```

Or: compute combat properties from physical properties where possible.

### Body Parts

`BodyPartGeometry` either becomes `PhysicalProperties` or includes it:

```zig
pub const BodyPartGeometry = struct {
    physical: PhysicalProperties,

    // Body-specific: surface area matters for coverage
    surface_area_m2: f32,

    // Tissue volume (different from bounding volume)
    tissue_volume_m3: f32,
};
```

A severed limb could then be treated as an Item with physical properties derived
from its `BodyPartGeometry`.

### Armour

Armour pieces gain physical properties:

```zig
pub const Template = struct {
    physical: PhysicalProperties,
    material: *const Material,
    pattern: *const Pattern,
    // ...
};
```

### Items (General)

All item templates include physical properties:

```zig
pub const ItemTemplate = struct {
    physical: PhysicalProperties,
    category: ItemCategory,
    // ...
};
```

### Containers

Container capacity expressed in terms of physical properties:

```zig
pub const ContainerProperties = struct {
    // Internal dimensions (what can fit inside)
    internal: PhysicalProperties,

    // Maximum weight the container can hold
    max_contents_mass_kg: f32,

    // Rigidity: can it flex to fit odd shapes?
    flexible: bool,
};
```

## Relationship to 3-Axis Damage Model

The recent T044 unification established 3-axis physics for damage:
- Geometry (penetration)
- Energy (momentum)
- Rigidity (structural support)

These are *interaction* properties - how things damage each other.

`PhysicalProperties` is about *existence* properties - how big, how heavy, where
does it fit.

They're related but distinct:
- `PhysicalProperties.mass_kg` feeds into energy calculations
- `PhysicalProperties.length_m` might inform reach
- But the 3-axis coefficients (`geometry_coeff`, `rigidity_coeff`) are about
  material/construction behavior, not raw dimensions

The two systems should be complementary, not redundant.

## Unit Standardization

Propose SI base units throughout:
- Mass: kg
- Length: m
- Volume: m³
- Area: m²

This means converting existing cm/mm values. One-time migration.

Derived units (cm², mm thickness) can be used in specific contexts where more
human-readable, but internal representation is SI.

## Migration Concerns

This touches:
- `weapon.Template` and all weapon definitions
- `body.BodyPartGeometry` and body plan definitions
- `armour.Template` and armour definitions
- CUE generation pipeline
- Any code computing mass/volume/dimensions

**Risk**: High. This is foundational. Getting it wrong means re-doing it.

**Mitigation**:
1. Design the struct carefully before implementing
2. Start with weapons (most constrained, already have mass/length)
3. Extend to items generically
4. Migrate body parts (most complex due to anatomy)
5. Review against inventory use cases before finalizing

## Open Questions

1. **Irregular shapes**: A sword isn't a box. How much does actual_volume_m3 matter
   vs bounding box? Is packing efficiency a gameplay concern?

2. **Composition**: If I attach a basket hilt, how do physical properties combine?
   Simple addition? Or does the composite need explicit definition?

3. **Body parts**: Are severed limbs literally items? Or a special case? If items,
   they need physical properties derived from anatomy.

4. **Carried weight vs worn weight**: Wearing armour distributes weight across the
   body. Carrying a backpack concentrates it. Does the model need to distinguish?

5. **Dynamic properties**: A full waterskin weighs more than an empty one. Do we
   track this? Or is it "full waterskin" and "empty waterskin" as separate item
   states?

## Engineering Concerns

This is the hardest piece of the inventory system because it touches load-bearing
code that already works.

### Why This Is Scary

1. **Three partial representations exist and work**:
   - `weapon.Template`: mass, length, balance_point, moment_of_inertia
   - `body.BodyPartGeometry`: area_cm2, length_cm, circumference_cm
   - `armour.Material`: thickness (mm), density (implicit)

   Each evolved for its specific domain. Unifying risks breaking what works.

2. **The 3-axis damage model depends on these**:
   - Weapon physics feed into energy calculations
   - Body geometry determines hit areas and tissue volumes
   - Armour thickness/density drive protection calculations

   Changes here ripple through `resolution/damage.zig`, `resolution/outcome.zig`,
   `body.applyDamage()`, `armour.resolveThroughArmour()`.

3. **Data migration is substantial**:
   - All CUE definitions need updating
   - Generated code changes
   - Test fixtures need migration
   - Any hardcoded values in tests

### Research Touchpoints

Before implementation, audit:

1. **`weapon.Template`** (src/domain/weapon.zig):
   - Which fields are "existence" (mass, length) vs "interaction" (coefficients)?
   - Can mass_kg and length_m be factored out cleanly?

2. **`body.BodyPartGeometry`** (src/domain/body.zig):
   - Currently uses cm/cm². Convert to m/m²?
   - How does this interact with species scaling (`SizeModifiers`)?
   - Can we derive volume from existing geometry?

3. **`armour.Material`** and **`armour.Template`** (src/domain/armour.zig):
   - Thickness and density are interaction properties (for damage calc)
   - Do we need separate existence properties (mass, bulk)?
   - How does coverage area relate to volume?

4. **Damage resolution pipeline**:
   - Where does mass currently feed in? (energy = ½mv²)
   - Where does length feed in? (reach calculations)
   - What would break if we changed the source of these values?

5. **CUE schema** (data/*.cue):
   - Current field names and units
   - What can be derived vs what must be specified?

## Recommendation

This is necessary but high-stakes. Approach carefully:

### Sequencing

1. **After shared EntityID** - Don't do this until entity identity is clean
2. **Before Item system** - Items need physical properties to exist

### Plan for a Plan

Before writing code:

1. **Audit existing representations**: Document exactly what exists, where, and
   what depends on it. Map the dependency graph.

2. **Identify the minimal struct**: What fields are actually needed for inventory?
   (mass_kg, length_m, volume_l). What's nice-to-have? What's domain-specific?

3. **Design the migration path**: Can we add `PhysicalProperties` alongside
   existing fields first, then deprecate? Or must it be a flag-day change?

4. **Prototype on weapons only**: They're the most constrained (already have
   mass/length) and least entangled with other systems.

5. **Write the CUE schema change**: See what the data migration actually looks
   like before committing to the Zig changes.

### The 3-Axis Lesson

The recent T037/T044 unification was painful but worth it. Key lessons:
- Do it once, do it right
- Migration is the hard part, not the new code
- Tests catch regressions - ensure coverage before changing
- Generated data is your friend (change CUE, regenerate, done)

This deserves the same discipline.
