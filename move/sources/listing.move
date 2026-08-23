// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// One currency's offer on a pressing — a *Listing*.
///
/// A listing answers exactly two questions: **what does it cost** and **can you pay
/// in this currency**. Everything about *what you get* — the run, the number —
/// belongs to the `Pressing`. So a pressing sold in SUI and in USDC has two listings,
/// each with its own price and switch, both drawing on the same number sequence.
///
/// A listing's UID is derived off its pressing's UID at `ListingKey<Currency>()`, so
/// there is exactly one listing per (pressing, currency) — ever — and its address is
/// computable from the pressing's alone. The key is *phantom-typed* rather than a
/// stored `TypeName`, which makes the currency part of the key's type: distinct
/// currencies are distinct key types, so `derived_object::claim` enforces
/// once-per-currency by itself and the pressing needs no set of currencies to check
/// against. Listings are **permanent**: never destroyed, never replaced. The offer
/// changes *in place* — repriced, disabled, re-enabled — and the listing keeps its
/// identity through every change.
///
/// # Price
///
/// `Fixed` (pay exactly) or `Floor` (pay at least; overpayment is kept as a tip, not
/// refunded). The whole payment forwards to the release's address. Settable with the
/// `PressingAdminCap` (`set_price`) — repricing is an edit, not a teardown — and a
/// change cannot catch a buyer out: a `Fixed` buyer pays *exactly*, so a stale
/// payment aborts against a new price, and a `Floor` buyer never pays more than the
/// balance they sent.
///
/// Payment is a `Balance<Currency>`, never a `Coin<Currency>`. A coin is a wrapper an
/// object id, an owner, and a wrapping/unwrapping round trip — that this path has no
/// use for: the money comes in from wherever the PTB got it (a withdrawal off the
/// buyer's accumulator, a `coin::into_balance`, a split of some larger balance) and
/// goes straight back out to the release's address via `balance::send_funds`. Taking
/// the bare value means `buy` never mints an object just to destroy it, and never
/// forces the caller to make one either.
///
/// # Two switches
///
/// A listing is `Enabled` or `Disabled`; a disabled listing takes no payment in its
/// currency, while the pressing's other currencies carry on. Above it, the pressing's
/// own `Scheduled → Active → Paused` governs every currency at once
/// (`pressing::mint_next`). A sale needs both open.
///
/// The **when** lives on the pressing, not here: a drop moment is a fact about the
/// release going on sale, not about one payment rail, and a run that opened in SUI at
/// Friday 8pm and in USDC at some other time would have two drop moments and one
/// number sequence. So a listing carries no schedule — only whether its currency is
/// taken.
///
/// # The certificate
///
/// What the buyer paid is not part of the record — it is a fact about the *sale* — so
/// it rides out on the record's `Certificate`, stamped by `pressing::mint_next`
/// alongside the number. One field, written once, in the transaction that pressed the
/// record. `RecordSoldEvent` also snapshots both the accepted `Price` and the amount
/// paid, so an indexer can distinguish fixed sales from floor sales and compute tips
/// without replaying listing state.
module miso_pressing::listing;

use miso_pressing::certificate::Certificate;
use miso_pressing::pressing::{Pressing, PressingAdminCap};
use miso_record::record::Record;
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

/// Key for deriving a `Listing`'s UID off its PRESSING's UID. The currency rides in
/// the key's *type*, so one currency's key can never collide with another's — the
/// derived claim is the whole uniqueness check. Uses the currency type as written, so
/// upgrading the currency's package does not move the listing.
public struct ListingKey<phantom Currency>() has copy, drop, store;

/// One currency's offer on one pressing. Permanent; edited in place, never destroyed.
public struct Listing<phantom Currency> has key {
    id: UID,
    /// The release whose address collects the proceeds.
    release_id: ID,
    /// The pressing these records come out of.
    pressing_id: ID,
    /// What a buyer must pay per record.
    price: Price,
    /// Whether this currency is accepted right now.
    state: ListingState,
}

//=== Enums ===

/// Pricing policy for a listing.
public enum Price has copy, drop, store {
    /// Pay exactly `amount`.
    Fixed { amount: u64 },
    /// Pay at least `amount`; overpayment is forwarded to the release, not refunded.
    Floor { amount: u64 },
}

/// Whether this currency is accepted. Set at creation and by `set_state`.
public enum ListingState has copy, drop, store {
    /// Accepting payment in this currency, if the pressing is also active.
    Enabled,
    /// Not accepting payment in this currency. Other currencies are unaffected.
    Disabled,
}

//=== Events ===

/// A currency listing's initial identity, terms, and state.
public struct ListingOpenedEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    pressing_id: ID,
    release_id: ID,
    price: Price,
    state: ListingState,
}

/// The accepted offer and resulting record for one sale. `Currency` is carried in the
/// event type, while `price` and `paid` preserve the ask and the actual payment.
public struct RecordSoldEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    pressing_id: ID,
    release_id: ID,
    record_id: ID,
    number: u64,
    /// The offer accepted by this sale. Together with `paid`, this distinguishes a
    /// fixed-price sale from a floor-price sale and makes any tip directly computable.
    price: Price,
    paid: u64,
    buyer: address,
}

/// A currency listing's new enabled/disabled state.
public struct ListingStateChangedEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    pressing_id: ID,
    state: ListingState,
}

/// A currency listing's new standing price.
public struct ListingPriceChangedEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    pressing_id: ID,
    price: Price,
}

//=== Errors ===

// Authorization errors

/// This admin cap does not control this listing's pressing
const EUnauthorized: u64 = 0;

/// That is not the pressing this listing sells from
const EWrongPressing: u64 = 1;

// State errors

/// This listing does not accept payment in this currency
const EListingDisabled: u64 = 2;

// Validation errors

/// Payment does not satisfy the listing's price
const EInsufficientPayment: u64 = 3;

//=== Term Constructors ===

/// A fixed price: a buyer must pay exactly `amount`.
public fun new_fixed_price(amount: u64): Price {
    Price::Fixed { amount }
}

/// A floor price: a buyer must pay at least `amount`; overpayment is kept.
public fun new_floor_price(amount: u64): Price {
    Price::Floor { amount }
}

/// The enabled state: this currency is accepted.
public fun new_enabled_state(): ListingState {
    ListingState::Enabled
}

/// The disabled state: this currency is not accepted.
public fun new_disabled_state(): ListingState {
    ListingState::Disabled
}

//=== Public Functions ===

/// List the pressing for sale in `Currency` at the given price and state, and share
/// it.
///
/// Exactly one listing per (pressing, currency), ever: the slot is a derived-object
/// claim on the pressing at `ListingKey<Currency>()`, and listings are never
/// destroyed — so a second call for the same currency aborts in the claim. Every
/// later change to this currency's offer is an edit to this object, not a
/// replacement of it.
public fun new<Currency>(
    pressing: &mut Pressing,
    cap: &PressingAdminCap,
    price: Price,
    state: ListingState,
) {
    pressing.authorize(cap);

    let release_id = pressing.release_id();
    let pressing_id = object::id(pressing);
    let id = derived_object::claim(pressing.uid_mut(), ListingKey<Currency>());

    emit(ListingOpenedEvent<Currency> {
        listing_id: id.to_inner(),
        pressing_id,
        release_id,
        price,
        state,
    });

    transfer::share_object(Listing<Currency> { id, release_id, pressing_id, price, state })
}

/// Buy one record: pay this listing's price, take the next number out of the pressing.
///
/// `payment` is a bare `Balance<Currency>` and must satisfy the price (exactly, for
/// `Fixed`; at least, for `Floor`). The ENTIRE payment forwards to the release's
/// address — under `Floor`, anything above the floor is kept as a tip, not refunded.
/// The record's number is the pressing's next 1-based value, shared with every other
/// currency selling the same run, and its UID is derived off the pressing. The sale's
/// transaction sender and terms are embedded in the record's `Certificate`.
///
/// Both switches must be open: this listing `Enabled`, checked here, and the run
/// selling at this moment, checked in `pressing::mint_next`.
#[allow(lint(prefer_mut_tx_context))]
public fun buy<Currency>(
    self: &mut Listing<Currency>,
    pressing: &mut Pressing,
    payment: Balance<Currency>,
    clock: &Clock,
    ctx: &TxContext,
): Record<Certificate> {
    assert!(self.pressing_id == object::id(pressing), EWrongPressing);
    assert!(self.is_enabled(), EListingDisabled);

    let paid = payment.value();
    match (self.price) {
        Price::Fixed { amount } => assert!(paid == amount, EInsufficientPayment),
        Price::Floor { amount } => assert!(paid >= amount, EInsufficientPayment),
    };

    // Forward the entire payment to the release's address (funds accumulator); the
    // release / royalty layer redeems + splits it downstream. A free listing (price 0)
    // skips the send so we never open a zero-value accumulator slot.
    if (paid > 0) {
        balance::send_funds(payment, self.release_id.to_address());
    } else {
        payment.destroy_zero();
    };

    // The pressing owns the number, checks the run-wide switch, stamps the record's
    // birth date off the clock, and embeds who purchased it and what they paid. Read
    // the sender once so the certificate and sale event cannot disagree.
    let purchased_by = ctx.sender();
    let record = pressing.mint_next<Currency>(purchased_by, paid, clock);

    emit(RecordSoldEvent<Currency> {
        listing_id: self.id.to_inner(),
        pressing_id: self.pressing_id,
        release_id: self.release_id,
        record_id: object::id(&record),
        // mint_next just advanced the counter to this record's number.
        number: pressing.supply(),
        price: self.price,
        paid,
        buyer: purchased_by,
    });

    record
}

/// Enable or disable this currency. Leaves every other currency untouched; to stop
/// the whole run at once, pause the pressing (`pressing::set_state`).
public fun set_state<Currency>(
    self: &mut Listing<Currency>,
    cap: &PressingAdminCap,
    state: ListingState,
) {
    self.authorize(cap);
    self.state = state;
    emit(ListingStateChangedEvent<Currency> {
        listing_id: self.id.to_inner(),
        pressing_id: self.pressing_id,
        state,
    });
}

/// Reprice the listing in place. Safe against in-flight buys by construction: a
/// `Fixed` buyer pays exactly, so a stale payment aborts against the new price, and a
/// `Floor` buyer never pays more than the coin they sent.
public fun set_price<Currency>(
    self: &mut Listing<Currency>,
    cap: &PressingAdminCap,
    price: Price,
) {
    self.authorize(cap);
    self.price = price;
    emit(ListingPriceChangedEvent<Currency> {
        listing_id: self.id.to_inner(),
        pressing_id: self.pressing_id,
        price,
    });
}

//=== Internal ===

/// Abort unless `cap` controls this listing's pressing.
fun authorize<Currency>(self: &Listing<Currency>, cap: &PressingAdminCap) {
    assert!(cap.pressing_id() == self.pressing_id, EUnauthorized);
}

//=== View Functions ===

/// The address `Currency`'s listing on `pressing_id` occupies — pure address math,
/// computable before the listing exists.
public fun derive_id<Currency>(pressing_id: ID): ID {
    derived_object::derive_address(pressing_id, ListingKey<Currency>()).to_id()
}

/// Whether `pressing` has a listing in `Currency` yet. Reads the derived slot
/// directly, so the pressing stores no set of currencies; to enumerate every listing,
/// index `ListingOpenedEvent<Currency>`.
public fun has_listing<Currency>(pressing: &Pressing): bool {
    derived_object::exists(pressing.uid(), ListingKey<Currency>())
}

public fun release_id<Currency>(self: &Listing<Currency>): ID {
    self.release_id
}

public fun pressing_id<Currency>(self: &Listing<Currency>): ID {
    self.pressing_id
}

public fun price<Currency>(self: &Listing<Currency>): Price {
    self.price
}

public fun state<Currency>(self: &Listing<Currency>): ListingState {
    self.state
}

/// Whether `buy` would be accepted right now: the right pressing, this currency
/// enabled, and the run selling at this moment (open, and past its drop time if it
/// has one).
public fun is_live<Currency>(
    self: &Listing<Currency>,
    pressing: &Pressing,
    clock: &Clock,
): bool {
    self.pressing_id == object::id(pressing) && self.is_enabled() && pressing.is_selling(clock)
}

/// The price amount (the fixed price, or the floor).
public fun amount(self: &Price): u64 {
    match (self) {
        Price::Fixed { amount } => *amount,
        Price::Floor { amount } => *amount,
    }
}

//=== Internal ===

fun is_enabled<Currency>(self: &Listing<Currency>): bool {
    match (self.state) {
        ListingState::Enabled => true,
        ListingState::Disabled => false,
    }
}

//=== Test Helpers ===

// One-line derivations of `state()`; see the note in `pressing`. `is_live` is the
// public one, because it composes both switches and the clock.

#[test_only]
public fun opened_event_fields<Currency>(
    event: &ListingOpenedEvent<Currency>,
): (ID, ID, ID, Price, ListingState) {
    (event.listing_id, event.pressing_id, event.release_id, event.price, event.state)
}

#[test_only]
public fun sold_event_fields<Currency>(
    event: &RecordSoldEvent<Currency>,
): (ID, ID, ID, ID, u64, Price, u64, address) {
    (
        event.listing_id,
        event.pressing_id,
        event.release_id,
        event.record_id,
        event.number,
        event.price,
        event.paid,
        event.buyer,
    )
}

#[test_only]
public fun state_changed_event_fields<Currency>(
    event: &ListingStateChangedEvent<Currency>,
): (ID, ID, ListingState) {
    (event.listing_id, event.pressing_id, event.state)
}

#[test_only]
public fun price_changed_event_fields<Currency>(
    event: &ListingPriceChangedEvent<Currency>,
): (ID, ID, Price) {
    (event.listing_id, event.pressing_id, event.price)
}

#[test_only]
public fun is_enabled_for_testing<Currency>(self: &Listing<Currency>): bool {
    self.is_enabled()
}

#[test_only]
public fun is_disabled_for_testing<Currency>(self: &Listing<Currency>): bool {
    !self.is_enabled()
}

/// Build an unshared `Listing` on a fresh UID, for tests of `buy` that have no shared
/// pressing to go through.
#[test_only]
public fun new_for_testing<Currency>(
    release_id: ID,
    pressing_id: ID,
    price: Price,
    state: ListingState,
    ctx: &mut TxContext,
): Listing<Currency> {
    Listing { id: object::new(ctx), release_id, pressing_id, price, state }
}

#[test_only]
public fun destroy_for_testing<Currency>(self: Listing<Currency>) {
    let Listing { id, .. } = self;
    id.delete();
}
