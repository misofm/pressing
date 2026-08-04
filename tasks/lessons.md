# Lessons

- **Discuss before diff on design decisions.** During the 2026-07 redesign I
  implemented a struct change (removing `number` from `Record`) straight from a
  design conversation without asking first. Rule: when the user is exploring a design
  ("what do you think", "I wonder if"), the deliverable is a position and a
  consensus check — the diff comes after explicit agreement. Reversibility of the
  change does not waive this.
- **Check what a mechanism actually constrains before citing it.** I claimed deleting
  `Settings` was required to make miso_record immutable; wrong — immutability freezes
  code, and Settings is *state*, which stays mutable under a frozen package. Trace
  the actual coupling before using it as an argument.
- **Naming: plain beats precise-but-affected, and the app's existing vocabulary wins.**
  "Pressing" was rejected when it named an edition batch, then chosen when it named
  the production facility — because the app already spoke it (pressing routes,
  pressing.ts). Align chain vocabulary with product vocabulary.
