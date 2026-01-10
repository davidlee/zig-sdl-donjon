# Physical Interface Design

**Status:** Draft
**Related:** [Problem statement](../issues/physical_properties_unification.md)
**Depends on:** T047 (EntityID unification)
**Enables:** Item system, inventory constraints

## Summary

A minimal derived interface for physical properties, enabling inventory operations
without restructuring existing domain representations.

## The Interface

```zig
/// Minimal physical properties for inventory operations.
/// Type-erased interface pattern (see ai.Director for precedent).
pub const Physical = struct {
    ptr: *const anyopaque,

    lengthFn: *const fn (ptr: *const anyopaque) f32,
    volumeFn: *const fn (ptr: *const anyopaque) f32,
    massFn: *const fn (ptr: *const anyopaque) f32,

    /// Longest dimension in meters.
    /// "Does it fit lengthwise?" A halberd won't fit in a backpack.
    pub fn length_m(self: Physical) f32 {
        return self.lengthFn(self.ptr);
    }

    /// Total volume in liters.
    /// "Is there room?" Sum of item volumes vs container capacity.
    pub fn volume_l(self: Physical) f32 {
        return self.volumeFn(self.ptr);
    }

    /// Mass in kilograms.
    /// "Can I carry this?" Encumbrance, weight limits.
    pub fn mass_kg(self: Physical) f32 {
        return self.massFn(self.ptr);
    }
};
```

**Location:** `src/domain/physical.zig` (new file)

### Performance Note

The type-erased interface incurs vtable dispatch overhead. For templates (weapons,
armour), the underlying data is static — the same weapon template always returns
the same mass. If inventory UI queries dozens of items frequently, consider:

1. **Cache physical values** in the item instance at creation time
2. **Add static `PhysicalTraits` struct** to templates alongside the interface

For now, the interface is sufficient. Measure before optimising.

## Why This Shape

### Length + Volume, Not Bounding Box

Full bounding box (L×W×D) invites awkward questions: rotation, diagonal packing,
orientation-aware fitting. These are simulation rabbit holes, not fun.

The heuristic captures the two failure modes that matter:
- **Too long:** halberd won't fit in backpack regardless of volume
- **Too bulky:** watermelon won't fit in coin purse regardless of length

### Derived Interface, Not Unified Storage

Existing representations evolved for their combat roles:
- Body parts: TARGET geometry (cross-section, penetration depth)
- Weapons: SOURCE physics (momentum, energy transfer)
- Armour: BARRIER properties (deflection, absorption)

These aren't accidental divergence — they're domain-appropriate. The `Physical`
interface is a projection for a *different* concern (inventory), not a replacement.

## Implementation by Domain

### Body Parts

**Derivation:** From existing `BodyPartGeometry`.

```zig
// On body.PartDef or as standalone function:
pub fn physical(self: *const PartDef) Physical {
    return .{
        .ptr = self,
        .lengthFn = lengthImpl,
        .volumeFn = volumeImpl,
        .massFn = massImpl,
    };
}

fn lengthImpl(ptr: *const anyopaque) f32 {
    const self: *const PartDef = @ptrCast(@alignCast(ptr));
    return self.geometry.length_cm / 100.0;
}

fn volumeImpl(ptr: *const anyopaque) f32 {
    const self: *const PartDef = @ptrCast(@alignCast(ptr));
    const g = self.geometry;
    // Cylinder approximation: V = π/4 × d² × h, convert cm³ to L
    return std.math.pi / 4.0 * g.thickness_cm * g.thickness_cm * g.length_cm / 1000.0;
}

fn massImpl(ptr: *const anyopaque) f32 {
    const self: *const PartDef = @ptrCast(@alignCast(ptr));
    // Tissue ≈ water density (1.0 kg/L)
    return volumeImpl(ptr);
}
```

**Schema changes:** None. Geometry already sufficient.

### Weapons

**Derivation:** From existing `weapon.Template` fields.

```zig
fn lengthImpl(ptr: *const anyopaque) f32 {
    const self: *const Template = @ptrCast(@alignCast(ptr));
    return self.length / 100.0;  // cm to m
}

fn volumeImpl(ptr: *const anyopaque) f32 {
    const self: *const Template = @ptrCast(@alignCast(ptr));
    // Weapons have negligible volume relative to length.
    // Conservative approximation: thin rod, ~50ml per meter.
    return self.length / 100.0 * 0.05;
}

fn massImpl(ptr: *const anyopaque) f32 {
    const self: *const Template = @ptrCast(@alignCast(ptr));
    return self.effective_mass;  // already in kg
}
```

**Schema changes:** None. Fields already exist.

**Note:** Volume approximation is deliberately crude. For inventory, weapon length
dominates — a sword doesn't fit in a pouch regardless of its actual volume.

### Armour

**Derivation:** Not cleanly derivable. Armour's combat properties (thickness,
material response) don't map to inventory properties (stowed dimensions, total mass).

**Solution:** Add explicit fields to `armour.Template`:

```zig
pub const Template = struct {
    id: u64,
    name: []const u8,
    material: *const Material,
    pattern: *const Pattern,

    // Physical properties for inventory (not derivable from combat properties)
    mass_kg: f32,
    stowed_length_m: f32,  // longest dimension when carried/stored
    stowed_volume_l: f32,  // volume when not worn
};
```

**Schema changes:** Add to CUE schema, populate for existing armour definitions.

**Rationale:** Armour data is currently sparse. Adding three fields is trivial.
The alternative (deriving from coverage × thickness × density) requires:
- Adding density to Material
- Summing covered body part areas (coupling to body geometry)
- Defining "length when stowed" (meaningless derivation)

Explicit is cleaner.

**For authors:** These fields exist because armour's combat properties (how it
stops damage) are unrelated to its inventory properties (how much space it takes).
A mail hauberk and a plate cuirass might have similar protection but very different
stowed volume. If armour data grows significantly and this becomes tedious, we can
revisit deriving mass from `material.density × coverage_area × thickness` — but
that couples armour to body geometry and still can't derive stowed dimensions.

**Schema migration:** Add defaults (`mass_kg: 0`, etc.) so existing armour compiles.
Authors fill in real values as armour definitions are fleshed out.

## Container Properties

For completeness, containers need capacity constraints:

```zig
pub const Container = struct {
    max_length_m: f32,      // longest item that fits
    capacity_l: f32,        // total internal volume
    max_mass_kg: f32,       // weight limit
    flexible: bool,         // can it flex to accommodate odd shapes?

    pub fn canFit(self: Container, item: Physical) bool {
        return item.length_m() <= self.max_length_m and
               item.volume_l() <= self.capacity_l and
               item.mass_kg() <= self.max_mass_kg;
    }
};
```

This is future work — noted here for completeness.

**Coupling note:** Containers need to track:
- `available_volume_l` — capacity minus contents
- `current_mass_kg` — sum of contained item masses
- Child item references

This couples tightly with the Item system design. Container logic should be
designed alongside items, not before. The `Physical` interface is a prerequisite
(containers need to query item properties), but container *behaviour* is Item
system scope.

## Migration Path

1. **Create `src/domain/physical.zig`** with interface definition
2. **Add `physical()` to `body.PartDef`** — pure addition, no breakage
3. **Add `physical()` to `weapon.Template`** — pure addition
4. **Extend armour CUE schema** — add `mass_kg`, `stowed_length_m`, `stowed_volume_l`
5. **Regenerate armour data** — populate new fields
6. **Add `physical()` to `armour.Template`** — reads new fields

No flag-day migration. Each step is independently testable.

## Open Questions

1. **Worn vs carried weight:** Wearing armour distributes weight across the body.
   Carrying concentrates it. Does the model need to distinguish? Probably not
   for MVP — encumbrance can treat all weight equally.

2. **Dynamic properties:** A full waterskin weighs more than empty. Track as
   item state, or separate item definitions? Defer to Item system design.

   The `Physical` interface supports this — stateful items implement `physical()`
   to return current values, not template values. A waterskin item queries its
   fill level and computes mass accordingly. The interface doesn't assume static
   data.

3. **Composition:** Sword + gem pommel — how do properties combine? Defer to
   Item system design. Likely: composite items have explicit properties.

## Sequencing

```
T047 EntityID ──► Physical Interface ──► Item System
     (in progress)     (this doc)          (future)
```

Do not start until T047 lands. The Item system depends on this.

**T047 coordination:** Ensure EntityID unification accounts for items as entities.
The `Physical` interface adds another layer of type erasure; we don't want to
immediately undo T047's consolidation. Items should use the unified EntityID,
and `Physical` should be an interface *on* item entities, not a parallel identity
system.

## Implementation Notes

When implementing `physical()` for each domain:

1. **Add sensible defaults to armour schema** so existing definitions compile.
   Authors populate real values incrementally.

2. **Write sanity-check tests:**
   - Halberd length > backpack max_length
   - Finger volume < torso volume
   - Plate armour mass > leather armour mass
   - etc.

3. **Coordinate with Item system card** to ensure items expose `Physical` once
   stateful items exist. The interface is defined here; usage is Item scope.
