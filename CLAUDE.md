- we're using zig 0.15.2
- IMPORTANT: code quality is more important than rate of progress. If you detect a code smell, it's worth immediately raising it with the user for discussion.
- concern yourself closely with coupling, cohesion, and intent-revealing naming.
- try to minimise the amount of code you add wherever possible - removing code is ideal
- don't make assumptions; stop and clarify the intended design before implementation.
- tests should focus on behaviour, not implementation

- DO NOT EVER introduce a new concept which could have been better (more flexibly, consistently & extensibly) 
  implemented using existing code or concepts. 
  -  In particular: cards (rules, predicates, effects, triggers, etc), weapons and armour are modelled 
     very flexibly. Understand them before you consider adding bespoke extensions.
