// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A release's record production — its *Pressing*.
///
/// A release has exactly one pressing, and the pressing is one uncapped run of
/// records: every copy ever made draws its number from this single counter, forever.
/// There are no editions, no supply caps, and no sold-out state — scarcity on Miso is
/// what a record *accrues* (playtime above all), not how few of it were printed. The
/// pressing owns two things and only two things: the **run** the records number
/// against, and the **switch** that stops it.
///
/// ```text
/// Release
///  └─ Pressing              the run, and when it sells at all       PressingKey()
///      ├─ PressingAdminCap  authority over price and state         PressingAdminCapKey()
///      ├─ Listing<SUI>      what it costs in one currency          ListingKey<SUI>()
///      └─ Listing<USDC>
/// ```
///
/// # Everything is address math
///
/// A pressing's UID is derived off its release's UID at a singleton key, its admin
/// cap's and each listing's off the pressing's, and records off the pressing's at
/// their number. So every object in the tree is reachable from the release id alone,
/// by pure computation — no registry, no pointer that has to be maintained, and no
/// stored set of listings: a listing either exists at its derived address or it does
/// not (`listing::has_listing`), and `ListingOpenedEvent<Currency>` enumerates them
/// for an indexer. It also makes the number sequence gap-free for free, and every
/// record verifiable against its pressing from chain state alone
/// (`verify_record`).
///
/// # Starting and stopping is state, never teardown
///
/// Nothing here is ever destroyed, sealed, or wound down — deleting a pressing would
/// strand its whole derived subtree, so there is no destructor at all. The run's
/// lifecycle is `Scheduled → Active → Paused → Active`: it opens itself at its drop
/// moment (no artist transaction, and nobody can buy early), and after that the artist
/// stops and starts it at will. The first transition is real, not computed — the first
/// sale past the start rewrites `Scheduled` to `Active` inside `mint_next`, which is
/// why `Scheduled` only ever describes a run still waiting. Below it, each listing's
/// `Enabled | Disabled` governs one currency. A run that is paused or not yet open
/// sells in no currency, whatever the listings say.
///
/// There is no end state and no expiry: an uncapped, permanent run has nothing to
/// count down to, and a time-limited sale is scarcity theater this design rejects. An
/// artist ending a campaign pauses it.
///
/// # Authority
///
/// Opening a pressing needs the release's `ReleaseAdminCap`, enforced by the
/// protocol's `release::uid_mut`, and hands back a `PressingAdminCap`. Everything
/// after that — pricing, pausing, opening listings — authorizes against the pressing
/// cap alone.
///
/// The split is deliberate and it is about money, not tidiness. `ReleaseAdminCap`
/// yields `release::uid_mut`, and `balance::withdraw_funds_from_object` is gated on
/// `&mut UID` alone — so the release cap can withdraw the sales revenue that `buy`
/// forwards to the release's address. Under one cap, "may reprice a listing" and
/// "may take the money" would be the same grant. The pressing cap is the routine
/// one, safe to delegate to whoever runs the shop; the release cap stays with the
/// rightsholder.
module miso_pressing::pressing;

use miso::release::{Release, ReleaseAdminCap};
use miso_pressing::certificate;
use miso_record::record::{Self, Record};
use miso_record::settings::Settings;
use sui::clock::Clock;
use sui::derived_object;
use sui::event::emit;

public use fun pressing_admin_cap_pressing_id as PressingAdminCap.pressing_id;

//=== Structs ===

/// Key for deriving a `Pressing`'s UID off its RELEASE's UID. A singleton — a release
/// has exactly one pressing, so the key carries no data and can be claimed exactly
/// once.
public struct PressingKey() has copy, drop, store;

/// Key for deriving the `PressingAdminCap`'s UID off the PRESSING's UID.
public struct PressingAdminCapKey() has copy, drop, store;

/// Witness authorizing `miso_record` mints. Constructible only inside this package,
/// and produced only on `mint_next`'s path — so possessing a value of it proves a
/// mint went through the pressing's counter. `miso_record::Settings` must authorize
/// this *type* to mint.
public struct MintWitness has drop {}

/// A release's record production: one uncapped run. Owns the number sequence the
/// records derive from, and the switch that stops the whole run. Never destroyed.
public struct Pressing has key {
    id: UID,
    /// The release these records are copies of.
    release_id: ID,
    /// Whether the run sells at all, in any currency.
    state: PressingState,
    /// Records pressed so far; also the most recent number. Read on every mint — this
    /// is the sequence itself, not a statistic.
    supply: u64,
}

/// Authority over a pressing: its state, its listings, and their prices. Deliberately
/// *not* the release's cap — see the module doc on why the split is about money.
/// `key, store` so a vault or multisig can custody it (there is no recovery here).
public struct PressingAdminCap has key, store {
    id: UID,
    /// The pressing this cap controls. Every mutator asserts against it.
    pressing_id: ID,
}

//=== Enums ===

/// Whether the run sells, over every currency at once. The lifecycle runs
/// `Scheduled → Active → Paused → Active`: a pressing opens itself at its drop
/// moment, then the artist stops and starts it at will.
public enum PressingState has copy, drop, store {
    /// Opens the moment the clock passes `start_timestamp_ms` (Unix ms), with no
    /// further action from anyone. A start already in the past sells now.
    ///
    /// This is a *transitional* state: the first sale past the start rewrites it to
    /// `Active` (in `mint_next`, before any sales logic), so a run reads `Scheduled`
    /// only while it is still waiting. Between the start and that first sale the run
    /// already sells — `is_selling` answers against the clock — so nobody has to go
    /// first for the drop to be open.
    ///
    /// Consequence worth knowing: once the transition fires the start time is gone
    /// from the object. `PressingOpenedEvent` and `PressingStateChangedEvent` carry
    /// it, so "when was this run scheduled for" is an event-log question, not an
    /// object read.
    Scheduled { start_timestamp_ms: u64 },
    /// Selling, subject to each listing's own state.
    Active,
    /// Selling in no currency, whatever the listings say.
    Paused,
}

//=== Events ===

/// A pointer event, with one exception: it carries the opening `state`. A `Scheduled`
/// run rewrites itself to `Active` on its first sale past the start, so an indexer that
/// reads the object afterwards cannot recover the drop time — this is the only place it
/// survives.
public struct PressingOpenedEvent has copy, drop {
    pressing_id: ID,
    release_id: ID,
    state: PressingState,
}

/// The pressing's new run-wide state, emitted for both cap-authorized changes and the
/// clock-authorized `Scheduled` to `Active` transition on the first sale.
public struct PressingStateChangedEvent has copy, drop {
    pressing_id: ID,
    state: PressingState,
}

//=== Errors ===

// Authorization errors
#[error]
const EUnauthorized: vector<u8> = b"This admin cap does not control this pressing";

// State errors
#[error]
const ENotStarted: vector<u8> = b"The pressing is scheduled and has not opened yet";

#[error]
const EPressingPaused: vector<u8> = b"The pressing is paused and sells in no currency";

//=== State Constructors ===

/// The scheduled state: the run opens itself at `start_timestamp_ms` (Unix ms).
public fun new_scheduled_state(start_timestamp_ms: u64): PressingState {
    PressingState::Scheduled { start_timestamp_ms }
}

/// The active state: the run sells, subject to each listing's own state.
public fun new_active_state(): PressingState {
    PressingState::Active
}

/// The paused state: the run sells in no currency.
public fun new_paused_state(): PressingState {
    PressingState::Paused
}

//=== Public Functions ===

/// Open a release's pressing in `state` — `Scheduled` for a drop moment, `Active` to
/// sell immediately, `Paused` to set it up quietly. Returns it unshared, so the same
/// transaction can list it (`listing::new`) before `share` puts it on chain, plus the
/// cap that governs it from here on. Neither value has `drop`, so neither can be lost
/// by forgetting.
///
/// Claim-once on `PressingKey()` means a release's pressing can only ever be opened
/// here, exactly once; calling this twice for the same release aborts.
public fun new(
    release: &mut Release,
    cap: &ReleaseAdminCap,
    state: PressingState,
): (Pressing, PressingAdminCap) {
    let release_id = release.id();
    let mut id = derived_object::claim(release.uid_mut(cap), PressingKey());
    let pressing_id = id.to_inner();

    let admin_cap = PressingAdminCap {
        id: derived_object::claim(&mut id, PressingAdminCapKey()),
        pressing_id,
    };

    emit(PressingOpenedEvent { pressing_id, release_id, state });

    (Pressing { id, release_id, state, supply: 0 }, admin_cap)
}

/// Put the pressing on chain. `new` hands back an unshared `Pressing` so the same
/// transaction can list it first; this is the last call in that sequence.
public fun share(self: Pressing) {
    transfer::share_object(self)
}

/// Move the run between its three modes — schedule it, open it, stop it. Takes effect
/// across every currency at once, regardless of any listing's own state.
public fun set_state(self: &mut Pressing, cap: &PressingAdminCap, state: PressingState) {
    self.authorize(cap);
    self.state = state;
    emit(PressingStateChangedEvent { pressing_id: self.id.to_inner(), state });
}

//=== Package Functions ===

/// Abort unless `cap` controls this pressing.
public(package) fun authorize(self: &Pressing, cap: &PressingAdminCap) {
    assert!(cap.pressing_id == self.id.to_inner(), EUnauthorized);
}

/// The pressing's UID, for reading what is derived off it.
public(package) fun uid(self: &Pressing): &UID {
    &self.id
}

/// Press the next record in the run: advance the counter, derive the record's UID off
/// this pressing at the new number, and stamp its certificate in the same transaction
/// (`miso_pressing::certificate`). The 1-based number is unique across every currency
/// the pressing sells in. Aborts if the run is paused or has not opened yet — the
/// run-wide switch is checked here, so no sale path can miss it.
public(package) fun mint_next<Currency>(
    self: &mut Pressing,
    settings: &Settings,
    purchase_price: u64,
    clock: &Clock,
    ctx: &TxContext,
): Record {
    // Settle the schedule before any sales logic. A `Scheduled` run past its start
    // becomes `Active` right here — the clock is the only authority that transition
    // needs, and this is the one place a sale can reach it.
    match (self.state) {
        PressingState::Scheduled { start_timestamp_ms } => {
            assert!(clock.timestamp_ms() >= start_timestamp_ms, ENotStarted);
            self.state = PressingState::Active;
            emit(PressingStateChangedEvent {
                pressing_id: self.id.to_inner(),
                state: self.state,
            });
        },
        PressingState::Active => (),
        PressingState::Paused => abort EPressingPaused,
    };

    self.supply = self.supply + 1;
    let mut record = record::mint(
        MintWitness {},
        settings,
        &mut self.id,
        self.release_id,
        self.supply,
        clock,
        ctx,
    );
    certificate::attach<Currency>(&mut record, self.supply, purchase_price);
    record
}

/// The pressing's UID, for deriving a listing off it.
public(package) fun uid_mut(self: &mut Pressing): &mut UID {
    &mut self.id
}

//=== View Functions ===

/// The address `release_id`'s pressing occupies — pure address math, computable
/// before the pressing has been opened.
public fun derive_id(release_id: ID): ID {
    derived_object::derive_address(release_id, PressingKey()).to_id()
}

public fun id(self: &Pressing): ID {
    self.id.to_inner()
}

public fun release_id(self: &Pressing): ID {
    self.release_id
}

/// Records pressed so far; also the most recent number.
public fun supply(self: &Pressing): u64 {
    self.supply
}

#[test_only]
public fun state(self: &Pressing): PressingState {
    self.state
}

/// Whether the run sells *right now* — the question `buy` actually asks. `Scheduled`
/// answers it against the clock, so a run past its start that has not yet had a sale
/// to settle it reads as selling, which it is.
public fun is_selling(self: &Pressing, clock: &Clock): bool {
    match (self.state) {
        PressingState::Scheduled { start_timestamp_ms } => {
            clock.timestamp_ms() >= start_timestamp_ms
        },
        PressingState::Active => true,
        PressingState::Paused => false,
    }
}

/// The pressing this cap controls. Public so a custody layer holding the cap can tell
/// what it governs without the `Pressing` object.
public fun pressing_admin_cap_pressing_id(cap: &PressingAdminCap): ID {
    cap.pressing_id
}

/// Whether `record` is genuinely the copy its certificate claims it is, checked from
/// chain state alone and without needing the `Pressing` object.
///
/// The record must sit at exactly the address its certificate number derives to off
/// its release's pressing. The certificate is the readable form of what the address
/// already proves.
public fun verify_record(record: &Record): bool {
    certificate::of(record).is_some_and!(|cert| {
        record::derive_id(derive_id(record.release_id()), cert.number()) == record.id()
    })
}

//=== Test Helpers ===

// The state predicates below are `#[test_only]` on purpose. Each is a one-line
// derivation of `state()`, and an off-chain client reads the object's fields over RPC
// rather than calling a view — so on chain they would be surface with no caller.
// `is_selling` is the exception that stays public: it is the composed question `buy`
// asks, and duplicating that match is exactly the drift a shared view prevents.

#[test_only]
public fun opened_event_fields(event: &PressingOpenedEvent): (ID, ID, PressingState) {
    (event.pressing_id, event.release_id, event.state)
}

#[test_only]
public fun state_changed_event_fields(event: &PressingStateChangedEvent): (ID, PressingState) {
    (event.pressing_id, event.state)
}

#[test_only]
public fun is_scheduled(self: &Pressing): bool {
    self.start_timestamp_ms().is_some()
}

#[test_only]
public fun is_active(self: &Pressing): bool {
    match (self.state) { PressingState::Active => true, _ => false }
}

#[test_only]
public fun is_paused(self: &Pressing): bool {
    match (self.state) { PressingState::Paused => true, _ => false }
}

#[test_only]
public fun start_timestamp_ms(self: &Pressing): Option<u64> {
    match (self.state) {
        PressingState::Scheduled { start_timestamp_ms } => option::some(start_timestamp_ms),
        _ => option::none(),
    }
}

/// The id of record `number`, or `none` if the pressing has not pressed that many.
/// Composes `supply()` with `record::derive_id`, so it is a convenience, not a
/// capability.
#[test_only]
public fun record_id(self: &Pressing, number: u64): Option<ID> {
    if (number == 0 || number > self.supply) return option::none();
    option::some(record::derive_id(self.id.to_inner(), number))
}

/// Where `pressing_id`'s admin cap was minted. The cap is transferable, so this is not
/// where it lives — only proof that it was derived, which is what the test asserts.
#[test_only]
public fun derive_admin_cap_id(pressing_id: ID): ID {
    derived_object::derive_address(pressing_id, PressingAdminCapKey()).to_id()
}

/// Build an unshared, `Active` `Pressing` on a fresh UID plus its cap, for tests that
/// exercise the number sequence without a release to derive off.
#[test_only]
public fun new_for_testing(release_id: ID, ctx: &mut TxContext): (Pressing, PressingAdminCap) {
    let mut id = object::new(ctx);
    let pressing_id = id.to_inner();
    let admin_cap = PressingAdminCap {
        id: derived_object::claim(&mut id, PressingAdminCapKey()),
        pressing_id,
    };
    (Pressing { id, release_id, state: PressingState::Active, supply: 0 }, admin_cap)
}

/// A cap for a pressing that does not exist, to prove the id check bites.
#[test_only]
public fun foreign_admin_cap_for_testing(pressing_id: ID, ctx: &mut TxContext): PressingAdminCap {
    PressingAdminCap { id: object::new(ctx), pressing_id }
}

#[test_only]
public fun destroy_for_testing(self: Pressing, cap: PressingAdminCap) {
    let Pressing { id, .. } = self;
    id.delete();
    let PressingAdminCap { id, .. } = cap;
    id.delete();
}
