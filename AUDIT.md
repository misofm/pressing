# Security review — `miso_pressing`

**Date:** 2026-09-01

**Scope:** `sources/pressing.move`, `sources/listing.move`, the `miso_record`
dependency at `c3f5310e0f52b1aa5553636c7f8edae7d01d0010`, and their tests.

## Security claim

A successful `listing::buy`:

1. accepts the exact fixed price or at least the configured floor;
2. forwards the complete payment to the release's funds accumulator;
3. checks the Listing and Pressing switches;
4. asks the singleton `RecordRegistry` to allocate the release's next number and
   derive the Record at `RecordKey(release_id, number)`; and
5. succeeds only while Record Settings names
   `miso_pressing::pressing::MintWitness` as its one active witness.

Pressing remains the sale-state object. It is deliberately not the Record parent:
Registry identity and numbering survive complete replacement of this sales package.

## Authority boundaries

- `pressing::new` requires the release's `ReleaseAdminCap` through
  `release::uid_mut`; the singleton `PressingKey()` claim permits one Pressing per
  release in this package.
- `PressingAdminCap` governs Pressing state, Listing creation, Listing state, and
  price. Its stored `pressing_id` is checked on every mutation.
- `MintWitness()` has `drop` only. Its positional field is module-private, and the
  only production construction is inside package-private `pressing::mint_next`.
- `record::mint` independently compares the witness's defining type against immutable
  `&Settings`. Replacing or clearing the active witness disables this package without
  upgrading it.
- The release cap, not the Pressing cap, controls proceeds withdrawal. Repricing and
  revenue custody remain separate authorities.

## Purchase and numbering invariants

- `Fixed` requires `paid == amount`; `Floor` requires `paid >= amount`.
- The entire `Balance<Currency>` is forwarded. A zero-value purchase destroys only
  the zero balance and creates no funds slot.
- `Listing<Currency>` and `Balance<Currency>` statically bind the payment currency.
  `record::mint<MintWitness, Currency>` stamps that same type into the Record.
- `RecordRegistry` owns the canonical per-release counter. Equal numbers for
  different releases cannot collide because both values participate in `RecordKey`.
- Pressing's `supply` is only a count of sales through this Pressing. Listing events
  read `record.number()` rather than trusting that local statistic, so they remain
  correct after a prior sales implementation has already advanced the Registry.
- Any Settings rejection, state failure, derived claim failure, or later abort rolls
  back payment movement, Pressing supply, Registry supply, and Record creation as one
  transaction.

## State and event integrity

- A Listing must belong to the supplied Pressing and be enabled.
- `mint_next` checks the run-wide `Scheduled | Active | Paused` state. The first
  purchase at or after a scheduled start atomically settles Pressing to `Active`;
  early and paused purchases abort.
- Record itself stores Registry, release, number, creation time, purchase currency,
  and original purchaser. `RecordCreatedEvent` additionally records the active
  witness.
- `RecordSoldEvent<Currency>` records Listing, Pressing, release, Record, canonical
  number, accepted price, actual payment, buyer, and Clock timestamp.

## Ownership assumptions

`Record` has `key + store`; callers use framework public transfer and may wrap,
share, or freeze it. Pressing makes no downstream ownership claim about an immutable
Record reference. Pressing and Listing remain key-only shared objects whose defining
modules control their initial sharing.

## Adversarial verification

The 37 Move tests cover successful purchases, fixed/floor pricing, wrong Pressing,
disabled/paused/early states, foreign caps, duplicate Pressing/Listing claims,
cross-currency Registry numbering, transaction-boundary framework transfer, payment
redemption, complete creation/sale/destruction provenance, and direct and
Listing-mediated mint rejection when Settings does not authorize `MintWitness`.

Production modules build separately from tests. An external-package probe must also
continue to reject construction of `MintWitness()` and calls to package-private
`mint_next`; those checks protect the only capability accepted by Record Settings.

## Residual assumptions and tradeoffs

- Every purchase mutates the singleton Registry, so otherwise unrelated releases
  contend on that shared root. This is the accepted cost of a stable global namespace.
- Settings administration is a governance boundary. Selecting this witness trusts
  this package's payment and state checks; replacing it immediately disables them.
- A free Listing intentionally issues Records without payment.
- Floor overpayment is intentionally irreversible and recorded in the sale event.
- `purchased_by` is the transaction sender, not necessarily the eventual transfer
  recipient. Pressing currently returns the Record and lets the PTB choose custody.
