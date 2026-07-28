// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One currency's offer on an edition — a *Listing*.
///
/// A listing answers exactly two questions: **what does it cost** and **when can you buy
/// it**. Everything about *what you get* — the run, the cap, the serial number — belongs
/// to the `Edition`. So an edition sold in SUI and in USDC has two listings, each with its
/// own price and window, both drawing on the same cap and the same serial sequence.
///
/// A listing's UID is derived off its edition's UID keyed by the currency's `TypeName`, so
/// there is at most one listing per (edition, currency) and its address is computable from
/// the edition's alone.
///
/// # Price and window
///
/// - `Price` — `Fixed` (pay exactly) or `Floor` (pay at least; overpayment is kept as a
///   tip, not refunded). The whole payment forwards to the release's address; the record
///   stamps the currency and the exact amount paid.
/// - `Window` — `Unbounded { start }` (opens, possibly in the future, never closes) or
///   `Bounded { start, end }`.
///
/// Both are fixed at creation. Liveness is never stored: it is a pure function of the
/// window against the clock and of the edition's cap against its count.
///
/// # Lifecycle — closing *is* destroying
///
/// A listing has no status field, because it has no states worth storing. Closing it is
/// destroying it: `withdraw` for the artist pulling an offer at will, `close` for anyone
/// clearing up one that is already finished (its window elapsed, or its edition over). The
/// reason rides on `ListingClosedEvent` — where an indexer wants it, and where it cannot
/// drift out of sync with reality.
///
/// A listing never outlives its usefulness. `close` is permissionless the moment the
/// listing can no longer sell, so a finished offer does not sit on chain waiting for the
/// artist to remember it — and because both paths hand the currency back to the edition,
/// the run knows exactly what it is still carrying and closes itself when the last one
/// comes down.
///
/// Destroying is safe precisely because the edition is not: the claim marker for this
/// currency stays on the edition forever, so the address can never be re-derived and no
/// already-minted record can be collided with. The trade is that a closed listing is
/// closed for good — selling that currency again means a new edition. The marker also
/// gives clients a free three-way read with no stored state: no marker means never
/// listed, a marker with no object means closed, an object means sellable.
module miso_drop::listing;

use miso::release::ReleaseAdminCap;
use miso_drop::edition::Edition;
use miso_record::record::Record;
use miso_record::settings::Settings;
use std::type_name::{Self, TypeName};
use sui::balance;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

/// Key for deriving a `Listing`'s UID off its EDITION's UID: the currency's type. Uses
/// defining IDs, so upgrading the currency's package does not move the listing.
public struct ListingKey(TypeName) has copy, drop, store;

/// One currency's offer on one edition. Immutable terms; destroyed to close.
public struct Listing<phantom Currency> has key {
    id: UID,
    /// The release whose address collects the proceeds.
    release_id: ID,
    /// The edition these records come out of.
    edition_id: ID,
    /// That edition's number, denormalized for clients and events.
    edition_number: u32,
    /// What a buyer must pay per record.
    price: Price,
    /// When this listing sells.
    window: Window,
    /// Records sold through THIS currency (the edition holds the run's total).
    sold: u64,
}

//=== Enums ===

/// Pricing policy for a listing.
public enum Price has copy, drop, store {
    /// Pay exactly `amount`.
    Fixed { amount: u64 },
    /// Pay at least `amount`; overpayment is forwarded to the release, not refunded.
    Floor { amount: u64 },
}

/// When a listing sells. `buy` rejects purchases outside the window.
public enum Window has copy, drop, store {
    /// Opens at `start_timestamp_ms` (Unix ms; may be in the future — a scheduled
    /// listing) and never closes.
    Unbounded { start_timestamp_ms: u64 },
    /// Sells only within `[start_timestamp_ms, end_timestamp_ms]` (Unix ms).
    Bounded { start_timestamp_ms: u64, end_timestamp_ms: u64 },
}

/// Why a listing was closed. Carried on the event, never stored.
public enum CloseReason has copy, drop, store {
    /// The edition minted its last record.
    SoldOut,
    /// The listing's bounded window elapsed.
    Expired,
    /// The edition was sealed by the artist.
    Sealed,
    /// The artist pulled the offer.
    Withdrawn,
}

//=== Events ===

public struct ListingOpenedEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    edition_id: ID,
    release_id: ID,
    edition_number: u32,
    price: Price,
    window: Window,
}

public struct RecordSoldEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    edition_id: ID,
    release_id: ID,
    edition_number: u32,
    record_id: ID,
    number: u64,
    paid: u64,
    buyer: address,
}

public struct ListingClosedEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    edition_id: ID,
    release_id: ID,
    edition_number: u32,
    sold: u64,
    reason: CloseReason,
}

//=== Errors ===

/// The admin cap does not control this listing's release, or the edition passed is not
/// the one this listing sells from.
const EUnauthorized: u64 = 0;
/// Payment does not satisfy the listing's price.
const EInsufficientPayment: u64 = 1;
/// The listing has not opened yet (`now < start_timestamp_ms`).
const ENotStarted: u64 = 2;
/// The listing's window has closed (`now > end_timestamp_ms`).
const EClosed: u64 = 3;
/// A bounded window must be non-empty and not already elapsed.
const EInvalidWindow: u64 = 4;
/// The listing is still sellable — only `withdraw` can close it.
const EStillLive: u64 = 5;

//=== Term Constructors ===

/// A fixed price: a buyer must pay exactly `amount`.
public fun new_fixed_price(amount: u64): Price {
    Price::Fixed { amount }
}

/// A floor price: a buyer must pay at least `amount`; overpayment is kept.
public fun new_floor_price(amount: u64): Price {
    Price::Floor { amount }
}

/// A window that opens at `start_timestamp_ms` (may be in the future) and never closes.
public fun new_unbounded_window(start_timestamp_ms: u64): Window {
    Window::Unbounded { start_timestamp_ms }
}

/// A window selling only within `[start_timestamp_ms, end_timestamp_ms]`. The close must
/// be strictly after the open.
public fun new_bounded_window(start_timestamp_ms: u64, end_timestamp_ms: u64): Window {
    assert!(end_timestamp_ms > start_timestamp_ms, EInvalidWindow);
    Window::Bounded { start_timestamp_ms, end_timestamp_ms }
}

//=== Public Functions ===

/// List an edition for sale in `Currency` on the given price and window, and share it.
///
/// At most one listing per (edition, currency) can ever exist: the slot is a derived-object
/// claim on the edition, and the edition outlives every listing, so the marker is
/// permanent. Adding a second currency to a live run is just another call here — no new
/// edition, no change to the run's cap or serial sequence.
public fun new<Currency>(
    edition: &mut Edition,
    cap: &ReleaseAdminCap,
    price: Price,
    window: Window,
    clock: &Clock,
) {
    edition.authorize(cap);
    edition.assert_listed();
    assert_window_not_elapsed(&window, clock);

    let release_id = edition.release_id();
    let edition_id = edition.id();
    let edition_number = edition.number();

    let id = derived_object::claim(
        edition.uid_mut(),
        ListingKey(type_name::with_defining_ids<Currency>()),
    );
    edition.register_currency<Currency>();

    emit(ListingOpenedEvent<Currency> {
        listing_id: id.to_inner(),
        edition_id,
        release_id,
        edition_number,
        price,
        window,
    });

    transfer::share_object(Listing<Currency> {
        id,
        release_id,
        edition_id,
        edition_number,
        price,
        window,
        sold: 0,
    })
}

/// Buy one record: pay this listing's price, take the next serial out of the edition.
///
/// `payment` must satisfy the price (exactly, for `Fixed`; at least, for `Floor`). The
/// ENTIRE payment forwards to the release's address — under `Floor`, anything above the
/// floor is kept as a tip, not refunded. The record's number is the edition's next
/// 1-based serial, shared with every other currency selling the same run, and its UID is
/// derived off the EDITION. `settings` must authorize this package's `MintWitness`.
public fun buy<Currency>(
    self: &mut Listing<Currency>,
    edition: &mut Edition,
    payment: Coin<Currency>,
    settings: &Settings,
    clock: &Clock,
    ctx: &TxContext,
): Record {
    assert!(self.edition_id == edition.id(), EUnauthorized);

    let now = clock.timestamp_ms();
    match (self.window) {
        Window::Unbounded { start_timestamp_ms } => {
            assert!(now >= start_timestamp_ms, ENotStarted);
        },
        Window::Bounded { start_timestamp_ms, end_timestamp_ms } => {
            assert!(now >= start_timestamp_ms, ENotStarted);
            assert!(now <= end_timestamp_ms, EClosed);
        },
    };

    let paid = payment.value();
    match (self.price) {
        Price::Fixed { amount } => assert!(paid == amount, EInsufficientPayment),
        Price::Floor { amount } => assert!(paid >= amount, EInsufficientPayment),
    };

    // Forward the entire payment to the release's address (funds accumulator); the
    // release / royalty layer redeems + splits it downstream. A free listing (price 0)
    // skips the send so we never open a zero-value accumulator slot.
    if (paid > 0) {
        balance::send_funds(payment.into_balance(), self.release_id.to_address());
    } else {
        payment.destroy_zero();
    };

    // The edition enforces the seal and the cap, and owns the serial.
    let record = edition.mint_next<Currency>(settings, paid, ctx);
    self.sold = self.sold + 1;

    emit(RecordSoldEvent<Currency> {
        listing_id: self.id.to_inner(),
        edition_id: self.edition_id,
        release_id: self.release_id,
        edition_number: self.edition_number,
        record_id: record.id(),
        number: edition.minted(),
        paid,
        buyer: ctx.sender(),
    });

    record
}

/// Pull the offer and destroy the listing. The artist's call, allowed at any time —
/// including while it is still selling.
public fun withdraw<Currency>(
    self: Listing<Currency>,
    edition: &mut Edition,
    cap: &ReleaseAdminCap,
) {
    assert!(cap.release_admin_cap_release_id() == self.release_id, EUnauthorized);
    self.take_down(edition, CloseReason::Withdrawn);
}

/// Clear up a listing that is already finished — its window elapsed, or the edition it
/// sells from is over (sold out, or sealed). Permissionless, because it cannot change any
/// outcome: every one of these conditions already makes `buy` abort, so closing the
/// listing takes nothing away from anyone. Aborts while the listing can still sell; that
/// is the artist's call, via `withdraw`.
public fun close<Currency>(self: Listing<Currency>, edition: &mut Edition, clock: &Clock) {
    let reason = if (edition.is_sold_out()) {
        CloseReason::SoldOut
    } else if (!edition.is_listed()) {
        CloseReason::Sealed
    } else if (self.is_expired(clock)) {
        CloseReason::Expired
    } else {
        abort EStillLive
    };

    self.take_down(edition, reason);
}

//=== Internal ===

/// Hand the currency back to the edition and delete the listing. Unregistering is what
/// walks the run down its state machine: taking the last listing off a sealed run closes
/// it. The claim marker stays on the edition forever, so this address is retired, not
/// freed — the currency cannot be listed against this run again.
fun take_down<Currency>(self: Listing<Currency>, edition: &mut Edition, reason: CloseReason) {
    assert!(self.edition_id == edition.id(), EUnauthorized);
    edition.unregister_currency<Currency>();

    let Listing { id, release_id, edition_id, edition_number, sold, .. } = self;
    let listing_id = id.to_inner();
    id.delete();

    emit(ListingClosedEvent<Currency> {
        listing_id,
        edition_id,
        release_id,
        edition_number,
        sold,
        reason,
    });
}

/// A bounded window must not already be elapsed. (Structural validity — the close
/// strictly after the open — is enforced at construction by `new_bounded_window`.)
fun assert_window_not_elapsed(window: &Window, clock: &Clock) {
    match (window) {
        Window::Unbounded { .. } => (),
        Window::Bounded { end_timestamp_ms, .. } => {
            assert!(*end_timestamp_ms > clock.timestamp_ms(), EInvalidWindow);
        },
    }
}

//=== View Functions ===

/// The address `Currency`'s listing on `edition_id` occupies — pure address math,
/// computable before the listing exists and after it has been closed.
public fun derive_id<Currency>(edition_id: ID): ID {
    derived_object::derive_address(
        edition_id,
        ListingKey(type_name::with_defining_ids<Currency>()),
    ).to_id()
}

public fun id<Currency>(self: &Listing<Currency>): ID {
    self.id.to_inner()
}

public fun release_id<Currency>(self: &Listing<Currency>): ID {
    self.release_id
}

public fun edition_id<Currency>(self: &Listing<Currency>): ID {
    self.edition_id
}

public fun edition_number<Currency>(self: &Listing<Currency>): u32 {
    self.edition_number
}

public fun price<Currency>(self: &Listing<Currency>): u64 {
    self.price.amount()
}

public fun price_terms<Currency>(self: &Listing<Currency>): Price {
    self.price
}

public fun window<Currency>(self: &Listing<Currency>): Window {
    self.window
}

public fun sold<Currency>(self: &Listing<Currency>): u64 {
    self.sold
}

/// Flat projection of `window`: when the listing opens.
public fun start_timestamp_ms<Currency>(self: &Listing<Currency>): u64 {
    match (self.window) {
        Window::Unbounded { start_timestamp_ms } => start_timestamp_ms,
        Window::Bounded { start_timestamp_ms, .. } => start_timestamp_ms,
    }
}

/// Flat projection of `window`: the close, or `none` if unbounded.
public fun end_timestamp_ms<Currency>(self: &Listing<Currency>): Option<u64> {
    match (self.window) {
        Window::Unbounded { .. } => option::none(),
        Window::Bounded { end_timestamp_ms, .. } => option::some(end_timestamp_ms),
    }
}

/// Whether the clock is inside the listing's window.
public fun is_in_window<Currency>(self: &Listing<Currency>, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    match (self.window) {
        Window::Unbounded { start_timestamp_ms } => now >= start_timestamp_ms,
        Window::Bounded { start_timestamp_ms, end_timestamp_ms } => {
            now >= start_timestamp_ms && now <= end_timestamp_ms
        },
    }
}

/// Whether the listing's bounded window has elapsed (always `false` if unbounded).
public fun is_expired<Currency>(self: &Listing<Currency>, clock: &Clock): bool {
    match (self.window) {
        Window::Unbounded { .. } => false,
        Window::Bounded { end_timestamp_ms, .. } => clock.timestamp_ms() > end_timestamp_ms,
    }
}

/// Whether `buy` would be accepted right now: the right edition, still listed, and inside
/// the window. Sold-out needs no check of its own — the run seals itself on its last mint.
public fun is_live<Currency>(self: &Listing<Currency>, edition: &Edition, clock: &Clock): bool {
    self.edition_id == edition.id() && edition.is_listed() && self.is_in_window(clock)
}

/// The price amount (the fixed price, or the floor).
public fun amount(self: &Price): u64 {
    match (self) {
        Price::Fixed { amount } => *amount,
        Price::Floor { amount } => *amount,
    }
}

//=== Test Helpers ===

/// Build an unshared `Listing` on a fresh UID, for tests of `buy` that have no edition to
/// derive off.
#[test_only]
public fun new_for_testing<Currency>(
    release_id: ID,
    edition_id: ID,
    edition_number: u32,
    price: Price,
    window: Window,
    ctx: &mut TxContext,
): Listing<Currency> {
    Listing {
        id: object::new(ctx),
        release_id,
        edition_id,
        edition_number,
        price,
        window,
        sold: 0,
    }
}

#[test_only]
public fun destroy_for_testing<Currency>(self: Listing<Currency>) {
    let Listing { id, .. } = self;
    id.delete();
}
