• Feint’s current implementation really is “pay 1 Focus to zero‑out your own card and maybe tweak advantage a bit,” so
  it rarely pulls its weight.

  - In src/domain/card_list.zig:706-739 it’s just a commit-phase modifier: .damage_mult = 0, .cost_mult = 0.5,
    replace_advantage gives small control nudges if the defender blocks/parries, and only a mild penalty when they
    ignore it. With no guaranteed follow-up, you’ve effectively spent a card slot plus Focus to do nothing unless the
    opponent flinches.
  - None of the sequencing hooks from the older design write-up (doc/archived/focus_design.md:287-353, :481-579) are
    wired in. There’s no “if you feinted last turn, riposte gains X” predicate, no “wasted defense” condition, and no
    event for the UI/domain to capitalize on.
  - Because our AI rarely over-commits to blocks and players don’t have reaction costs tied to failed reads yet (doc/
    stance_design.md:84-90), those advantage tweaks almost never swing an encounter. It becomes a worse version of
    simply holding a card to watch the opponent.

  If we want Feint to matter, we probably need changes beyond just tuning the numbers:

  1. Create a tangible game-state hook: e.g., emit a feint_succeeded event whenever the defender expends a defensive
     action on it, then let subsequent cards check for that event or set a short-lived condition that buffs the next
     attack. That honors the sequencing ideas already sketched in the focus design doc.
  2. Let Feint threaten tempo: consider refunding some time/stamina immediately (so you can queue another play sooner)
     or explicitly draining the defender’s time when they bite. Right now .cost_mult = 0.5 only affects your own play
     cost; it doesn’t punish the defender unless their card’s advantage profile happens to look at .replace_advantage.
  3. Integrate with the upcoming drag/multi-weapon work: if we’ll already touch Play for channel overrides (T028/T027),
     we could add a flag that marks a play as “revealed feint,” allowing you to drag it off the timeline mid-selection
     without the normal penalties. That makes feint a safer scouting action.

  In short, you’re not missing anything—Feint is unfinished. Either we finish the supporting systems (reaction costs,
  sequencing predicates, event-driven follow-ups) or we overhaul the card to deliver an immediate, obvious benefit;
  otherwise it’ll keep feeling like a dead slot.