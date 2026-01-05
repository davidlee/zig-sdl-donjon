# Presentation Layer Refactoring Plan

## COMPLETED (Sessions 1 + 2)

**All phases completed:**
- [x] Phase 1: types.zig created, view.zig updated as compatibility layer
- [x] Phase 2: card/model.zig, card/data.zig, card/zone.zig, card/mod.zig created
- [x] Phase 3: combat/hit.zig, combat/play.zig, combat/button.zig, combat/avatar.zig, combat/status_bar.zig, combat/view.zig created
- [x] Phase 4: All views renamed to `View` (title, menu, summary, chrome)
- [x] Session 2: combat_view.zig → combat/view.zig (CombatView → View)
- [x] Session 2: EndTurnButton → combat/button.zig (EndTurn)
- [x] Session 2: PlayerAvatar, EnemySprite, Opposition → combat/avatar.zig
- [x] Session 2: status_bar_view.zig → combat/status_bar.zig (StatusBarView → View)
- [x] Session 2: ChromeView → chrome.View
- [x] Session 2: Deleted deprecated card_view.zig, combat_view.zig, status_bar_view.zig

**Build status:** Compiles, tests pass, formatted

**Key notes:**
- CardZoneView stays in combat/view.zig (it's combat-coupled)
- view.zig remains as the barrel file (Phase 5 skipped - optional, current structure works)
- Domain coupling issue documented below for future work

**Final file structure:**
```
src/presentation/views/
├── view.zig             (View union, re-exports types)
├── types.zig            (shared Renderable, AssetId, InputResult, etc.)
├── card/
│   ├── mod.zig          (barrel exports)
│   ├── model.zig        (Model, Kind, Rarity, State)
│   ├── data.zig         (Data, Source)
│   └── zone.zig         (Layout only)
├── combat/
│   ├── mod.zig          (barrel exports: View, Zone, Hit, EndTurn, Player, Enemy, Opposition, StatusBar)
│   ├── view.zig         (View - main combat view, ~600 lines with CardZoneView)
│   ├── hit.zig          (Zone, Hit, Interaction)
│   ├── play.zig         (Data, Zone for plays)
│   ├── button.zig       (EndTurn)
│   ├── avatar.zig       (Player, Enemy, Opposition)
│   └── status_bar.zig   (View)
├── title.zig            (View)
├── menu.zig             (View)
├── summary.zig          (View)
└── chrome.zig           (View)
```

---

## Goal
Refactor `src/presentation/views/` to:
1. Follow Zig naming idiom (`module.Type` not `module_type.ModuleType`)
2. Extract reusable card components for future inventory/deck builder screens
3. Document domain coupling issue for future work
4. Establish scalable directory patterns

## Target Structure

```
src/presentation/views/
├── mod.zig              (View union + re-exports, replaces view.zig)
├── types.zig            (shared Renderable, AssetId, etc.)
├── card/
│   ├── mod.zig          (barrel exports)
│   ├── model.zig        (CardViewModel → Model, CardState → State)
│   ├── data.zig         (CardViewData → Data, Source enum)
│   └── zone.zig         (CardZoneView → Zone, CardLayout → Layout)
├── combat/
│   ├── mod.zig          (barrel exports)
│   ├── view.zig         (CombatView → View, ~400 lines after extraction)
│   ├── play.zig         (PlayViewData → Data, PlayZoneView → Zone)
│   ├── hit.zig          (ViewZone, HitResult, CardViewState)
│   ├── button.zig       (EndTurnButton → EndTurn)
│   ├── avatar.zig       (PlayerAvatar, EnemySprite, Opposition)
│   └── status_bar.zig   (StatusBarView → View)
├── title.zig            (TitleScreenView → View)
├── menu.zig             (MenuView → View)
├── summary.zig          (SummaryView → View)
└── chrome.zig           (ChromeView → View)
```

## Naming Changes

| Old | New | Access |
|-----|-----|--------|
| `combat_view.CombatView` | `combat.View` | `views.combat.View` |
| `splash.TitleScreenView` | `title.View` | `views.title.View` |
| `card_view.CardViewModel` | `card.Model` | `views.card.Model` |
| `status_bar_view.StatusBarView` | `combat.status_bar.View` | `views.combat.status_bar.View` |

## Execution Phases

### Phase 1: Infrastructure
1. Create `views/types.zig` - extract from view.zig: logical_w/h, Point, Rect, Color, AssetId, Renderable union, InputResult
2. Update `view.zig` to import from types.zig (temporary compatibility layer)

### Phase 2: Card Components (reusable)
3. Move `card_view.zig` → `card/model.zig`, rename: CardViewModel→Model, CardKind→Kind, etc.
4. Create `card/data.zig` - extract CardViewData, Source from combat_view.zig:47-75
5. Create `card/zone.zig` - extract CardZoneView, CardLayout from combat_view.zig:154-337
6. Create `card/mod.zig` barrel
7. Update combat_view.zig imports to use card/

### Phase 3: Combat Extraction
8. Create `combat/hit.zig` - extract ViewZone, HitResult, CardViewState
9. Create `combat/play.zig` - extract PlayViewData, PlayZoneView
10. Create `combat/button.zig` - extract EndTurnButton→EndTurn
11. Create `combat/avatar.zig` - extract PlayerAvatar, EnemySprite, Opposition
12. Move `status_bar_view.zig` → `combat/status_bar.zig`, rename StatusBarView→View
13. Refactor remaining combat_view.zig → `combat/view.zig`
14. Create `combat/mod.zig` barrel

### Phase 4: Other Views
15. Rename `splash.zig` → `title.zig`, TitleScreenView→View
16. Update `menu.zig`: MenuView→View
17. Update `summary.zig`: SummaryView→View
18. Update `chrome.zig`: ChromeView→View

### Phase 5: Finalize
19. Replace `view.zig` with `mod.zig` (update View union imports)
20. Update `coordinator.zig` imports
21. Update `presentation/mod.zig` exports
22. Delete old files, clean up empty dirs
23. Run tests + lint

## Files Modified

**Primary extraction source:**
- `src/presentation/views/combat_view.zig` (1,118 lines → ~400 after split)

**Import updates needed:**
- `src/presentation/coordinator.zig`
- `src/presentation/mod.zig`
- `src/presentation/graphics.zig` (if imports card_view)

## Domain Coupling (Future Work)

**Problem:** combat/view.zig calls `apply.*` validation functions directly:
- `apply.validateCardSelection()` - card playability
- `apply.canModifierAttachToPlay()` - drag validation
- `apply.resolvePlayTargetIDs()` - targeting arrows

**Why problematic:** Violates architecture (views should be read-only lenses), makes testing harder, business logic leaks into presentation.

**Next actions:**
1. Decide approach: query methods on Agent/World vs precomputed flags vs validation service
2. Add query interface to domain layer
3. Update view to use queries
4. Remove apply.zig import from view

**Document at:** `doc/future/view-domain-coupling.md`
