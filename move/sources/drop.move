// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A primary record sale — a *Drop*.
///
/// A `Drop` is a shared object that mints and sells numbered `Record` copies of a
/// release, forwarding each payment to the release's address, with no cap on how many
/// may ever be sold. Each purchase mints a `Record` whose UID is *derived* off the
/// `Drop`'s own UID (keyed by the 1-based serial number it was sold at), so every copy
/// is deterministically addressable from its drop and can be minted at most once.
///
/// # No access gate
///
/// A drop never gates *who* may buy. Supply is uncapped and anyone may buy a copy while
/// the drop is live. How "rare" a record becomes is a matter of how its owner engages
/// with it over time (an extension concern), never of manufactured scarcity at the
/// point of sale — so there are no caps, allowlists, auctions, or raffles here.
///
/// # Editions
///
/// A release may have many drops — a first run, a re-run, a variant. Each is an
/// *edition*: a 0-based run number scoped to the release. Drop UIDs are themselves
/// *derived* off the shared `DropRegistry`, keyed by `DropKey(release_id, edition)`,
/// which gives two things for free:
/// - **deterministic addressing** — a drop's address is computable from its release
///   and edition, and a record's from its drop and number; and
/// - **gap-free sequencing** — creating edition `n > 0` asserts edition `n - 1` already
///   exists for that release, and `derived_object::claim` rejects a duplicate edition.
///
/// # Window (the only mechanic)
///
/// A drop is **immutable** once created: its price and window are fixed. It sells
/// only within `[start_timestamp_ms, end_timestamp_ms]` — the close is optional (`none`
/// = evergreen, always buyable). Liveness is a pure function of the clock; there is no
/// manual pause. To end a limited run, set a close up front; to offer more later, drop
/// a new edition.
///
/// # Authority
///
/// Creating a drop needs the release's `ReleaseAdminCap` (which carries the
/// `release_id`). Minting is authorized separately: this package presents its
/// `MintWitness`, whose type must be on `miso_record`'s `Settings` allowlist. A
/// different shop with different mechanics is just another package with its own
/// witness — same `Record`, no `miso_record` redeploy.
module miso_drop::drop;

use miso::release::{Release, ReleaseAdminCap};
use miso_record::record::{Self, Record};
use miso_record::settings::Settings;
use sui::balance;
use sui::clock::Clock;
use sui::coin::Coin;
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

/// Root object that all `Drop` UIDs are derived off. Shared once at publish; every
/// `new` claims its drop off this registry keyed by `DropKey(release_id, edition)`.
public struct DropRegistry has key {
    id: UID,
}

/// Key for deriving a `Drop`'s UID off the `DropRegistry`: a release's `edition`
/// run number. Scoped by `release_id` so each release owns an independent `0, 1, 2, …`
/// edition sequence.
public struct DropKey(ID, u32) has copy, drop, store;

/// Witness authorizing `miso_record` mints. Constructible only inside this package,
/// and minted only on `buy`'s paid path — so possessing a value of it proves a valid
/// purchase happened. `miso_record::Settings` must authorize this *type* to mint.
public struct MintWitness has drop {}

/// A primary sale of `Record`s for one edition of a release. Immutable once created.
public struct Drop<phantom Currency> has key {
    id: UID,
    /// The release these records are copies of.
    release_id: ID,
    /// Which edition run of the release this is (0 = first drop).
    edition: u32,
    /// How much a buyer must pay per record.
    price: Price,
    /// Records sold so far; also the most recently sold record's number.
    /// Uncapped — a drop never runs out on quantity.
    quantity_sold: u64,
    /// Unix ms the drop opens (may be in the future — a scheduled drop). `buy`
    /// rejects purchases before it.
    start_timestamp_ms: u64,
    /// Unix ms the drop closes; `none` = evergreen (always buyable). `buy` rejects
    /// purchases after it.
    end_timestamp_ms: Option<u64>,
}

//=== Enums ===

/// Pricing policy for a drop.
public enum Price has copy, drop, store {
    /// Pay exactly `amount`.
    Fixed { amount: u64 },
    /// Pay at least `amount`; overpayment is forwarded to the release, not refunded.
    Floor { amount: u64 },
}

//=== Events ===

public struct DropCreatedEvent<phantom Currency> has copy, drop {
    drop_id: ID,
    release_id: ID,
    edition: u32,
    price_type: vector<u8>,
    price_amount: u64,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
}

public struct RecordSoldEvent<phantom Currency> has copy, drop {
    drop_id: ID,
    release_id: ID,
    edition: u32,
    record_id: ID,
    number: u64,
    paid: u64,
    buyer: address,
}

//=== Errors ===

/// The admin capability does not authorize this drop's release.
const EUnauthorized: u64 = 0;
/// Payment does not satisfy the drop's price.
const EInsufficientPayment: u64 = 1;
/// The drop has not opened yet (`now < start_timestamp_ms`).
const EDropNotStarted: u64 = 2;
/// The drop has closed (`now > end_timestamp_ms`).
const EDropClosed: u64 = 3;
/// The requested `[start, end]` window is empty or already in the past.
const EInvalidWindow: u64 = 4;
/// Editions must be created in sequence: edition `n > 0` requires edition `n - 1` to
/// already exist for this release.
const ENonSequentialEdition: u64 = 5;

//=== Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(DropRegistry { id: object::new(ctx) });
}

//=== Price Constructors ===

/// A fixed price: a buyer must pay exactly `amount`.
public fun new_fixed_price(amount: u64): Price {
    Price::Fixed { amount }
}

/// A floor price: a buyer must pay at least `amount`; overpayment is kept.
public fun new_floor_price(amount: u64): Price {
    Price::Floor { amount }
}

//=== Public Functions ===

/// Create and share a new `Drop` — edition `edition_hint` of `release` — selling
/// copies at `price` within `[start_timestamp_ms, end_timestamp_ms]`, with no quantity
/// cap. Authorized by the release's admin cap. The drop is immutable once created.
///
/// `edition_hint` is the run number to create; it must be the next in the release's
/// sequence — edition `n > 0` requires edition `n - 1` to already exist, and reusing an
/// edition aborts — so editions are always gap-free. Pass `0` for a release's first
/// drop.
///
/// The window is validated against the `Clock`: a bounded `end` must be after both
/// `start` and now (you can't create an already-closed drop). `start` may be in the
/// future to schedule a drop.
public fun new<Currency>(
    registry: &mut DropRegistry,
    release: &Release,
    cap: &ReleaseAdminCap,
    price: Price,
    edition_hint: u32,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
    clock: &Clock,
) {
    assert!(cap.release_id() == release.id(), EUnauthorized);
    let release_id = release.id();

    // Editions are gap-free: creating edition n>0 requires n-1 to already exist for
    // this release. `derived_object::claim` below separately rejects a duplicate edition.
    if (edition_hint > 0) {
        assert!(
            derived_object::exists(&registry.id, DropKey(release_id, edition_hint - 1)),
            ENonSequentialEdition,
        );
    };

    // A bounded window must be non-empty and not already elapsed.
    end_timestamp_ms.do_ref!(|end| {
        assert!(*end > start_timestamp_ms, EInvalidWindow);
        assert!(*end > clock.timestamp_ms(), EInvalidWindow);
    });

    let id = derived_object::claim(&mut registry.id, DropKey(release_id, edition_hint));

    emit(DropCreatedEvent<Currency> {
        drop_id: id.to_inner(),
        release_id,
        edition: edition_hint,
        price_type: price.type_name(),
        price_amount: price.amount(),
        start_timestamp_ms,
        end_timestamp_ms,
    });

    transfer::share_object(Drop<Currency> {
        id,
        release_id,
        edition: edition_hint,
        price,
        quantity_sold: 0,
        start_timestamp_ms,
        end_timestamp_ms,
    });
}

/// Buy one record from a live drop — one within its time window.
///
/// `payment` must satisfy the price (exactly, for `Fixed`; at least, for `Floor`). The
/// ENTIRE payment is forwarded to the release's address — under `Floor`, anything paid
/// above the floor is kept (a pay-what-you-want tip), not refunded. The sold record's
/// number is the 1-based `quantity_sold` count, its UID is derived off the drop, and
/// it records the drop's `edition`, the `Currency`, and the amount paid. `settings`
/// must authorize this package's `MintWitness`.
public fun buy<Currency>(
    self: &mut Drop<Currency>,
    payment: Coin<Currency>,
    settings: &Settings,
    clock: &Clock,
    ctx: &mut TxContext,
): Record {
    let now = clock.timestamp_ms();
    assert!(now >= self.start_timestamp_ms, EDropNotStarted);
    self.end_timestamp_ms.do_ref!(|end| assert!(now <= *end, EDropClosed));

    let paid = payment.value();
    match (self.price) {
        Price::Fixed { amount } => assert!(paid == amount, EInsufficientPayment),
        Price::Floor { amount } => assert!(paid >= amount, EInsufficientPayment),
    };

    // Forward the entire payment to the release's address (funds accumulator); the
    // release / royalty layer redeems + splits it downstream. A free drop (price 0)
    // skips the send so we never open a zero-value accumulator slot.
    if (paid > 0) {
        balance::send_funds(payment.into_balance(), self.release_id.to_address());
    } else {
        payment.destroy_zero();
    };
    self.quantity_sold = self.quantity_sold + 1;

    let record = record::mint_derived<MintWitness, Currency>(
        MintWitness {},
        settings,
        &mut self.id,
        self.release_id,
        self.edition,
        self.quantity_sold,
        paid,
        ctx,
    );

    emit(RecordSoldEvent<Currency> {
        drop_id: self.id.to_inner(),
        release_id: self.release_id,
        edition: self.edition,
        record_id: record.id(),
        number: self.quantity_sold,
        paid,
        buyer: ctx.sender(),
    });

    record
}

//=== View Functions ===

public fun id<Currency>(self: &Drop<Currency>): ID {
    self.id.to_inner()
}

public fun release_id<Currency>(self: &Drop<Currency>): ID {
    self.release_id
}

public fun edition<Currency>(self: &Drop<Currency>): u32 {
    self.edition
}

public fun quantity_sold<Currency>(self: &Drop<Currency>): u64 {
    self.quantity_sold
}

public fun price<Currency>(self: &Drop<Currency>): u64 {
    self.price.amount()
}

/// Whether `buy` would be accepted right now: inside the time window.
public fun is_live<Currency>(self: &Drop<Currency>, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    now >= self.start_timestamp_ms
        && (self.end_timestamp_ms.is_none() || now <= *self.end_timestamp_ms.borrow())
}

public fun start_timestamp_ms<Currency>(self: &Drop<Currency>): u64 {
    self.start_timestamp_ms
}

public fun end_timestamp_ms<Currency>(self: &Drop<Currency>): Option<u64> {
    self.end_timestamp_ms
}

/// The price amount (the fixed price, or the floor).
public fun amount(self: &Price): u64 {
    match (self) {
        Price::Fixed { amount } => *amount,
        Price::Floor { amount } => *amount,
    }
}

/// A short label for the price policy: `b"Fixed"` or `b"Floor"`.
public fun type_name(self: &Price): vector<u8> {
    match (self) {
        Price::Fixed { .. } => b"Fixed",
        Price::Floor { .. } => b"Floor",
    }
}

//=== Test Helpers ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun new_registry_for_testing(ctx: &mut TxContext): DropRegistry {
    DropRegistry { id: object::new(ctx) }
}

#[test_only]
public fun destroy_registry_for_testing(registry: DropRegistry) {
    let DropRegistry { id } = registry;
    id.delete();
}

/// Build an unshared `Drop` for tests of `buy` (real `new` shares it and derives
/// off the registry, which a unit test without a scenario can't retrieve).
#[test_only]
public fun new_for_testing<Currency>(
    release_id: ID,
    edition: u32,
    price: Price,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
    ctx: &mut TxContext,
): Drop<Currency> {
    Drop {
        id: object::new(ctx),
        release_id,
        edition,
        price,
        quantity_sold: 0,
        start_timestamp_ms,
        end_timestamp_ms,
    }
}

#[test_only]
public fun destroy_for_testing<Currency>(self: Drop<Currency>) {
    let Drop { id, .. } = self;
    id.delete();
}
