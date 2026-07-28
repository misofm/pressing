// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_drop::listing_tests;

use miso_drop::drop;
use miso_drop::edition::{Self, Edition};
use miso_drop::listing::{Self, Listing};
use miso_drop::test_utils::{a_release, authorized_settings, clock_at, id, USDX};
use miso_record::record;
use miso_record::settings;
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

/// Mirrors of the module-private abort codes (constants aren't importable).
const EUnauthorized: u64 = 0; // miso_drop::listing
const EInsufficientPayment: u64 = 1;
const ENotStarted: u64 = 2;
const EClosed: u64 = 3;
const EInvalidWindow: u64 = 4;
const EStillLive: u64 = 5;
const ENotListed: u64 = 3; // miso_drop::edition

/// A listed edition on a fresh UID, plus a matching listing registered against it.
fun a_listing<Currency>(
    supply: edition::Supply,
    price: listing::Price,
    window: listing::Window,
    ctx: &mut TxContext,
): (Edition, Listing<Currency>) {
    let mut e = edition::new_for_testing(id(@0xBEEF), id(@0xD0), 0, supply, ctx);
    e.register_currency<Currency>();
    let l = listing::new_for_testing<Currency>(id(@0xBEEF), e.id(), 0, price, window, ctx);
    (e, l)
}

//=== buy ===

#[test]
fun buy_stamps_the_record_and_counts_against_both() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx); // t = 0

    // Floor of 5; the buyer pays 8 — a 3-over tip, kept, not refunded.
    let (mut e, mut l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_floor_price(5),
        listing::new_unbounded_window(0),
        &mut ctx,
    );
    let edition_id = e.id();

    let payment = coin::mint_for_testing<SUI>(8, &mut ctx);
    let r = l.buy(&mut e, payment, &cfg, &clk, &ctx);

    assert!(r.purchase_price() == 8); // the full 8, tip included
    assert!(r.number() == 1);
    assert!(r.is_derived_from(edition_id)); // provenance is the edition, not the listing

    // The listing counts its own currency's sales; the edition counts the run's.
    assert!(l.sold() == 1);
    assert!(e.minted() == 1);

    record::destroy(r);
    l.destroy_for_testing();
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EInsufficientPayment, location = miso_drop::listing)]
fun buy_aborts_on_underpayment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut e, mut l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(10),
        listing::new_unbounded_window(0),
        &mut ctx,
    );

    let payment = coin::mint_for_testing<SUI>(9, &mut ctx);
    let r = l.buy(&mut e, payment, &cfg, &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EInsufficientPayment, location = miso_drop::listing)]
fun a_fixed_price_rejects_overpayment_too() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut e, mut l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(10),
        listing::new_unbounded_window(0),
        &mut ctx,
    );

    // Fixed means exactly — a tip needs a Floor price.
    let payment = coin::mint_for_testing<SUI>(11, &mut ctx);
    let r = l.buy(&mut e, payment, &cfg, &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ENotStarted, location = miso_drop::listing)]
fun buy_aborts_before_the_window_opens() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock_at(50, &mut ctx);
    let (mut e, mut l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(0),
        listing::new_unbounded_window(100), // scheduled for later
        &mut ctx,
    );

    let r = l.buy(&mut e, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EClosed, location = miso_drop::listing)]
fun buy_aborts_after_the_window_closes() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock_at(250, &mut ctx);
    let (mut e, mut l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(0),
        listing::new_bounded_window(100, 200),
        &mut ctx,
    );

    let r = l.buy(&mut e, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EUnauthorized, location = miso_drop::listing)]
fun buy_aborts_with_an_edition_this_listing_does_not_sell_from() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (e, mut l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(0),
        listing::new_unbounded_window(0),
        &mut ctx,
    );

    // A different run entirely — it must not be possible to draw its serials down.
    let mut other = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        1,
        edition::new_uncapped_supply(),
        &mut ctx,
    );
    let r = l.buy(&mut other, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);

    record::destroy(r);
    other.destroy_for_testing();
    l.destroy_for_testing();
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

//=== Window construction ===

#[test]
#[expected_failure(abort_code = EInvalidWindow, location = miso_drop::listing)]
fun an_empty_window_aborts_at_construction() {
    listing::new_bounded_window(200, 200);
}

#[test]
#[expected_failure(abort_code = EInvalidWindow, location = miso_drop::listing)]
fun listing_with_an_already_elapsed_window_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);
    let clk = clock_at(500, &mut ctx);
    let mut e = edition::new_for_testing(
        rel.id(),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    // The window [100, 200] is already behind us.
    listing::new<SUI>(
        &mut e,
        &cap,
        listing::new_fixed_price(0),
        listing::new_bounded_window(100, 200),
        &clk,
    );

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ENotListed, location = miso_drop::edition)]
fun a_sealed_edition_takes_no_new_listings() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let mut e = edition::new_for_testing(
        rel.id(),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );
    e.seal(&cap);

    listing::new<SUI>(
        &mut e,
        &cap,
        listing::new_fixed_price(0),
        listing::new_unbounded_window(0),
        &clk,
    );

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}

//=== Liveness ===

#[test]
fun is_live_reflects_the_window_and_the_state() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let (mut e, mut l) = a_listing<SUI>(
        edition::new_capped_supply(1),
        listing::new_fixed_price(0),
        listing::new_bounded_window(100, 200),
        &mut ctx,
    );
    let mut clk = clock::create_for_testing(&mut ctx);

    // The test clock only moves forward, so assert in ascending order.
    clk.set_for_testing(50);
    assert!(!l.is_live(&e, &clk)); // before the window opens
    assert!(!l.is_expired(&clk));

    clk.set_for_testing(150);
    assert!(l.is_live(&e, &clk)); // inside

    // Selling the last record of the cap ends the run, mid-window.
    let r = l.buy(&mut e, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);
    assert!(e.is_sold_out());
    assert!(e.is_sealed()); // sold out sealed it in the same transaction
    assert!(!l.is_live(&e, &clk));

    clk.set_for_testing(250);
    assert!(l.is_expired(&clk));

    record::destroy(r);
    l.destroy_for_testing();
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

//=== Closing ===

#[test]
fun close_is_permissionless_once_the_edition_has_sold_out() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut e, mut l) = a_listing<SUI>(
        edition::new_capped_supply(1),
        listing::new_fixed_price(0),
        listing::new_unbounded_window(0),
        &mut ctx,
    );

    let r = l.buy(&mut e, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);
    l.close(&mut e, &clk); // no cap needed — buy already aborts on this listing

    // That was the only listing the sold-out run was carrying, so it wound down with it.
    assert!(e.is_closed());
    assert!(e.outstanding_listings() == 0);

    record::destroy(r);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
fun close_is_permissionless_once_the_window_has_elapsed() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(250, &mut ctx);
    let (mut e, l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(0),
        listing::new_bounded_window(100, 200),
        &mut ctx,
    );

    l.close(&mut e, &clk);

    // An expired listing does not have to wait for the whole run to end before it can be
    // cleared up — and clearing it up does not end the run.
    assert!(e.is_listed());
    assert!(!e.has_currency<SUI>());
    assert!(e.outstanding_listings() == 0);

    e.destroy_for_testing();
    clk.destroy_for_testing();
}

#[test]
fun close_is_permissionless_once_the_edition_is_sealed() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut e, l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(0),
        listing::new_unbounded_window(0),
        &mut ctx,
    );
    e.seal_for_testing();
    assert!(e.is_sealed());

    l.close(&mut e, &clk);

    assert!(e.is_closed());

    e.destroy_for_testing();
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EStillLive, location = miso_drop::listing)]
fun close_aborts_while_the_listing_is_still_sellable() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut e, l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(0),
        listing::new_unbounded_window(0),
        &mut ctx,
    );

    // Nothing has ended — pulling this offer is the artist's call, via `withdraw`.
    l.close(&mut e, &clk);

    e.destroy_for_testing();
    clk.destroy_for_testing();
}

#[test]
fun withdraw_closes_a_live_listing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);
    let mut e = edition::new_for_testing(
        rel.id(),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );
    e.register_currency<SUI>();
    let l = listing::new_for_testing<SUI>(
        rel.id(),
        e.id(),
        0,
        listing::new_fixed_price(0),
        listing::new_unbounded_window(0),
        &mut ctx,
    );

    l.withdraw(&mut e, &cap);

    // The run keeps selling — it just isn't listed in SUI any more.
    assert!(e.is_listed());
    assert!(!e.has_currency<SUI>());

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

#[test]
#[expected_failure(abort_code = EUnauthorized, location = miso_drop::listing)]
fun withdraw_aborts_with_a_cap_for_another_release() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);
    let (mut e, l) = a_listing<SUI>(
        edition::new_uncapped_supply(),
        listing::new_fixed_price(0),
        listing::new_unbounded_window(0),
        &mut ctx,
    );

    // The listing's release is @0xBEEF, not the one this cap controls.
    l.withdraw(&mut e, &cap);

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

//=== The whole chain, end to end ===

#[test]
fun one_edition_sells_in_two_currencies_off_one_cap() {
    let mut sc = ts::begin(@0xA);
    let (cfg, admin) = authorized_settings(sc.ctx());
    let clk = clock::create_for_testing(sc.ctx());
    let (mut rel, cap) = a_release(sc.ctx());
    let release_id = rel.id();

    // Open the drop and its first edition, capped at 3, and list it in two currencies —
    // all in one transaction, because `new` hands the edition back unshared.
    let mut e = drop::new(&mut rel, &cap, edition::new_capped_supply(3));
    let edition_id = e.id();
    listing::new<SUI>(
        &mut e,
        &cap,
        listing::new_fixed_price(10),
        listing::new_unbounded_window(0),
        &clk,
    );
    listing::new<USDX>(
        &mut e,
        &cap,
        listing::new_fixed_price(25),
        listing::new_unbounded_window(0),
        &clk,
    );
    assert!(e.has_currency<SUI>() && e.has_currency<USDX>());
    e.share();

    // Both listings sit exactly where the currency type says they should.
    assert!(listing::derive_id<SUI>(edition_id) != listing::derive_id<USDX>(edition_id));

    sc.next_tx(@0xA);
    let mut edition = sc.take_shared<Edition>();
    let mut sui_listing = sc.take_shared<Listing<SUI>>();
    let mut usdx_listing = sc.take_shared<Listing<USDX>>();

    assert!(sui_listing.id() == listing::derive_id<SUI>(edition_id));
    assert!(usdx_listing.id() == listing::derive_id<USDX>(edition_id));
    assert!(sui_listing.price() == 10);
    assert!(usdx_listing.price() == 25);

    // One numbered run, two payment rails: the serials interleave.
    let r1 = sui_listing.buy(
        &mut edition,
        coin::mint_for_testing<SUI>(10, sc.ctx()),
        &cfg,
        &clk,
        sc.ctx(),
    );
    let r2 = usdx_listing.buy(
        &mut edition,
        coin::mint_for_testing<USDX>(25, sc.ctx()),
        &cfg,
        &clk,
        sc.ctx(),
    );
    let r3 = sui_listing.buy(
        &mut edition,
        coin::mint_for_testing<SUI>(10, sc.ctx()),
        &cfg,
        &clk,
        sc.ctx(),
    );

    assert!(r1.number() == 1);
    assert!(r2.number() == 2);
    assert!(r3.number() == 3);
    assert!(r1.is_derived_from(edition_id));
    assert!(r2.is_derived_from(edition_id));
    assert!(r1.release_id() == release_id);

    // Three sales exhausted one shared cap of three, not two caps of three.
    assert!(edition.minted() == 3);
    assert!(edition.is_sold_out());
    assert!(sui_listing.sold() == 2);
    assert!(usdx_listing.sold() == 1);
    assert!(!sui_listing.is_live(&edition, &clk));
    assert!(!usdx_listing.is_live(&edition, &clk));

    // The sale that finished the cap sealed the run, so both listings are now anyone's
    // to clear up — and the run knows it is still carrying exactly two of them.
    assert!(edition.is_sealed());
    assert!(edition.outstanding_listings() == 2);

    sui_listing.close(&mut edition, &clk);
    assert!(edition.is_sealed()); // one still standing
    assert!(edition.outstanding_listings() == 1);

    usdx_listing.close(&mut edition, &clk);

    // Nothing of this run is left on chain but the run itself, which keeps the
    // denominator "of 3" and the claim markers that make the records verifiable.
    assert!(edition.is_closed());
    assert!(edition.outstanding_listings() == 0);
    assert!(r1.is_derived_from(edition_id));

    record::destroy(r1);
    record::destroy(r2);
    record::destroy(r3);
    ts::return_shared(edition);
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
    sc.end();
}

#[test]
#[expected_failure] // derived_object::claim aborts: a currency's slot is claim-once
fun an_edition_cannot_be_listed_twice_in_one_currency() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let mut e = edition::new_for_testing(
        rel.id(),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    listing::new<SUI>(
        &mut e,
        &cap,
        listing::new_fixed_price(10),
        listing::new_unbounded_window(0),
        &clk,
    );
    // The slot is on the edition, which outlives every listing — so this is refused
    // even after the first listing has been closed.
    listing::new<SUI>(
        &mut e,
        &cap,
        listing::new_fixed_price(20),
        listing::new_unbounded_window(0),
        &clk,
    );

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}
