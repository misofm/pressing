// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One numbered run of a release's records — an *Edition*.
///
/// An edition is what a `Record`'s serial number counts against: "number 7 of 500" is a
/// statement about an edition, not about a price or a currency. So the edition owns two
/// things and only two things — the **supply cap** and the **serial sequence** — and
/// `Record` UIDs are derived off the edition's UID keyed by that serial.
///
/// # First edition, second edition
///
/// Editions are *sequential runs*, in the sense a card collector means: the 1st edition
/// is a signal that you were there early. They are NOT variants — a deluxe version has
/// different tracks, so it is a different `Release`, and therefore a different `Drop`
/// entirely. A drop's editions can only ever be successive runs of the same record.
///
/// Whether being early actually meant something is the artist's call, not the protocol's:
/// opening edition `n + 1` does not seal edition `n`. An artist who wants the 1st edition
/// to be genuinely scarce seals it (`seal`) before opening the 2nd; an artist who would
/// rather keep selling simply doesn't. Scarcity stays a per-edition decision.
///
/// # Currencies
///
/// One edition can be sold through several currencies at once — one `Listing<Currency>`
/// each — and they all draw from this single cap and this single serial sequence. That is
/// the point of putting supply here rather than on the listing: buying with USDC or with
/// SUI gets you the *same* run, and number 7 is number 7 either way.
///
/// # Lifecycle — the run knows what it is still carrying
///
/// `EditionState` is a three-step machine, and the first two steps carry the set of
/// currencies the run currently has listings standing in:
///
/// ```text
/// Listed { currencies } ──seal / sold out──▶ Sealed { currencies } ──last one──▶ Closed
/// ```
///
/// Listings register on the way up and unregister on the way down, so the set is what is
/// on chain *right now*, never a log of everything ever tried. `Sealed` is the cleanup
/// state: nothing can sell, so anyone may close what is left, and the run reaches `Closed`
/// exactly when the last listing comes down. Nothing is left standing that nobody needs —
/// and `Closed` is a fact the chain can state, not one an indexer has to infer.
///
/// A `Capped` run seals itself the moment it mints its last record, so a sell-out never
/// waits on the artist to notice.
///
/// The edition object itself is **never destroyed**, even when `Closed`. Two reasons: its
/// claim markers are what stop a currency's listing slot from ever being reused, and it
/// holds the denominator — without it, "number 7 of 500" is only "number 7", and a
/// `Record` can no longer be read against its run from chain state alone.
module miso_drop::edition;

use miso::release::ReleaseAdminCap;
use miso_record::record::{Self, Record};
use miso_record::settings::Settings;
use std::type_name::{Self, TypeName};
use sui::derived_object;
use sui::event::emit;
use sui::vec_set::{Self, VecSet};

//=== Structs ===

/// Key for deriving an `Edition`'s UID off its DROP's UID: the edition number. Markers
/// persist forever — an edition is never destroyed — so a number can never be reused.
public struct EditionKey(u32) has copy, drop, store;

/// Witness authorizing `miso_record` mints. Constructible only inside this package, and
/// produced only on `mint_next`'s path — so possessing a value of it proves a sale went
/// through an edition's supply check and serial counter. `miso_record::Settings` must
/// authorize this *type* to mint.
public struct MintWitness has drop {}

/// One numbered run of a release's records. Owns the supply cap and the serial sequence
/// that `Record`s derive from. Never destroyed.
public struct Edition has key {
    id: UID,
    /// The release these records are copies of.
    release_id: ID,
    /// The drop this run belongs to.
    drop_id: ID,
    /// Which run of the drop this is (0 = the first edition).
    number: u32,
    /// How many records this run may ever mint.
    supply: Supply,
    /// Records minted so far, across every currency; also the most recent serial.
    minted: u64,
    /// Where the run is in its life, and which listings it is still carrying.
    state: EditionState,
}

//=== Enums ===

/// Supply policy for an edition, fixed at creation.
public enum Supply has copy, drop, store {
    /// No quantity limit — the run never sells out.
    Uncapped,
    /// Sells out after `max` records, across all currencies.
    Capped { max: u64 },
}

/// Where a run is in its life. Each state carries the listings outstanding *in* it, so
/// the edition always knows exactly what is still on chain in its name — and `Closed` is
/// reachable only by taking all of it back down.
///
/// ```text
/// Listed { currencies } ──seal / sold out──▶ Sealed { currencies } ──last one──▶ Closed
///        └─ mints, takes listings                └─ takes nothing back down          │
///        └─ an expired listing may go             └─ any listing may go              │
///                                                                                    ▼
///                                             nothing of this run is left listed
/// ```
public enum EditionState has copy, drop, store {
    /// Selling. Mints records, takes new listings. `currencies` are the listings live
    /// right now — a listing that comes down (withdrawn, or its window elapsed) leaves
    /// the set, so this is never a growing log of everything ever tried.
    Listed { currencies: VecSet<TypeName> },
    /// The run is over — no more records, no new listings — but listings are still
    /// standing. `currencies` is the cleanup list: every one of them can now be closed by
    /// anyone, because none of them can sell.
    Sealed { currencies: VecSet<TypeName> },
    /// Wound down. Every listing has been taken down and nothing more will ever happen
    /// here. Terminal.
    Closed,
}

//=== Events ===

public struct EditionOpenedEvent has copy, drop {
    edition_id: ID,
    drop_id: ID,
    release_id: ID,
    number: u32,
    supply: Supply,
}

public struct EditionSealedEvent has copy, drop {
    edition_id: ID,
    drop_id: ID,
    release_id: ID,
    number: u32,
    minted: u64,
    /// How many listings the run still has standing, and so how many closes it takes to
    /// reach `Closed`.
    outstanding_listings: u64,
}

public struct EditionClosedEvent has copy, drop {
    edition_id: ID,
    drop_id: ID,
    release_id: ID,
    number: u32,
    minted: u64,
}

//=== Errors ===

/// The admin cap does not control this edition's release.
const EUnauthorized: u64 = 0;
/// A capped supply must be able to mint at least one record (`max > 0`).
const EInvalidSupply: u64 = 1;
/// The edition has minted every one of its `Capped { max }` records. Unreachable through
/// this package: a run that mints its last record seals itself in the same call, so the
/// next attempt is turned away by the state check first. Kept as a guard on the invariant
/// — if sealing-on-sell-out ever stopped firing, this is what would stop an over-mint.
const ESoldOut: u64 = 2;
/// The run is no longer listed: it has been sealed or wound down, so it mints nothing and
/// takes no new listings.
const ENotListed: u64 = 3;
/// The run has already wound down — there is nothing left to take off it.
const EAlreadyClosed: u64 = 4;

//=== Term Constructors ===

/// An uncapped supply: the run never sells out.
public fun new_uncapped_supply(): Supply {
    Supply::Uncapped
}

/// A capped supply: the run sells out after `max` records, counted across every currency
/// it is listed in. `max` must be at least 1.
public fun new_capped_supply(max: u64): Supply {
    assert!(max > 0, EInvalidSupply);
    Supply::Capped { max }
}

//=== Public Functions ===

/// End a run: no more records mint, and no new currency may be listed against it.
/// Irreversible.
///
/// This is how an artist makes "1st edition" mean something — seal the 1st before opening
/// the 2nd. It is also the only way to end an `Uncapped` run, which otherwise never
/// finishes on its own; a `Capped` run seals itself the moment it mints its last record.
///
/// Sealing hands every standing listing over for cleanup: none of them can sell any more,
/// so from here anyone may close them. When the last one comes down the run reaches
/// `Closed`. A run with no listings standing goes straight there.
public fun seal(self: &mut Edition, cap: &ReleaseAdminCap) {
    self.authorize(cap);
    self.do_seal();
}

/// Put the run on chain. `drop::new` and `drop::next_edition` hand back an unshared
/// `Edition` so the same transaction can list it first (`listing::new`); this is the last
/// call in that sequence. An edition that needs no listing yet is shared immediately.
public fun share(self: Edition) {
    transfer::share_object(self);
}

//=== Package Functions ===

/// Claim edition `number`'s derived UID off the drop's UID and build the run. Returned
/// unshared so the caller can list against it in the same transaction before `share`.
public(package) fun new(
    drop_uid: &mut UID,
    release_id: ID,
    drop_id: ID,
    number: u32,
    supply: Supply,
): Edition {
    let id = derived_object::claim(drop_uid, EditionKey(number));

    emit(EditionOpenedEvent {
        edition_id: id.to_inner(),
        drop_id,
        release_id,
        number,
        supply,
    });

    Edition {
        id,
        release_id,
        drop_id,
        number,
        supply,
        minted: 0,
        state: EditionState::Listed { currencies: vec_set::empty() },
    }
}

/// Mint the next record in the run: enforces the state and the cap, advances the serial,
/// and derives the record's UID off this edition. The 1-based serial is the record's
/// `number`, and it is unique across every currency the run sells in.
///
/// A `Capped` run that mints its last record seals itself here. Nothing is left waiting on
/// the artist to notice it sold out: its listings become closeable in the same transaction
/// as the sale that finished it.
public(package) fun mint_next<Currency>(
    self: &mut Edition,
    settings: &Settings,
    paid: u64,
    ctx: &TxContext,
): Record {
    self.assert_listed();
    match (self.supply) {
        Supply::Uncapped => (),
        Supply::Capped { max } => assert!(self.minted < max, ESoldOut),
    };
    self.minted = self.minted + 1;

    let record = record::mint_derived<MintWitness, Currency>(
        MintWitness {},
        settings,
        &mut self.id,
        self.release_id,
        self.number,
        self.minted,
        paid,
        ctx,
    );

    if (self.is_sold_out()) self.do_seal();

    record
}

/// The edition's UID, for deriving a listing off it.
public(package) fun uid_mut(self: &mut Edition): &mut UID {
    &mut self.id
}

/// Take `Currency` onto the run's standing-listings set. Only a listed run takes new
/// listings — a sealed one is on its way down, not up.
public(package) fun register_currency<Currency>(self: &mut Edition) {
    match (&mut self.state) {
        EditionState::Listed { currencies } => {
            currencies.insert(type_name::with_defining_ids<Currency>())
        },
        _ => abort ENotListed,
    }
}

/// Take `Currency` back off, because its listing has just been destroyed. If that was the
/// last listing a sealed run was carrying, the run is wound down: it closes here.
public(package) fun unregister_currency<Currency>(self: &mut Edition) {
    let currency = type_name::with_defining_ids<Currency>();
    let wound_down = match (&mut self.state) {
        // A listing coming off a live run — withdrawn, or its window elapsed — just
        // leaves the set. The run is still selling in whatever else it is listed in.
        EditionState::Listed { currencies } => {
            currencies.remove(&currency);
            false
        },
        EditionState::Sealed { currencies } => {
            currencies.remove(&currency);
            currencies.is_empty()
        },
        EditionState::Closed => abort EAlreadyClosed,
    };

    if (wound_down) self.do_close();
}

/// Abort unless `cap` controls this edition's release.
public(package) fun authorize(self: &Edition, cap: &ReleaseAdminCap) {
    assert!(cap.release_admin_cap_release_id() == self.release_id, EUnauthorized);
}

/// Abort unless the run is still listed — still minting and still taking listings.
public(package) fun assert_listed(self: &Edition) {
    assert!(self.is_listed(), ENotListed);
}

//=== Internal ===

/// `Listed → Sealed`, carrying the standing listings over as the cleanup list — or
/// straight to `Closed` if there is nothing standing.
fun do_seal(self: &mut Edition) {
    let currencies = match (&self.state) {
        EditionState::Listed { currencies } => *currencies,
        _ => abort ENotListed,
    };

    emit(EditionSealedEvent {
        edition_id: self.id.to_inner(),
        drop_id: self.drop_id,
        release_id: self.release_id,
        number: self.number,
        minted: self.minted,
        outstanding_listings: currencies.length(),
    });

    if (currencies.is_empty()) {
        self.do_close()
    } else {
        self.state = EditionState::Sealed { currencies }
    }
}

/// `→ Closed`. Nothing of this run is listed any more, and nothing ever will be again.
fun do_close(self: &mut Edition) {
    self.state = EditionState::Closed;

    emit(EditionClosedEvent {
        edition_id: self.id.to_inner(),
        drop_id: self.drop_id,
        release_id: self.release_id,
        number: self.number,
        minted: self.minted,
    });
}

//=== View Functions ===

/// The address edition `number` of `drop_id` occupies — pure address math, computable
/// before the edition exists and after anything derived from it is gone.
public fun derive_id(drop_id: ID, number: u32): ID {
    derived_object::derive_address(drop_id, EditionKey(number)).to_id()
}

public fun id(self: &Edition): ID {
    self.id.to_inner()
}

public fun release_id(self: &Edition): ID {
    self.release_id
}

public fun drop_id(self: &Edition): ID {
    self.drop_id
}

public fun number(self: &Edition): u32 {
    self.number
}

public fun supply(self: &Edition): Supply {
    self.supply
}

public fun minted(self: &Edition): u64 {
    self.minted
}

public fun state(self: &Edition): EditionState {
    self.state
}

/// The currencies this run currently has a `Listing` standing in — never a log of
/// everything ever tried, always what is on chain right now. Empty once `Closed`.
public fun currencies(self: &Edition): vector<TypeName> {
    match (&self.state) {
        EditionState::Listed { currencies } => *currencies.keys(),
        EditionState::Sealed { currencies } => *currencies.keys(),
        EditionState::Closed => vector[],
    }
}

/// Whether this run has a `Listing` standing in `Currency` right now.
public fun has_currency<Currency>(self: &Edition): bool {
    let currency = type_name::with_defining_ids<Currency>();
    match (&self.state) {
        EditionState::Listed { currencies } => currencies.contains(&currency),
        EditionState::Sealed { currencies } => currencies.contains(&currency),
        EditionState::Closed => false,
    }
}

/// How many listings this run still has standing — how many closes from `Closed`.
public fun outstanding_listings(self: &Edition): u64 {
    self.currencies().length()
}

/// Flat projection of `supply`: the cap, or `none` if uncapped.
public fun max_supply(self: &Edition): Option<u64> {
    match (self.supply) {
        Supply::Uncapped => option::none(),
        Supply::Capped { max } => option::some(max),
    }
}

/// How many records the run can still mint, or `none` if uncapped.
public fun remaining(self: &Edition): Option<u64> {
    match (self.supply) {
        Supply::Uncapped => option::none(),
        Supply::Capped { max } => option::some(max - self.minted),
    }
}

/// Whether the run has minted every one of its `Capped { max }` records (always `false`
/// for an uncapped run).
public fun is_sold_out(self: &Edition): bool {
    match (self.supply) {
        Supply::Uncapped => false,
        Supply::Capped { max } => self.minted >= max,
    }
}

/// Still selling: minting records and taking new listings.
public fun is_listed(self: &Edition): bool {
    match (&self.state) {
        EditionState::Listed { .. } => true,
        _ => false,
    }
}

/// Over, but still carrying listings that need taking down.
public fun is_sealed(self: &Edition): bool {
    match (&self.state) {
        EditionState::Sealed { .. } => true,
        _ => false,
    }
}

/// Wound down: over, and nothing left standing in its name.
public fun is_closed(self: &Edition): bool {
    match (&self.state) {
        EditionState::Closed => true,
        _ => false,
    }
}

//=== Test Helpers ===

/// Build an unshared `Edition` on a fresh UID, for tests that exercise minting without a
/// drop to derive off.
#[test_only]
public fun new_for_testing(
    release_id: ID,
    drop_id: ID,
    number: u32,
    supply: Supply,
    ctx: &mut TxContext,
): Edition {
    Edition {
        id: object::new(ctx),
        release_id,
        drop_id,
        number,
        supply,
        minted: 0,
        state: EditionState::Listed { currencies: vec_set::empty() },
    }
}

#[test_only]
public fun seal_for_testing(self: &mut Edition) {
    self.do_seal();
}

#[test_only]
public fun destroy_for_testing(self: Edition) {
    let Edition { id, .. } = self;
    id.delete();
}
