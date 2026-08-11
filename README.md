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

- **One pressing, one run, no editions.** Every copy a release ever sells draws its
  number from the pressing's single counter, forever. There are no supply caps and no
  sold-out state — scarcity on Miso is what a record *accrues* over its life (playtime
  above all), not how few of it were printed. Bot pressure on a capped run is denial;
  on an uncapped one it is revenue.

- **Everything is address math.** A `Pressing`'s UID is derived off its `Release`'s UID
  at a singleton key (claim-once: a release can only ever open one pressing), the admin
  cap's and each `Listing`'s off the pressing's, and `Record` UIDs off the pressing's at
  their number. Every object in the tree is reachable from the release id alone, by pure
  computation — no registry, no pointer to maintain, and **no stored set of listings**: a
  listing either exists at its derived address or it does not (`listing::has_listing`),
  and `ListingOpenedEvent<Currency>` enumerates them for an indexer. The numbers are
  gap-free by construction, and `pressing::verify_record(&record)` checks provenance
  from chain state alone.

- **The listing key is phantom-typed.** `ListingKey<Currency>()` puts the currency in
  the key's *type* rather than in a stored `TypeName`, so distinct currencies are
  distinct key types and `derived_object::claim` enforces once-per-currency by itself.
  That is what lets the pressing drop its currency set entirely.

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
  path can miss it. `Scheduled` is the trustless drop moment: nobody can buy before the
  start, and at the start the run opens itself with no artist transaction. Below it,
  each listing is `Enabled | Disabled`: one currency, leaving the others alone. A sale
  needs both open.

  The transition is **real, not computed**, and it lives in `mint_next` — a sale is
  the only thing that can reach it, and a sale already holds `&mut Pressing`. The first
  purchase past the drop moment rewrites `Scheduled` to `Active` before any sales logic
  runs, so every later reader sees a plain `Active` run rather than a schedule it has to
  re-evaluate. It is the one state change no capability gates: the clock is the
  authority, and it only makes good on what the schedule already promised. Until that
  first sale nothing is stale in any way that matters — `is_selling(&clock)` reads a due
  `Scheduled` as selling, so nobody has to go first for the drop to be open.

  The cost is that the start time leaves the object at the transition:
  `start_timestamp_ms()` is `none` on a settled run. "When was this run scheduled for"
  is an event-log question — `PressingOpenedEvent` and `PressingStateChangedEvent` both
  carry the state, which is why the opened event breaks the pointer-event rule and
  carries a value at all.

  The **when** lives on the pressing rather than the listing because a drop moment is a
  fact about the release going on sale, not about one payment rail — a run that opened
  in SUI at Friday 8pm and in USDC at some other time would have two drop moments and
  one number sequence. There is still no end state and no expiry: an uncapped,
  permanent run has nothing to count down to, and a time-limited sale is scarcity
  theater this design rejects. Ending a campaign is `set_state(Paused)`.

- **One certificate, on the record.** A number is only meaningful inside the sequence
  that issued it, and what a copy sold for is a fact about the same sale — so they are
  one field, written once: `mint_next` stamps
  `Certificate { number, purchase_currency, purchase_price }` in the
  transaction that presses the record (`certificate::of(&record)`). It does not store
  its pressing's or record's id: a release has exactly one pressing at a derived
  address, and the record's id derives from that pressing plus the certificate number.
  `pressing::verify_record` recomputes that address and checks it against the record.
  The key is constructible only inside this package, so the field can be neither
  forged nor detached.

- **Two caps, split along the money.** Opening a pressing needs the release's
  `ReleaseAdminCap` (the protocol's `release::uid_mut` enforces it) and hands back a
  `PressingAdminCap`; everything after — pricing, pausing, opening listings —
  authorizes against the pressing cap alone, asserting `cap.pressing_id` against the
  pressing. This is not tidiness. `ReleaseAdminCap` yields `release::uid_mut`, and
  `balance::withdraw_funds_from_object` is gated on `&mut UID` alone — so the release
  cap can withdraw the sales revenue `buy` forwards to the release's address. Under one
  cap, "may reprice a listing" and "may take the money" would be the same grant. The
  pressing cap is the routine one, safe to delegate to whoever runs the shop; the
  release cap stays with the rightsholder. Both are `key, store`, so a vault or multisig
  can custody them — the package implements no recovery.

- **Minting is authorized by type.** `buy` presents this package's `MintWitness` to
  `miso_record`'s witness-gated `mint`; the witness type must be on the
  `miso_record::Settings` allowlist. A different sale mechanic (auction, dutch,
  giveaway…) is just another package with its own witness — same `Record`, no
  `miso_record` redeploy.

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
let record = listing.buy(&mut pressing, payment, &settings, &clock, ctx);
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
(`is_active`, `is_paused`, `is_scheduled`, `start_timestamp_ms`, `is_disabled`,
`record_id`) is `#[test_only]`, which is stripped from the published bytecode.

`is_selling(&clock)` and `is_live(&pressing, &clock)` are the exceptions that stay
public: each composes several facts, and duplicating that logic in a caller is exactly
the drift a shared view prevents. `authorize` and `uid` on the pressing are
`public(package)` — only `listing` calls them.

## Layout

```
move/
  sources/pressing.move     the run: the counter, the mint witness, the schedule + switch, the cap
  sources/listing.move      one currency's offer: price, state, buy
  sources/certificate.move  what a record carries out: number + what was paid
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

## Testnet deployment

- Immutable `miso_pressing`: `0xe9c134a5c2d263a8e9893e6439f7c797bc9e7f65bc34e99610d53c1c6e7a631b`
- Immutable `miso_record`: `0x2f0e3cf7257f7ba6ee1109c741f0ccc39f44c2da610052d165e7b514c1149fd2`
- Shared record `Settings`: `0xbc8468ea6fae4a1a0ba8f0dd2554fa75d2d3e1bff7537f866ad7b4b2f8d96e86`
- `SettingsAdminCap`: `0xfe6996468cd9a91c833d753df218cd311b3a8fa58c9085aac5104dcdca964c5a`
- Immutable `miso`: `0x5bb3ec642b1f7debd8bc2acbc16232abe893844d5978431d1cc0fbdddad73b97`
- Shared `ReleaseRegistry`: `0x3f202b6f89cf635f54bd7ddee7a21e73c77b88a10f1fc451571e9e931997e8d6`
- `MintWitness` authorization transaction: `2M2AcrcddNVAzDkDCrYqr7yALLXvMqSuV5wqh8s5Va9a`

License: Apache-2.0
