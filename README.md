# miso-drop

The Miso drop — the primary sale that mints `Record`s, on Sui. "Drop your Record
on Miso."

A drop is three objects, each answering one question and nothing else:

```
Release
 └─ Drop                     which release is selling      DropKey()
     └─ Edition (n)          which run, and how many       EditionKey(n)
         ├─ Listing<SUI>     what it costs, and when       ListingKey(TypeName)
         └─ Listing<USDC>
```

## Design

- **Everything is address math.** A `Drop`'s UID is derived off its `Release`'s UID at a
  singleton key, an `Edition`'s off the drop's at its number, a `Listing`'s off the
  edition's at its currency type. Every object in the tree is reachable from the release
  id alone, by pure computation — no registry, no package-level shared state, no pointer
  to maintain. `Drop.editions` says how far the sequence runs; `derive_id` does the rest.
  The counter also makes the sequence gap-free for free: it picks every number, and a
  derived key can be claimed only once.

- **The edition owns the run.** Supply and the serial sequence live on the `Edition`, and
  `Record` UIDs derive off it — so "number 7 of 500" means the same thing no matter which
  currency paid for it. `Supply` is `Uncapped` or `Capped { max }`, fixed at creation.

- **The listing owns the offer.** Price and window, per currency, and nothing else. An
  edition sold in SUI and USDC has two listings drawing on one cap and one serial
  sequence. `Price` is `Fixed { amount }` (pay exactly) or `Floor { amount }` (pay ≥,
  overpayment kept as a tip); `Window` is `Unbounded { start }` or `Bounded { start, end }`.
  Liveness is never stored — it is a pure function of the window against the clock and the
  cap against the count. The whole payment forwards to the release's address.

- **Editions are runs, not variants.** First edition, second edition — the card-collector
  sense, a signal that you were there early. A deluxe version has different tracks, so it
  is a different `Release` and therefore a different `Drop`; a drop's editions can only
  ever be successive runs of the same record. Opening edition `n + 1` does **not** seal
  edition `n`: an artist who wants the 1st edition to be genuinely scarce seals it first,
  and one who would rather keep selling doesn't. Scarcity stays the artist's choice.

- **A run knows what it is still carrying.** `EditionState` is a three-step machine, and
  its first two steps hold the set of currencies the run currently has listings standing
  in:

  ```
  Listed { currencies } ──seal / sold out──▶ Sealed { currencies } ──last one──▶ Closed
  ```

  Listings register on the way up and unregister on the way down, so the set is what is on
  chain *right now* — never a log of everything ever tried. `Sealed` is the cleanup state:
  nothing can sell, so anyone may close what is left, and the run reaches `Closed` exactly
  when the last listing comes down. A `Capped` run seals itself the moment it mints its
  last record, so a sell-out never waits on the artist to notice.

- **Nothing outlives its usefulness.** Closing a listing *is* destroying it — there is no
  status field, because the only states worth naming are terminal. `withdraw` is the artist
  pulling an offer at will; `close` is anyone clearing up one that has already finished
  (window elapsed, or the run over), and it is permissionless precisely because every
  condition it accepts already makes `buy` abort — so a finished offer never sits waiting
  for someone to remember it. An expired listing can be cleared while the run is still
  selling in other currencies. The reason rides on `ListingClosedEvent`, where an indexer
  wants it and where it cannot drift.

  Drops and editions are the exception, and stay forever even when `Closed`: their claim
  markers are what stop an edition number or a currency slot from ever being reused, and
  the edition holds the denominator — without it "number 7 of 500" is only "number 7".

  The markers also give clients a three-way read with no stored state: **no marker** means
  never listed, **a marker with no object** means closed, **an object** means sellable.

- **Minting is authorized by type.** `buy` presents this package's `MintWitness` to
  `miso_record`'s witness-gated `mint_derived`; the witness type must be on the
  `miso_record::Settings` allowlist. A different sale mechanic (auction, dutch, giveaway…)
  is just another package with its own witness — same `Record`, no `miso_record` redeploy.

## Usage

`drop::new` and `drop::next_edition` return the `Edition` **unshared**, so one transaction
can list it before `edition::share` puts it on chain:

```move
let mut edition = drop::new(&mut release, &cap, edition::new_capped_supply(500));
listing::new<SUI>(&mut edition, &cap, listing::new_fixed_price(10), window, &clock);
listing::new<USDC>(&mut edition, &cap, listing::new_fixed_price(25), window, &clock);
edition.share();
```

Then, per sale:

```move
let record = listing.buy(&mut edition, payment, &settings, &clock, ctx);
```

Adding a currency to a live run is just another `listing::new` — no new edition, and no
change to the run's cap or serials. Ending a run is `edition::seal` (or its last sale).
Winding it down is `listing::close`, once per standing listing:

```move
listing.close(&mut edition, &clock);   // permissionless once it can no longer sell
```

Starting the next run is `drop::next_edition`.

## Layout

```
move/
  sources/drop.move        the namespace and the edition counter
  sources/edition.move     the run: supply, serials, sealing, the mint witness
  sources/listing.move     one currency's offer: price, window, buy, close
  tests/
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
