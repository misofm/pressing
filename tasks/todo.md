# miso-drop restructure — Drop / Edition / Listing

## Decisions (settled in conversation)

- **`Drop`** — per-release namespace + edition counter. Derived off the `Release` UID at a
  singleton `DropKey()`. No `Currency` phantom. Never destroyed, no state enum.
### Revision — the wind-down state machine

The first pass left finished listings on chain indefinitely: `close` was optional, and
`Edition.currencies` was an append-only log of every currency ever listed. Replaced with a
three-step machine that owns the wind-down, where the first two states carry the set of
listings still standing:

```
Listed { currencies } ──seal / sold out──▶ Sealed { currencies } ──last one──▶ Closed
```

- `listing::new` registers; `close` / `withdraw` unregister. The set is what is on chain
  now, not a log. Both take `&mut Edition` as a result.
- A `Capped` run seals itself on its last mint, so cleanup never waits on the artist.
- Taking the last listing off a `Sealed` run closes it — `Closed` is a fact the chain
  states, not one an indexer infers.
- A listing whose window elapsed can be cleared while the run is still selling in other
  currencies. (Deviation from the sketch, which only allowed teardown in the wind-down
  state — that would have made expired listings linger longer, not less.)
- `ESoldOut` is now unreachable (auto-seal fires first). Kept as an invariant guard, in the
  same spirit as the old `ENonSequentialEdition` claim-site assert.

### Original decisions

- **`Edition`** — one sequential run (1st edition, 2nd edition — an earliness signal, not
  standard-vs-deluxe; a deluxe version has different tracks, so it is a different `Release`
  and therefore a different `Drop`). Derived off the `Drop` at `EditionKey(n)`.
  Owns the supply cap AND the serial sequence — `Record`s derive off the **Edition**, so
  "number 7 of 500" means the same thing regardless of which currency paid for it.
  Never destroyed. `EditionState::{Open, Sealed}` — sealing is artist-triggered and
  irreversible.
- **`Listing<Currency>`** — price + window for one currency. Derived off the `Edition` at
  `ListingKey(TypeName)`. Destroyed to close; closing *is* destruction, so there is no
  status field. The reason lives in the close event, not in storage.
- Opening edition `n + 1` does **not** seal edition `n`. Whether to close a run is the
  artist's call, consistent with "scarcity is the artist's choice, not a protocol stance."
- Naming rejected along the way: `Pressing` (vinyl jargon), `Distributor` / `Label`
  (org-level, category error), `Factory` (software-pattern register), `Shop` (a shop
  selling one record isn't a shop), `Mint` (crypto register).

## What this removes

- `Drop<Currency>` phantom and the two-currency `new_edition<Old, New>`.
- The consuming `new_edition` — editions are permanent now, nothing is destroyed.
- `ENonSequentialEdition` and its claim-site guard — the counter on `Drop` plus
  claim-once is the invariant.
- `CurrentDropKey` — with `Drop.editions`, every address in the tree derives from the
  release id alone. Discovery is address math, not a pointer.

## Authority

`release_admin_cap_release_id(cap)` (miso-protocol `release.move:315`) means only
`drop::new` needs the `Release` object. Every later call — `next_edition`, `seal`,
`list`, `withdraw` — authorizes against the cap alone by comparing to `release_id`.

## Tasks

- [x] `sources/drop.move` — `Drop`, `DropKey()`, `new`, `next_edition`, views
- [x] `sources/edition.move` — `Edition`, `EditionKey(u32)`, `Supply`, `EditionState`,
      `MintWitness`, package-visible `mint_next`, `seal`, `share`, views
- [x] `sources/listing.move` — `Listing<Currency>`, `ListingKey(TypeName)`, `Price`,
      `Window`, `CloseReason`, `new`, `buy`, `close`, `withdraw`, views
- [x] Delete the old single-module `drop.move` surface
- [x] Rewrite `tests/drop_tests.move` → `test_utils` + three per-module test files
- [x] `sui move test` green — 38 tests, no warnings
- [x] Update `README.md`
- [ ] Follow-up (separate, not in this change): `miso-record` `is_derived_from` doc comment
      says "e.g. a `Pressing`'s ID" — stale vocabulary, should read `Edition`.

## Review

**Departed from the plan in one place.** The plan had `launch<Currency>` and a matching
`next_edition_with_listing<Currency>` as convenience entry points, to avoid spending a
transaction on a drop that isn't listed yet. Both are unnecessary: `drop::new` and
`drop::next_edition` return the `Edition` **unshared** and `edition::share` is public, so a
PTB composes the whole flow — open, list in as many currencies as it likes, share — without
the package having to anticipate the combinations. Two entry points instead of four, and
the value has no `drop` ability, so a caller cannot lose an edition by forgetting to share
it. This also made the suite testable without `test_scenario` in most cases.

**`buy` takes `&TxContext`, not `&mut`.** Nothing on the path needs mutation.

**Coverage.** All 27 behaviors the old single-module suite asserted are carried over,
against the new shape. New ground: one edition selling in two currencies off one cap and
one serial sequence (`one_edition_sells_in_two_currencies_off_one_cap`), sealing, the four
close paths and their permissionlessness, and claim-once on both `DropKey()` and a
currency's listing slot.

**Not done, deliberately.** No republish. The witness type moved from
`miso_drop::drop::MintWitness` to `miso_drop::edition::MintWitness`, so whatever
`miso_record::Settings` authorizes has to be re-authorized against the new package — worth
handling as part of the deploy, not here.
