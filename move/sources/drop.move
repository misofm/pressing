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
/// A drop may be capped (`max_supply` — "1000 records only"), time-boxed
/// (`end_timestamp_ms` — "two weeks only"), both, or neither (an open, evergreen
/// sale). Scarcity here is a per-edition decision by the artist, not a protocol
/// stance — and it is never a dead end: fans who miss a drop can always be answered
/// with a new edition. What a drop never has is an access gate: no allowlists,
/// auctions, or raffles — while a drop is live, anyone may buy.
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
/// Drop UIDs are *derived* off the shared `DropRegistry`, keyed by
/// `DropKey(release_id, edition)`, so every edition's address is computable from its
/// release and edition — and since claim markers outlive the objects they name, a
/// destroyed edition's key can never be claimed again. The registry also keeps a
/// `CurrentDropKey(release_id) → ID` pointer to the live drop (superseded drops are
/// deleted, so the pointer — not address probing — is how clients find the current
/// edition).
///
/// # Records
///
/// Serial numbers restart at 1 each edition: a record is "edition `e`, number `n`
/// (of `max_supply`)", and it stamps the `Currency` and the exact amount paid. A
/// record from a destroyed edition remains verifiable — `record::is_derived_from`
/// is pure address math and does not need the drop object alive.
///
/// # Authority
///
/// Opening edition 0 needs the release's `ReleaseAdminCap`; opening edition `n + 1`
/// needs the cap AND the predecessor drop. Minting is authorized separately: this
/// package presents its `MintWitness`, whose type must be on `miso_record`'s
/// `Settings` allowlist. A different shop with different mechanics is just another
/// package with its own witness — same `Record`, no `miso_record` redeploy.
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

/// Root object that all `Drop` UIDs are derived off. Shared once at publish; every
/// edition claims its drop off this registry keyed by `DropKey(release_id, edition)`,
/// and a `CurrentDropKey(release_id)` dynamic field points at each release's live drop.
public struct DropRegistry has key {
    id: UID,
}

/// Key for deriving a `Drop`'s UID off the `DropRegistry`: a release's `edition`
/// number. Scoped by `release_id` so each release owns an independent `0, 1, 2, …`
/// edition sequence. Claim markers persist even after a drop is destroyed, so an
/// edition key can never be reused.
public struct DropKey(ID, u32) has copy, drop, store;

/// Dynamic-field key on the `DropRegistry` holding the `ID` of a release's live drop.
/// Maintained by `new` / `new_edition`; needed because superseded drops are deleted,
/// so the current edition cannot be found by probing derived addresses.
public struct CurrentDropKey(ID) has copy, drop, store;

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
    /// Copies this edition may ever sell; `none` = uncapped (an open edition).
    max_supply: Option<u64>,
    /// Records sold so far; also the most recently sold record's number.
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
    max_supply: Option<u64>,
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
/// The drop has sold every one of its `max_supply` records.
const ESoldOut: u64 = 5;
/// A capped drop must be able to sell at least one record (`max_supply > 0`).
const EInvalidSupply: u64 = 6;

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

/// Create and share a release's FIRST drop — edition `0` — selling copies at `price`
/// within `[start_timestamp_ms, end_timestamp_ms]`, capped at `max_supply` (`none` =
/// uncapped). Authorized by the release's admin cap. The drop is immutable once
/// created; every later change (price, currency, a fresh run) is `new_edition`.
///
/// Edition 0's key can only ever be claimed once, so a release's edition sequence
/// can only ever start here — calling `new` twice for the same release aborts.
///
/// The window is validated against the `Clock`: a bounded `end` must be after both
/// `start` and now (you can't create an already-closed drop). `start` may be in the
/// future to schedule a drop.
public fun new<Currency>(
    registry: &mut DropRegistry,
    release: &Release,
    cap: &ReleaseAdminCap,
    price: Price,
    max_supply: Option<u64>,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
    clock: &Clock,
) {
    assert!(cap.release_id() == release.id(), EUnauthorized);
    assert_valid_terms(&max_supply, start_timestamp_ms, &end_timestamp_ms, clock);
    share_drop<Currency>(
        registry,
        release.id(),
        0,
        price,
        max_supply,
        start_timestamp_ms,
        end_timestamp_ms,
    );
}

/// Open the NEXT edition of a release's drop, CONSUMING the current one. The
/// predecessor shared object is destroyed — so at most one drop per release is ever
/// live, and this is the one way to change terms: a new price, a new `Currency`, a
/// new cap or window. It may be called while the predecessor is still selling (a
/// cutover) or after it sold out / closed (a fresh run for fans who missed it).
///
/// Records already sold by the predecessor are untouched and remain verifiable
/// against its (now deleted) id. Serial numbers restart at 1 for the new edition.
public fun new_edition<OldCurrency, NewCurrency>(
    registry: &mut DropRegistry,
    old: Drop<OldCurrency>,
    cap: &ReleaseAdminCap,
    price: Price,
    max_supply: Option<u64>,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
    clock: &Clock,
) {
    assert!(cap.release_id() == old.release_id, EUnauthorized);
    assert_valid_terms(&max_supply, start_timestamp_ms, &end_timestamp_ms, clock);

    let Drop { id, release_id, edition, .. } = old;
    id.delete();

    share_drop<NewCurrency>(
        registry,
        release_id,
        edition + 1,
        price,
        max_supply,
        start_timestamp_ms,
        end_timestamp_ms,
    );
}

/// Buy one record from a live drop — one inside its time window with supply left.
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
    self.max_supply.do_ref!(|cap| assert!(self.quantity_sold < *cap, ESoldOut));

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

/// Terms every edition must satisfy: a bounded window must be non-empty and not
/// already elapsed, and a cap must allow at least one sale.
fun assert_valid_terms(
    max_supply: &Option<u64>,
    start_timestamp_ms: u64,
    end_timestamp_ms: &Option<u64>,
    clock: &Clock,
) {
    max_supply.do_ref!(|cap| assert!(*cap > 0, EInvalidSupply));
    end_timestamp_ms.do_ref!(|end| {
        assert!(*end > start_timestamp_ms, EInvalidWindow);
        assert!(*end > clock.timestamp_ms(), EInvalidWindow);
    });
}

/// Claims the edition's derived UID, points the registry's `CurrentDropKey` at it,
/// emits `DropCreatedEvent`, and shares the drop.
fun share_drop<Currency>(
    registry: &mut DropRegistry,
    release_id: ID,
    edition: u32,
    price: Price,
    max_supply: Option<u64>,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
) {
    let id = derived_object::claim(&mut registry.id, DropKey(release_id, edition));
    let drop_id = id.to_inner();

    if (df::exists(&registry.id, CurrentDropKey(release_id))) {
        *df::borrow_mut(&mut registry.id, CurrentDropKey(release_id)) = drop_id;
    } else {
        df::add(&mut registry.id, CurrentDropKey(release_id), drop_id);
    };

    emit(DropCreatedEvent<Currency> {
        drop_id,
        release_id,
        edition,
        price_type: price.type_name(),
        price_amount: price.amount(),
        max_supply,
        start_timestamp_ms,
        end_timestamp_ms,
    });

    transfer::share_object(Drop<Currency> {
        id,
        release_id,
        edition,
        price,
        max_supply,
        quantity_sold: 0,
        start_timestamp_ms,
        end_timestamp_ms,
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

/// Copies this edition may ever sell; `none` = uncapped.
public fun max_supply<Currency>(self: &Drop<Currency>): Option<u64> {
    self.max_supply
}

/// Whether the drop has sold every one of its `max_supply` records (always `false`
/// for an uncapped drop).
public fun is_sold_out<Currency>(self: &Drop<Currency>): bool {
    self.max_supply.is_some() && self.quantity_sold >= *self.max_supply.borrow()
}

/// Whether `buy` would be accepted right now: inside the time window and not sold out.
public fun is_live<Currency>(self: &Drop<Currency>, clock: &Clock): bool {
    let now = clock.timestamp_ms();
    now >= self.start_timestamp_ms
        && (self.end_timestamp_ms.is_none() || now <= *self.end_timestamp_ms.borrow())
        && !self.is_sold_out()
}

public fun start_timestamp_ms<Currency>(self: &Drop<Currency>): u64 {
    self.start_timestamp_ms
}

public fun end_timestamp_ms<Currency>(self: &Drop<Currency>): Option<u64> {
    self.end_timestamp_ms
}

/// The `ID` of a release's live drop, or `none` if the release has never dropped.
/// (There is always at most one: `new_edition` destroys the predecessor.)
public fun current_drop_id(registry: &DropRegistry, release_id: ID): Option<ID> {
    if (!df::exists(&registry.id, CurrentDropKey(release_id))) return option::none();
    option::some(*df::borrow(&registry.id, CurrentDropKey(release_id)))
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

/// Build an unshared `Drop` for tests of `buy` / `new_edition` (real `new` shares it
/// and derives off the registry, which a unit test without a scenario can't retrieve).
#[test_only]
public fun new_for_testing<Currency>(
    release_id: ID,
    edition: u32,
    price: Price,
    max_supply: Option<u64>,
    start_timestamp_ms: u64,
    end_timestamp_ms: Option<u64>,
    ctx: &mut TxContext,
): Drop<Currency> {
    Drop {
        id: object::new(ctx),
        release_id,
        edition,
        price,
        max_supply,
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
