# miso-drop

The Miso drop — the primary sale that mints `Record`s, on Sui. "Drop your Record
on Miso."

A `Drop<Currency>` is a shared, **immutable** primary sale for one *edition* of a
release. Scarcity is the artist's choice per edition — a supply cap, a time window,
both, or neither — and it's never a dead end: fans who miss a drop can always be
answered with a new edition. What a drop never has is an access gate: while it's
live, anyone may buy.

## Design

- **One live drop per release.** `new` opens edition `0`; `new_edition` opens
  edition `n + 1` by **consuming** edition `n` (the predecessor shared object is
  destroyed). Two editions can never sell side by side, the sequence is gap-free by
  construction, and — since a drop is immutable — `new_edition` is the only way to
  change anything: price, currency, cap, or window.
- **Scarcity knobs.** `max_supply` (`none` = open edition; `some(n)` = sells out at
  `n`) and a sale window `[start, end?]` (`end = none` = evergreen). Liveness is a
  pure function of the clock and the count: inside the window and not sold out.
- **Price.** `Fixed` (pay exactly) or `Floor` (pay ≥, overpayment kept as a tip). The
  whole payment forwards to the release's address; the record stores what was paid.
- **Deterministic addressing.** Drop UIDs are derived off a shared `DropRegistry`
  keyed by `(release_id, edition)`; claim markers outlive destroyed editions, so a
  key can never be reused. The registry also keeps `CurrentDropKey(release_id) → ID`
  pointing at the live drop (superseded drops are deleted, so clients resolve the
  current edition through the pointer, not address probing).
- **Records derive off the drop.** Each `buy` mints a `Record` whose UID is derived
  off the `Drop`'s UID keyed by its 1-based serial; serials restart each edition, so
  a record is "edition `e`, number `n` (of `max_supply`)". Records from destroyed
  editions stay verifiable — `record::is_derived_from` is pure address math.
- **Minting is authorized by type.** `buy` presents this package's `MintWitness` to
  `miso_record`'s witness-gated `mint_derived`; the witness type must be on the
  `miso_record::Settings` allowlist. A different sale mechanic (auction, dutch,
  giveaway…) is just another package with its own witness — same `Record`, no
  `miso_record` redeploy.

## Layout

```
move/
  sources/drop.move     miso_drop — the Drop sale, editions, registry, and events
  tests/drop_tests.move
```

Depends on [`miso-record`](https://github.com/misonetwork/miso-record) (the `Record` +
`Settings` mint authority) and the miso-protocol (`Release` / `ReleaseAdminCap`), as
sibling checkouts under `misonetwork/`:

```toml
miso = { local = "../../miso-protocol/move" }
miso_record = { local = "../../miso-record/move" }
```

## Build

```bash
cd move && sui move test
```

License: Apache-2.0
