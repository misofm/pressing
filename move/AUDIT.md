# Security Audit — `miso_pressing`

**Revision:** not a git repository (working tree as of audit date) · **Date:** 2026-08-23 ·
**Toolchain:** sui 1.77.2

Audit of `miso_pressing` (modules `pressing`, `listing`, `certificate`): a
release's one uncapped record run. Buyers pay a per-currency `Listing` and
receive a derived-UID `Record<Certificate>`; proceeds forward to the
release's address. Verdict: **safe — no findings.** Pricing/payment math is
minimal and exact; authority splits are deliberate and correctly enforced.

## What it does

- `pressing::new` (`pressing.move:193`) — `ReleaseAdminCap`-gated, one
  pressing per release ever (derived claim on singleton `PressingKey()`);
  returns the unshared `Pressing` plus its derived `PressingAdminCap`.
- `listing::new` (`listing.move:200`) — pressing-cap-gated, one listing per
  (pressing, currency) ever (derived claim on phantom-typed
  `ListingKey<Currency>()`), shared immediately.
- `listing::buy` (`listing.move:235`) — permissionless: checks the listing
  belongs to the pressing, the listing is enabled, and the payment satisfies
  the price; forwards the ENTIRE payment to the release's address; mints the
  next-numbered record via `pressing::mint_next` (`pressing.move:243`,
  package-private — the run-wide Scheduled/Active/Paused switch is checked
  there so no sale path can miss it).
- `certificate` — package-only constructor (`certificate.move:35`), no
  `copy`; embeds immutable sale facts in the record.

Threat model: buyers cheated on price/numbering; unauthorized minting;
revenue redirected; caps confused across pressings; assets stranded.

## Checks performed (all hold)

- **Authority chain.** `pressing::new` goes through `release::uid_mut(cap)`,
  which asserts `cap.release_id == release id` (pinned dependency
  `miso/release.move:333-336`, `:241`). Everything downstream authorizes
  against `PressingAdminCap.pressing_id == pressing id`
  (`pressing.move:229-231`, `listing.move:317-319`). A foreign cap aborts —
  tested via `foreign_admin_cap_for_testing` (`pressing.move:399`).
- **Cap split is about money and it holds.** The pressing cap controls
  issuance (listings, prices, state) but CANNOT withdraw sales revenue:
  proceeds go to the release's funds accumulator via `balance::send_funds`
  (`listing.move:255`), and withdrawal needs `&mut UID` of the release —
  i.e. the `ReleaseAdminCap`. Deliberate, documented (`pressing.move:49-62`),
  verified in code.
- **Payment math.** `Fixed`: `paid == amount` exactly (`listing.move:247`) —
  a stale payment aborts against a repriced listing. `Floor`: `paid >=
  amount`; overpayment is a documented tip to the release (`:248`). No
  change/refund computation exists, so there is nothing to get wrong.
  Payment is a bare `Balance<Currency>`; `Currency` is the listing's phantom
  type, so cross-currency payment is a compile-time impossibility.
- **Numbering.** `supply + 1` (`pressing.move:265`) before the derived claim
  — a claim failure would abort the whole tx, so the counter and the derived
  sequence cannot diverge; numbers are gap-free and unique across currencies.
  Overflow needs 2⁶⁴ sales — not a practical DoS.
- **No asset traps.** `Pressing` is `key`-only (no `store`): the value
  returned by `new` can only be shared or frozen, never sent to an address
  or wrapped — the caller cannot lock it away (`:86`, `:214`). Listings are
  shared at creation. Records are returned to the buyer's transaction.
  Nothing has a destructor — deliberate, so a derived subtree can never be
  stranded (`pressing.move:35-38`).
- **Scheduled drop.** The `Scheduled → Active` transition fires inside
  `mint_next` against the shared `Clock` (`:252-260`); before the start,
  `ENotStarted` aborts; `is_selling` reads the same clock so the run sells
  at its drop moment with no "first caller" requirement. Nobody can buy
  early; the artist cannot be front-run on the transition (it's
  clock-authorized, not caller-authorized).
- **Certificate trust.** `Certificate` is constructible only in-package
  (`certificate.move:35`); `Record<Certificate>` is therefore a trusted
  specialization per `miso_record`'s contract. `purchase_currency` uses
  `with_defining_ids<Currency>` (`certificate.move:46`).
- **Double-open/double-list.** Both abort in `derived_object::claim`
  (singleton `PressingKey()`, phantom-typed `ListingKey<Currency>()`).

## Findings

None.

### Notes (not findings)

- **Free listings** (`Fixed 0` / `Floor 0`) mint records for free and skip
  the funds send (`listing.move:254-258`) — an artist-chosen price, not a
  bypass.
- Once the first sale settles a `Scheduled` run, the start time survives
  only in events (`pressing.move:121-124`) — indexer concern, not security.
- Floor-price overpayment is irreversible by design; the buyer chose the
  balance they sent.

## Edge cases (verified)

- Buy on wrong pressing — `EWrongPressing` (`listing.move:242`).
- Buy on disabled listing / paused run / before start — `EListingDisabled` /
  `EPressingPaused` / `ENotStarted`.
- Zero payment on a paid listing — `paid == amount` / `paid >= amount` both
  reject 0 when `amount > 0`; zero-amount listings destroy the zero balance.
- Reprice front-running — exact-pay `Fixed` aborts stale payments; `Floor`
  buyer caps their own spend.
- `RecordSoldEvent.number` reads `pressing.supply()` AFTER `mint_next`
  (`listing.move:272`) — matches the minted record's number.
- Event budget — `buy` emits exactly 1 event + at most 1 state-change event;
  no loops anywhere in the package (no unbounded-iteration DoS).

## Verification

Unit tests in `tests/pressing_tests.move` and `tests/listing_tests.move`
(plus `test_utils.move`) exercise the lifecycle, both price policies, the
foreign-cap abort, and derived-address assertions. Dependency behavior
(`miso::release` cap check, `miso_record::record::new` derived claim)
verified against the pinned build copies under `pressing/move/build/`.
