# Security review — `miso_pressing`

**Date:** 2026-08-31

**Scope:** `sources/pressing.move`, `sources/listing.move`, the merged
`miso_record` dependency at `a235ffd`, and their unit/integration tests.

## Security claim

A successful `listing::buy`:

1. accepts the exact configured fixed price or at least the configured floor;
2. forwards the complete payment to the release's funds accumulator;
3. advances one Pressing-owned, gap-free number sequence;
4. creates a concrete key-only `Record` derived from that Pressing and number; and
5. succeeds only while `miso_record::Settings` authorizes
   `miso_pressing::pressing::MintWitness`.

Pressing remains the derivation parent. There is deliberately no central Record
registry or global mint counter: a singleton would add shared-object contention and
would not strengthen the witness authorization already enforced by Record Settings.

## Authority boundaries

- `pressing::new` requires the release's `ReleaseAdminCap` through
  `release::uid_mut`, and the singleton `PressingKey()` claim permits one Pressing per
  release.
- `PressingAdminCap` governs Pressing state, Listing creation, Listing state, and
  price. Its stored `pressing_id` is checked on every mutating path.
- `MintWitness()` has `drop` only. Its positional field is module-private, and the
  only production construction is inside package-private `pressing::mint_next`.
  External code can name the type for Settings administration but cannot create a
  value or call `mint_next`.
- `record::mint` independently checks the witness type against immutable
  `&Settings`. Removing the type from Settings disables this package's mint path
  without upgrading either package.
- The release cap, not the Pressing cap, controls withdrawal of proceeds. Repricing
  and revenue custody therefore remain separate authorities.

## Purchase and numbering invariants

- `Fixed` requires `paid == amount`; `Floor` requires `paid >= amount`. A stale fixed
  payment aborts rather than silently overpaying, while a floor buyer caps its spend
  with the supplied `Balance`.
- The full `Balance<Currency>` is forwarded. A zero-value purchase destroys only the
  zero balance and does not create a funds slot.
- Listing currency is enforced by the `Listing<Currency>` and `Balance<Currency>`
  types. Different currencies feed the same Pressing counter.
- `supply` increments immediately before `record::mint`. Any Settings rejection,
  duplicate derived claim, or later abort rolls the transaction back, so neither a
  number gap nor a charged-but-unminted purchase can persist.
- Record IDs derive from the Pressing UID at `RecordKey(number)`. The Pressing is the
  smallest correct parent: it owns the sequence, while a release-wide or global
  registry would merge unrelated issuance namespaces.

## State and event integrity

- A Listing must belong to the supplied Pressing and be enabled.
- `mint_next` is the sole sale mint path and checks the run-wide
  `Scheduled | Active | Paused` state. The first purchase at or after a scheduled
  start atomically settles the Pressing to `Active`; early and paused purchases abort.
- `RecordCreatedEvent` records Record ID, Pressing parent, release, number, and the
  authorized witness type.
- `RecordSoldEvent<Currency>` records Listing, Pressing, release, Record, number,
  accepted price, actual payment, buyer, and Clock timestamp. Sale-specific facts are
  not duplicated into the universal Record object.

## Ownership assumptions

`Record` is key-only, exposes module-owned address transfer and destruction, and has
no share/freeze API. `Pressing` and `Listing` are also key-only and deliberately
shared only by their defining packages. These abilities prevent external wrapping or
use of framework `public_*` transfer functions.

## Adversarial verification

The 37 Move tests cover successful purchases, exact/floor pricing, wrong Pressing,
disabled/paused/early states, foreign caps, duplicate Pressing/Listing claims,
cross-currency numbering, transaction-boundary ownership, payment redemption,
creation/sale/destruction events, and both direct and Listing-mediated mint failures
when Settings does not authorize `MintWitness`.

In addition to the passing suite, an external-package compiler probe attempts to
construct `MintWitness()` and call package-private `mint_next`; both are rejected by
Move visibility rules. Builds and tests are run against the exact pinned Record
revision.

## Residual assumptions

- Settings administration is a Miso governance boundary. Authorizing a witness means
  trusting that witness's defining package to constrain construction correctly.
- A free Listing intentionally issues Records without payment.
- Floor overpayment is intentionally irreversible and is recorded in the sale event.
- A `u64` supply overflow would require 2^64 successful sales and is not a practical
  denial-of-service path.
