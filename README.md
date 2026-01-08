# DECK OF DWARF: a card game about killing Gobbo scum

This is an experimental deck-building dungeon battler written in Zig (0.15.2) with SDL3 bindings.

The game is about simultaneous disclosure, information asymmetry, and ludicrous simulated detail.

There are no health bars; only bone, tissue penetration, and vital organ trauma.

Happily, Dwarves regenerate in the presence of alcohol (although the process isn't kind to the alcohol).

Success in combat is about anticipating your opponent, carefully conserving stamina, probing and exploiting to gain an advantage, and pressing it at the right time (without over-extending) to land a decisive hit.

Everything is a card, drawn at random from your deck; but your inventory is modelled in autistic detail. Gambeson can be layered under chain; munitions plate is nearly impervious, but leaves your joints vulnerable to a rondel dagger.

Think of it as an attempt to answer the question nobody ever asked: what if Dwarf Fortress fell into a teleporter with Slay the Spire and Balatro?

design goals:
  - power & flexibility from simplicity and composition
  - independent systems designed with sympathy for the core card mechanics, as well as system-specific exensions
  - DRY / SRP / well-architected elegant composability; data driven programming
  - clean boundaries between decoupled systems; bleeding is bleeding, in or outside of combat
  - create emergent, interesting tactical complexity from clean composition of simple parts
  - model"realism" - fundamentally believable, historically resonant, but with scope for added interest from magical effects
  - strong boundaries and clarifying rules: pure domain, separation of presentation from rendering
  - event and command driven interactions
  - symmetry: wherever possible, the same rules apply for players and opponents
  - richness, not complexity 
  - smart, not clever
  - Losing is Fun!

Current State: pre-alpha. Crappy graphics; incomplete core gameplay loop; more ideas modelled than wired up; plenty of core data (e.g. a definitive list of cards) still missing.

