# miso-pressing

The Miso pressing — the production line that mints `Record`s, on Sui (package
`miso_pressing`).

A release has exactly one pressing, and the pressing is one uncapped run of records.
Each object answers one question and nothing else:

```
Release
 └─ Pressing              the run, and when it sells at all       PressingKey()
     ├─ PressingAdminCap  authority over price and state          PressingAdminCapKey()
     ├─ Listing<SUI>      what it costs in one currency           ListingKey<SUI>()
     └─ Listing<USDC>
```

## Design

- **One pressing, one sale run, no editions.** Every copy a release ever sells draws
  its canonical number from `RecordRegistry`'s per-release counter. The Pressing's
  `supply` is only the count sold through this sales implementation. There are no supply caps and no
  sold-out state — scarcity on Miso is what a record *accrues* over its life (playtime
  above all), not how few of it were printed. Bot pressure on a capped run is denial;
  on an uncapped one it is revenue.

- **Identity is address math.** A `Pressing`'s UID is derived off its `Release`'s UID
  at a singleton key (claim-once: a release can only ever open one pressing), the admin
  cap's and each `Listing`'s off the pressing's. There is **no stored set of listings**: a
  listing either exists at its derived address or it does not (`listing::has_listing`),
  and `ListingOpenedEvent<Currency>` enumerates them for an indexer. Record UIDs come
  from the separate singleton Registry, so the record id must equal
  `record::derive_address(registry_id, release_id, number).to_id()`. This preserves the
  namespace and numbering if Pressing is replaced wholesale.

- **The listing key is phantom-typed.** `ListingKey<Currency>()` puts the currency in
  the key's *type* rather than in a stored `TypeName`, so distinct currencies are
  distinct key types and `derived_object::claim` enforces once-per-currency by itself.
  That is what lets the pressing omit a currency set entirely.

- **The listing owns the offer, and it is permanent.** Price and state, per currency,
  and nothing else. A pressing sold in SUI and USDC has two listings drawing on one
  number sequence. `Price` is `Fixed { amount }` (pay exactly) or `Floor { amount }`
  (pay ≥, overpayment kept as a tip). A listing is never destroyed and never replaced:
  the offer changes *in place* (`set_price`, `set_state`), keeping its address and its
  identity through every change. Repricing cannot catch a buyer out — a `Fixed` buyer
  pays exactly, so a stale payment aborts against a new price, and a `Floor` buyer never
  pays more than the balance they sent. The whole payment forwards to the release's
  address. `RecordSoldEvent` snapshots both the accepted price and the amount paid, so
  an indexer can distinguish fixed sales from floor sales and compute tips without
  replaying price changes.

- **Payment is a `Balance<Currency>`, not a `Coin<Currency>`.** The money arrives from
  wherever the PTB got it — a withdrawal off the buyer's accumulator, a
  `coin::into_balance`, a split — and leaves immediately for the release's address via
  `balance::send_funds`. Nothing in that path needs an object id or an owner, so `buy`
  takes the bare value and never mints a coin just to unwrap it.

- **Two switches, and the schedule is run-wide.** The pressing walks
  `Scheduled { start } → Active → Paused → Active`, checked in `mint_next` so no sale
  path can miss it. `Scheduled` is the trustless opening time: nobody can buy before the
  start, and at the start the run opens itself with no artist transaction. Below it,
  each listing is `Enabled | Disabled`: one currency, leaving the others alone. A sale
  needs both open.

  The transition is **real, not computed**, and it lives in `mint_next` — a sale is
  the only thing that can reach it, and a sale already holds `&mut Pressing`. The first
  purchase past the scheduled start rewrites `Scheduled` to `Active` before any sales logic
  runs, so every later reader sees a plain `Active` run rather than a schedule it has to
  re-evaluate. It is the one state change no capability gates: the clock is the
  authority, and it only makes good on what the schedule already promised. Until that
  first sale nothing is stale in any way that matters — `is_selling(&clock)` reads a due
  `Scheduled` as selling, so nobody has to go first for the Pressing to be open.

  The cost is that the start time leaves the object at the transition:
  `start_timestamp_ms()` is `none` on a settled run. "When was this run scheduled for"
  is an event-log question — `PressingOpenedEvent` and `PressingStateChangedEvent` both
  carry the state, which is why the opened event breaks the pointer-event rule and
  carries a value at all.

  The **when** lives on the pressing rather than the listing because its opening time is a
  fact about the release going on sale, not about one payment rail — a run that opened
  in SUI at Friday 8pm and in USDC at some other time would have two starts and
  one number sequence. There is still no end state and no expiry: an uncapped,
  permanent run has nothing to count down to, and a time-limited sale is scarcity
  theater this design rejects. Ending a campaign is `set_state(Paused)`.

- **One concrete Record, one active sales witness.** `miso_record::Record` is Miso's
  distribution format, not a generic substrate. `pressing::MintWitness` is
  non-copyable and constructible only inside the `pressing` module; `mint_next` is its
  sole constructor path. The shared `miso_record::settings::Settings` must authorize
  that witness type before a listing can mint. This keeps one stable Record type while
  allowing Miso to replace the complete sales mechanism with one Settings update.
  `RecordRegistry`, not Pressing, is the UID parent and canonical per-release counter.
  Every purchase therefore mutates the same shared Registry object; this deliberate
  serialization is the cost of keeping identity stable across sales-package changes.

- **Records and sale events carry complementary provenance.** Record stores its
  Registry, release, number, creation time, purchase currency, and original purchaser.
  `RecordSoldEvent<Currency>` additionally snapshots the listing, pressing,
  release, Record, number, accepted price, paid amount, buyer, and clock timestamp.
  `RecordCreatedEvent` independently records the Registry, number, and authorized
  witness. Price and paid amount stay sale-specific.

- **Two caps, split along the money.** Opening a pressing needs the release's
  `ReleaseAdminCap` (the protocol's `release::uid_mut` enforces it) and hands back a
  `PressingAdminCap`; everything after — pricing, pausing, opening listings —
  authorizes against the pressing cap alone, asserting `cap.pressing_id` against the
  pressing. This is not tidiness. `ReleaseAdminCap` yields `release::uid_mut`, and
  `balance::withdraw_funds_from_object` is gated on `&mut UID` alone — so the release
  cap can withdraw the sales revenue `buy` forwards to the release's address. Under one
  cap, "may reprice a listing" and "may take the money" would be the same grant. The
  caps may be held together. If separated, the pressing cap remains issuance authority:
  it controls listing creation, price, and availability, but cannot withdraw revenue.
  Both are `key, store`, so a vault or multisig can custody them — the package implements
  no recovery.

- **Minting authority is explicit and replaceable.** Setting
  `miso_pressing::pressing::MintWitness` as the active witness enables this path;
  clearing or replacing it
  makes even an otherwise valid free or paid listing abort in `record::mint`. Settings
  is borrowed immutably on purchases. The Registry remains the intentionally mutable
  shared input.

## Usage

`pressing::new` returns the `Pressing` **unshared** plus its cap, so one transaction can
list it before `share` puts it on chain:

```move
let (mut pressing, admin_cap) =
    pressing::new(&mut release, &release_cap, pressing::new_scheduled_state(friday_8pm_ms));
listing::new<SUI>(&mut pressing, &admin_cap, listing::new_fixed_price(10), listing::new_enabled_state());
listing::new<USDC>(&mut pressing, &admin_cap, listing::new_fixed_price(25), listing::new_enabled_state());
pressing.share();
```

Both currencies open together at Friday 8pm, with no further transaction — the first
buy after the moment flips the run to `Active` on its way through.

Then, per sale:

```move
// `payment` is a Balance<SUI> — off the buyer's accumulator, or `coin.into_balance()`.
let record: Record = listing.buy(
    &mut pressing,
    &mut record_registry,
    payment,
    &record_settings,
    &clock,
    ctx,
);
transfer::public_transfer(record, buyer);
```

Adding a currency to a live pressing is just another `listing::new` — once per currency,
ever, since the listing is permanent. Everything after that is an edit in place, and
none of it needs the release cap again:

```move
listing.set_price(&admin_cap, listing::new_fixed_price(20));      // repricing
listing.set_state(&admin_cap, listing::new_disabled_state());     // stop taking this currency
listing.set_state(&admin_cap, listing::new_enabled_state());      // take it again
pressing.set_state(&admin_cap, pressing::new_active_state());     // open early, by hand
pressing.set_state(&admin_cap, pressing::new_paused_state());     // stop the whole run
pressing.set_state(&admin_cap, pressing::new_scheduled_state(t)); // reschedule it
```

## API surface

Deliberately small. The rule: **an off-chain client reads an object's fields over RPC,
it never calls a view function** — so a view earns its place on chain only if another
*Move* package needs it. Everything that was a one-line derivation of `state()`
(`is_active`, `is_paused`, `is_scheduled`, `start_timestamp_ms`, `is_disabled`) is
`#[test_only]`, which is stripped from the published bytecode.

`is_selling(&clock)` and `is_live(&pressing, &clock)` are the exceptions that stay
public: each composes several facts, and duplicating that logic in a caller is exactly
the drift a shared view prevents. `authorize` and `uid` on the pressing are
`public(package)` — only `listing` calls them.

## Layout

```
sources/pressing.move     the run: sale count, schedule + switch, mint witness, cap
sources/listing.move      one currency's offer: price, state, buy
tests/
```

Depends on [`miso-record`](https://github.com/misofm/record) (the concrete,
Registry-derived `key + store` Record) and the miso-protocol (`Release` /
`ReleaseAdminCap`). Both dependencies are pinned to reviewed git revisions:

```toml
miso = { git = "https://github.com/misonetwork/protocol.git", rev = "7bda0bb740c32a75ef76c0739cb671b3de77d338" }
miso_record = { git = "https://github.com/misofm/record.git", rev = "c3f5310e0f52b1aa5553636c7f8edae7d01d0010" }
```

## Build

```bash
sui move test
```

## Publication status

This version requires a fresh publication. It is not a compatible upgrade of the
legacy Testnet package: Record now has `key + store`, a new field layout, and a
singleton Registry; Listing purchases require that additional shared input.
Previously published package and object IDs do not identify this architecture. A new
`Published.toml` should be committed only after the fresh publication.

License: Apache-2.0
