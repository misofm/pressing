# miso-drop

The Miso drop — the primary sale that mints `Record`s, on Sui. "Drop your Record
on Miso."

A `Drop<Currency>` is a shared, **immutable** primary sale for one *edition* of a
release. It never gates *who* can buy — supply is uncapped and access is open; how rare
a record becomes is about how its owner engages with it over time, not manufactured
scarcity at the point of sale.

## Design

- **Editions.** Drop UIDs are derived off a shared `DropRegistry` keyed by
  `(release_id, edition)`, giving deterministic addressing and **gap-free** per-release
  runs: `0, 1, 2, …` (creating edition `n` requires `n-1` to exist; duplicates abort).
- **Price.** `Fixed` (pay exactly) or `Floor` (pay ≥, overpayment kept as a tip). The
  whole payment forwards to the release's address; the record stores what was paid.
- **Window (the only mechanic).** Sells within `[start, end?]`; `end` is optional
  (`none` = evergreen, always buyable). Liveness is a pure function of the clock — no
  manual pause. End a limited run with a close set up front; offer more with a new
  edition.
- **Records derive off the drop.** Each `buy` mints a `Record` whose UID is derived off
  the `Drop`'s UID keyed by its 1-based serial number, so every copy is
  deterministically addressable and a given number can be minted at most once.
- **Minting is authorized by type.** `buy` presents this package's `MintWitness` to
  `miso_record`'s witness-gated `mint_derived`; the witness type must be on the
  `miso_record::Settings` allowlist. A different sale mechanic (auction, dutch,
  giveaway…) is just another package with its own witness — same `Record`, no
  `miso_record` redeploy.

## Layout

```
move/
  sources/drop.move     miso_drop — the Drop sale, registry, and events
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
