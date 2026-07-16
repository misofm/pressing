// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A primary record sale — a *Drop*.
///
/// A `Drop` is a shared object that mints and sells numbered `Record` copies of a
/// release, forwarding each payment to the release's address. Each purchase mints a
/// `Record` whose UID is *derived* off the `Drop`'s own UID (keyed by the 1-based
/// serial number it was sold at), so every copy is deterministically addressable from
/// its drop and can be minted at most once.
///
/// # Scarcity is the artist's choice
///
/// A drop's terms are three enums, each fixed at creation:
/// - `Price` — `Fixed` (pay exactly) or `Floor` (pay at least; overpayment kept);
/// - `Supply` — `Uncapped`, or `Capped { max }` ("1000 records only");
/// - `Window` — `Unbounded { start }`, or `Bounded { start, end }` ("two weeks only").
///
/// Scarcity is a per-edition decision by the artist, not a protocol stance — and it
/// is never a dead end: fans who miss a drop can always be answered with a new
/// edition. What a drop never has is an access gate: no allowlists, auctions, or
/// raffles — while a drop is live, anyone may buy.
///
/// # Editions — one live drop per release
///
/// A release sells through at most ONE drop at a time. `new` opens edition `0`;
/// `new_edition` opens edition `n + 1` by CONSUMING edition `n` — the predecessor
/// shared object is destroyed, so two editions can never sell side by side, and the
/// edition sequence is gap-free by construction (you must hold edition `n` to open
/// `n + 1`). Because a drop is immutable once created, `new_edition` is also the only
/// way to change anything: a new price, a new currency, a fresh run after a sell-out
/// or a closed window — each is simply the next edition.
///
/// The RELEASE is the parent: drop UIDs are *derived* off the release's UID (via its
/// cap-gated `uid_mut` extension surface), keyed by `DropKey(edition)`. Every
/// edition's address is therefore computable from the release id alone — and since
/// claim markers outlive the objects they name, a destroyed edition's key can never
/// be claimed again. The release's UID also carries a `CurrentDropKey → ID` dynamic
/// field pointing at the live drop (superseded drops are deleted, so the pointer —
/// not address probing — is how clients find the current edition).
///
/// # Records
///
/// Serial numbers restart at 1 each edition: a record is "edition `e`, number `n`
/// (of `max`)", and it stamps the `Currency` and the exact amount paid. A record
/// from a destroyed edition remains verifiable — `record::is_derived_from` is pure
/// address math and does not need the drop object alive.
///
/// # Authority
///
/// Opening edition 0 needs the release's `ReleaseAdminCap` (enforced by the
/// protocol's `release::uid_mut`); opening edition `n + 1` needs the cap AND the
/// predecessor drop. Minting is authorized separately: this package presents its
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
use sui::dynamic_field as df;
use sui::event::emit;

//=== Structs ===

/// Key for deriving a `Drop`'s UID off its RELEASE's UID: the edition number. Each
/// release owns an independent `0, 1, 2, …` edition sequence. Claim markers persist
/// on the release even after a drop is destroyed, so an edition key can never be
/// reused.
public struct DropKey(u32) has copy, drop, store;

/// Dynamic-field key on the RELEASE's UID holding the `ID` of its live drop.
/// Maintained by `new` / `new_edition`; needed because superseded drops are deleted,
/// so the current edition cannot be found by probing derived addresses.
public struct CurrentDropKey() has copy, drop, store;

/// Witness authorizing `miso_record` mints. Constructible only inside this package,
/// and minted only on `buy`'s paid path — so possessing a value of it proves a valid
/// purchase happened. `miso_record::Settings` must authorize this *type* to mint.
public struct MintWitness has drop {}

/// A primary sale of `Record`s for one edition of a release. Immutable once created;
/// to change anything, open the next edition with `new_edition`.
public struct Drop<phantom Currency> has key {
    id: UID,
    /// The release these records are copies of.
    release_id: ID,
    /// Which edition of the release this is (0 = first drop).
    edition: u32,
    /// How much a buyer must pay per record.
    price: Price,
    /// How many records this edition may ever sell.
    supply: Supply,
    /// Records sold so far; also the most recently sold record's number.
    quantity_sold: u64,
    /// When this edition sells.
    window: Window,
}

//=== Enums ===

/// Pricing policy for a drop.
public enum Price has copy, drop, store {
    /// Pay exactly `amount`.
    Fixed { amount: u64 },
    /// Pay at least `amount`; overpayment is forwarded to the release, not refunded.
    Floor { amount: u64 },
}

/// Supply policy for a drop.
public enum Supply has copy, drop, store {
    /// No quantity limit — the edition never sells out.
    Uncapped,
    /// Sells out after `max` records.
    Capped { max: u64 },
}

/// When a drop sells. `buy` rejects purchases outside the window.
public enum Window has copy, drop, store {
    /// Opens at `start_timestamp_ms` (Unix ms; may be in the future — a scheduled
    /// drop) and never closes.
    Unbounded { start_timestamp_ms: u64 },
    /// Sells only within `[start_timestamp_ms, end_timestamp_ms]` (Unix ms).
    Bounded { start_timestamp_ms: u64, end_timestamp_ms: u64 },
}

//=== Events ===

public struct DropCreatedEvent<phantom Currency> has copy, drop {
    drop_id: ID,
    release_id: ID,
    edition: u32,
    price: Price,
    supply: Supply,
    window: Window,
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

/// The drop being superseded does not belong to this release.
const EUnauthorized: u64 = 0;
/// Payment does not satisfy the drop's price.
const EInsufficientPayment: u64 = 1;
/// The drop has not opened yet (`now < start_timestamp_ms`).
const EDropNotStarted: u64 = 2;
/// The drop has closed (`now > end_timestamp_ms`).
const EDropClosed: u64 = 3;
/// A bounded window must be non-empty and not already elapsed.
const EInvalidWindow: u64 = 4;
/// The drop has sold every one of its `Capped { max }` records.
const ESoldOut: u64 = 5;
/// A capped supply must be able to sell at least one record (`max > 0`).
const EInvalidSupply: u64 = 6;

//=== Term Constructors ===

/// A fixed price: a buyer must pay exactly `amount`.
public fun new_fixed_price(amount: u64): Price {
    Price::Fixed { amount }
}

/// A floor price: a buyer must pay at least `amount`; overpayment is kept.
public fun new_floor_price(amount: u64): Price {
    Price::Floor { amount }
}

/// An uncapped supply: the edition never sells out.
public fun new_uncapped_supply(): Supply {
    Supply::Uncapped
}

/// A capped supply: the edition sells out after `max` records. `max` must be at
/// least 1.
public fun new_capped_supply(max: u64): Supply {
    assert!(max > 0, EInvalidSupply);
    Supply::Capped { max }
}

/// A window that opens at `start_timestamp_ms` (may be in the future) and never
/// closes.
public fun new_unbounded_window(start_timestamp_ms: u64): Window {
    Window::Unbounded { start_timestamp_ms }
}

/// A window selling only within `[start_timestamp_ms, end_timestamp_ms]`. The close
/// must be strictly after the open.
public fun new_bounded_window(start_timestamp_ms: u64, end_timestamp_ms: u64): Window {
    assert!(end_timestamp_ms > start_timestamp_ms, EInvalidWindow);
    Window::Bounded { start_timestamp_ms, end_timestamp_ms }
}

//=== Public Functions ===

/// Create and share a release's FIRST drop — edition `0` — selling copies on the
/// given `price` / `supply` / `window` terms. Authorized by the release's admin cap
/// (enforced by `release::uid_mut`). The drop is immutable once created; every later
/// change (price, currency, a fresh run) is `new_edition`.
///
/// Edition 0's key can only ever be claimed once, so a release's edition sequence
/// can only ever start here — calling `new` twice for the same release aborts.
///
/// Term validity is enforced at construction (`new_capped_supply`,
/// `new_bounded_window`); the one check left here is temporal — a bounded window
/// must not already be elapsed against the `Clock`.
public fun new<Currency>(
    release: &mut Release,
    cap: &ReleaseAdminCap,
    price: Price,
    supply: Supply,
    window: Window,
    clock: &Clock,
) {
    assert_window_not_elapsed(&window, clock);
    let release_id = release.id();
    share_drop<Currency>(release.uid_mut(cap), release_id, 0, price, supply, window);
}

/// Open the NEXT edition of a release's drop, CONSUMING the current one. The
/// predecessor shared object is destroyed — so at most one drop per release is ever
/// live, and this is the one way to change terms: a new price, a new `Currency`, a
/// new supply or window. It may be called while the predecessor is still selling (a
/// cutover) or after it sold out / closed (a fresh run for fans who missed it).
///
/// Records already sold by the predecessor are untouched and remain verifiable
/// against its (now deleted) id. Serial numbers restart at 1 for the new edition.
public fun new_edition<OldCurrency, NewCurrency>(
    release: &mut Release,
    old: Drop<OldCurrency>,
    cap: &ReleaseAdminCap,
    price: Price,
    supply: Supply,
    window: Window,
    clock: &Clock,
) {
    assert!(old.release_id == release.id(), EUnauthorized);
    assert_window_not_elapsed(&window, clock);

    let Drop { id, release_id, edition, .. } = old;
    id.delete();

    share_drop<NewCurrency>(release.uid_mut(cap), release_id, edition + 1, price, supply, window);
}

/// Buy one record from a live drop — one inside its window with supply left.
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
    match (self.window) {
        Window::Unbounded { start_timestamp_ms } => {
            assert!(now >= start_timestamp_ms, EDropNotStarted);
        },
        Window::Bounded { start_timestamp_ms, end_timestamp_ms } => {
            assert!(now >= start_timestamp_ms, EDropNotStarted);
            assert!(now <= end_timestamp_ms, EDropClosed);
        },
    };
    match (self.supply) {
        Supply::Uncapped => (),
        Supply::Capped { max } => assert!(self.quantity_sold < max, ESoldOut),
    };

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

//=== Internal ===

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

/// Claims the edition's derived UID off the release's UID, points the release's
/// `CurrentDropKey` at it, emits `DropCreatedEvent`, and shares the drop.
fun share_drop<Currency>(
    parent: &mut UID,
    release_id: ID,
    edition: u32,
    price: Price,
    supply: Supply,
    window: Window,
) {
    let id = derived_object::claim(parent, DropKey(edition));
    let drop_id = id.to_inner();

    if (df::exists(parent, CurrentDropKey())) {
        *df::borrow_mut(parent, CurrentDropKey()) = drop_id;
    } else {
        df::add(parent, CurrentDropKey(), drop_id);
    };

    emit(DropCreatedEvent<Currency> { drop_id, release_id, edition, price, supply, window });

    transfer::share_object(Drop<Currency> {
        id,
        release_id,
        edition,
        price,
        supply,
        quantity_sold: 0,
        window,
    });
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

public fun supply<Currency>(self: &Drop<Currency>): Supply {
    self.supply
}

public fun window<Currency>(self: &Drop<Currency>): Window {
    self.window
}

/// Flat projection of `supply`: the cap, or `none` if uncapped.
public fun max_supply<Currency>(self: &Drop<Currency>): Option<u64> {
    match (self.supply) {
        Supply::Uncapped => option::none(),
        Supply::Capped { max } => option::some(max),
    }
}

/// Flat projection of `window`: when the drop opens.
public fun start_timestamp_ms<Currency>(self: &Drop<Currency>): u64 {
    match (self.window) {
        Window::Unbounded { start_timestamp_ms } => start_timestamp_ms,
        Window::Bounded { start_timestamp_ms, .. } => start_timestamp_ms,
    }
}

/// Flat projection of `window`: the close, or `none` if unbounded.
public fun end_timestamp_ms<Currency>(self: &Drop<Currency>): Option<u64> {
    match (self.window) {
        Window::Unbounded { .. } => option::none(),
        Window::Bounded { end_timestamp_ms, .. } => option::some(end_timestamp_ms),
    }
}

/// Whether the drop has sold every one of its `Capped { max }` records (always
/// `false` for an uncapped drop).
public fun is_sold_out<Currency>(self: &Drop<Currency>): bool {
    match (self.supply) {
        Supply::Uncapped => false,
        Supply::Capped { max } => self.quantity_sold >= max,
    }
}

/// Whether `buy` would be accepted right now: inside the window and not sold out.
public fun is_live<Currency>(self: &Drop<Currency>, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    let in_window = match (self.window) {
        Window::Unbounded { start_timestamp_ms } => now >= start_timestamp_ms,
        Window::Bounded { start_timestamp_ms, end_timestamp_ms } => {
            now >= start_timestamp_ms && now <= end_timestamp_ms
        },
    };
    in_window && !self.is_sold_out()
}

/// The `ID` of a release's live drop, or `none` if the release has never dropped.
/// (There is always at most one: `new_edition` destroys the predecessor.)
public fun current_drop_id(release: &Release): Option<ID> {
    if (!df::exists(release.uid(), CurrentDropKey())) return option::none();
    option::some(*df::borrow(release.uid(), CurrentDropKey()))
}

/// The price amount (the fixed price, or the floor).
public fun amount(self: &Price): u64 {
    match (self) {
        Price::Fixed { amount } => *amount,
        Price::Floor { amount } => *amount,
    }
}

//=== Test Helpers ===

/// Build an unshared `Drop` for tests of `buy` / `new_edition` (real `new` shares it
/// and derives off the release, which a unit test without a scenario can't retrieve).
#[test_only]
public fun new_for_testing<Currency>(
    release_id: ID,
    edition: u32,
    price: Price,
    supply: Supply,
    window: Window,
    ctx: &mut TxContext,
): Drop<Currency> {
    Drop {
        id: object::new(ctx),
        release_id,
        edition,
        price,
        supply,
        quantity_sold: 0,
        window,
    }
}

#[test_only]
public fun destroy_for_testing<Currency>(self: Drop<Currency>) {
    let Drop { id, .. } = self;
    id.delete();
}
