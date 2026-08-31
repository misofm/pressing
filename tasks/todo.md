# miso-pressing redesign — one pressing, one uncapped run, no editions

> **2026-09-01 — current direction.** Record is Miso's concrete distribution format.
> The package uses shared `miso_record::Settings`, one module-controlled
> `pressing::MintWitness`, and the singleton `RecordRegistry`. The Registry is the UID
> derivation parent at `RecordKey(release_id, number)` and owns the canonical
> per-release sequences; Pressing owns only sale state and a local sales count. The
> historical exploration below is retained for context; current source, tests, README,
> and audit are authoritative.

Supersedes the Drop / Edition / Listing restructure (see git history for that plan).

## Sixth revision (2026-07-31, settled with cofounder)

Consolidated decision after exploring (and rejecting) permissionless minting and a
`Record<phantom Cert>` type param — neither was ever implemented:

- **Record stays Miso's product, not a neutral standard.** The open protocol layer is
  musicos; others build their own format packages. Settings witness-gating stays: with
  it, counterfeits can't exist at all, one stable Record type forever, and succession
  is pure state (`authorize<V2Witness>` / `revoke<V1Witness>`) — note Settings never
  blocked immutability (state mutates; frozen code doesn't).
- **Renamed: package `miso_drop` → `miso_pressing`** (repo renamed miso-drop → miso-pressing).
  `Drop` → `Pressing` — the object is not the hype moment (that's the Listing's
  `Scheduled` state); it's the production facility: parents record UIDs at
  `RecordKey(u64)`, owns the serial counter, hosts the listings. `drop.move` →
  `pressing.move`, `DropKey` → `PressingKey`, `drop_id` → `pressing_id` everywhere.
- **`Serial` → `Certificate`** (`serial.move` → `certificate.move`): the authenticity
  stamp, `Certificate { pressing_id, number }`, attached by `mint_next` in the same
  transaction the record is minted. Read via `certificate::of(&record)`; the key is
  module-private, so reading and writing both live in that one module by necessity.

## Decisions (settled in conversation, 2026-07-28)

- **Record slims to intrinsic-at-birth only** — `{ id, release_id, created_at_ms }`
  (fifth revision, 2026-07-29: `number` left the struct too). A serial is only
  meaningful inside the sequence that issued it — a v2 sale package for the same
  release counts from 1 again, so two records could both claim "number 1" with the
  struct unable to say whose — which makes the serial the *issuer's* vocabulary, not
  record identity. The core keeps serials as pure addressing: `mint` still claims
  `RecordKey(number)` off the parent (collision-check + deterministic address,
  `record::derive_id` recomputes/verifies), but the readable serial is miso_drop's
  `Serial { drop_id, number }` dynamic field (`serial.move`), stamped in `mint_next`
  so gifts get one too. `created_at_ms` survives the same razor — a birth date needs
  no namespace — and is stamped by `miso_record` off the `Clock`, never by the minter.
  `edition`, `purchase_currency`, `purchase_price` went contextual earlier for the
  same reason; rarity on Miso is accrued playtime, not printed scarcity.
- **Editions deleted.** One drop per release (claim-once `DropKey()` off the Release UID),
  one uncapped run, forever. No `Supply`, no `EditionState`, no seal, no sold-out.
- **Drop = serial counter + listings map.** `{ id, release_id, minted, listings:
  VecMap<TypeName, ID> }`. Records derive off the drop at their serial (gap-free,
  provenance-verifiable). `MintWitness` lives here now.
- **Listings are derived AND permanent** (revised same day — first pass had fresh UIDs +
  destroy-to-close). Derived off the drop at `ListingKey(TypeName)`, exactly one per
  (drop, currency) ever, never destroyed. The claim-once objection to derived listing
  addresses only applied when closing destroyed the listing; permanence dissolves it, and
  "everything is address math" holds for the whole tree again. Drop keeps a
  `VecSet<TypeName>` purely for enumeration (grows only).
- **The window system is gone; one three-mode state instead** (third revision, same
  day). `ListingState = Paused | Scheduled { start_timestamp_ms } | Active`, set at
  creation and via `set_state` (cap-gated). `Scheduled` keeps the one load-bearing part
  of `Window` — the trustless drop moment (live once the clock passes start, no artist
  tx; the stored start survives as provenance of the drop time). The *end* bound was
  deleted deliberately: a time-limited sale of an uncapped permanent listing is
  scarcity theater, same family as editions. Ending a campaign = `set_state(Paused)`.
  Deletions: `Window`, both window constructors, `set_window`, `is_expired`,
  `is_in_window`, start/end projections, `EClosed`, `EInvalidWindow`, pause/resume
  pair. `new` no longer needs `&Clock`; price races stay safe (Fixed = pay exactly,
  Floor = never more than sent). No withdraw, no close, no `CloseReason`.
- **Receipt owned by miso_drop.** `buy` attaches `Receipt { currency, paid, buyer,
  listing_id }` to the record's UID under a module-private `ReceiptKey()` — unforgeable
  and undetachable despite open `uid_mut`. Gifts (records minted outside a sale) have
  none; read via `listing::receipt(&record): Option<Receipt>`.

## Done

- [x] `miso-record/move/sources/record.move` — slim struct; minting takes `&Clock` and
      loses the `Currency` type param; new `derive_id(parent, number)` view; the
      fresh-UID `mint` deleted (fourth revision) — the derived path is the singular
      `mint`, so every record has a verifiable parent and per-parent collision-checked
      serials (a fresh-UID mint would have allowed provenance-free records whose
      numbers collide with a run's serials; airdrop/gift packages derive off their own
      object instead)
- [x] `miso-record/move/tests/record_tests.move` — 4 tests green
- [x] `sources/edition.move` deleted; counter + witness folded into `drop.move`
- [x] `sources/drop.move` — Drop as the single per-release run
- [x] `sources/listing.move` — permanent derived listings, `ListingState`
      (Paused/Scheduled/Active) + `set_state`, `set_price`, Receipt
- [x] `sources/serial.move` — the drop's serial certificate on a record
      (`Serial { drop_id, number }`, module-private key, attached in `mint_next`)
- [x] Tests rewritten — 21 green (serials interleave across currencies, paused blocks
      buy, scheduled blocks before start and opens itself after, reprice-in-place with
      stale-payment abort, receipt contents, gift has no receipt,
      one-listing-per-currency-ever, one-drop-per-release)
- [x] READMEs updated (miso-pressing, miso-record)

## Follow-up (out of scope here)

- [ ] Display v2 (sui.io/blog/display-v2-mainnet, Sui v1.68) supports dynamic fields
      in templates (`{parent->['key']}`) — the "no #42 in wallets" trade-off may be
      void. At next testnet publish: register Display for `Record` via
      `display_registry` (v1 deprecated 2026-07-31; we have no legacy Display), and
      test whether a template can address a DF keyed by the module-private
      `CertificateKey()` struct (docs only show string keys). If struct keys are
      unsupported and wallet serial display is wanted: re-keying to a string key
      allows no forgery (Certificate value stays module-private-constructible, add
      aborts on duplicate) but allows *transplant* — defeated by the
      `record::derive_id(cert.pressing_id, cert.number) == record.id()` binding
      check, so strict verifiers stay safe; decide then.

- [ ] TypeScript: regenerate SDK codegen; rewrite `sdk/src/drop.ts`
      (kill `CurrentDropKey` / `newEdition` / `DropView.edition`); miso-app drops UI +
      `records.ts` field parsing; miso-api checkout `fulfill.ts` PTB (`drop::buy` →
      `listing::buy`); miso-cli publish path. Note: all of these still target published
      v5 — they never caught up with the edition split either.
- [ ] `miso-party-extensions/party_featured_drop` — rewrite against new `Drop`/`Listing`
- [x] Publish immutable `miso_record` and `miso_pressing` packages to Testnet and
      authorize `miso_pressing::pressing::MintWitness` in `miso_record::Settings`
      (authorization transaction `2M2AcrcddNVAzDkDCrYqr7yALLXvMqSuV5wqh8s5Va9a`)
- [ ] Update the `miso-deployments` manifest and downstream clients with the final
      package and singleton object ids
- [ ] miso-brain map docs (`map/miso-pressing.md`, MAP.md) + whitepaper mentions of
      `purchase_price`/`purchase_currency`

## Review

**Three designs in one day, each a net deletion.** Fresh-UID + withdraw solved the
claim-once problem by destroying listings; permanence solved it better by never
destroying them; the state enum then collapsed `paused: bool` × `Window` (a 2×2 with
an ambiguous paused-while-scheduled corner) into one mode. Gone across the day:
`withdraw`, `close`, `take_down`, `CloseReason`, `ListingClosedEvent`,
`unregister_listing`, `EListingMismatch`, `Window`, `set_window`, `is_expired`,
`is_in_window`, `EClosed`, `EInvalidWindow`. What remains: `buy`, `set_price`,
`set_state`.

**`is_live` is now a match on `ListingState`** — `Paused → false`,
`Scheduled → now >= start`, `Active → true` (plus the right-drop check). The only
clock read left in liveness is the scheduled start, which is the trustless-open
feature, not incidental state.

**Coverage.** 32 miso-pressing + 4 miso-record tests. New ground vs the edition suite:
paused blocking `buy`, a scheduled listing refusing early buys and opening itself
after its start, repricing in place with the stale-payment abort, receipt contents
including the floor-price tip, and receipt absence on non-sale mints. Dropped ground:
everything about seal/sold-out/wind-down/close/windows, which no longer exists.
