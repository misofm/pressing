// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_pressing::listing_tests;

use miso_pressing::certificate;
use miso_pressing::listing::{Self, Listing};
use miso_pressing::pressing::{Self, Pressing, PressingAdminCap};
use miso_pressing::test_utils::{a_release, authorized_settings, id, USDX};
use miso_record::record;
use miso_record::settings;
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

/// A pressing on a fresh UID, its cap, and a matching listing against it.
fun a_listing<Currency>(
    price: listing::Price,
    state: listing::ListingState,
    ctx: &mut TxContext,
): (Pressing, PressingAdminCap, Listing<Currency>) {
    a_listing_for<Currency>(id(@0xBEEF), price, state, ctx)
}

/// The same, bound to a given release id.
fun a_listing_for<Currency>(
    release_id: ID,
    price: listing::Price,
    state: listing::ListingState,
    ctx: &mut TxContext,
): (Pressing, PressingAdminCap, Listing<Currency>) {
    let (p, admin) = pressing::new_for_testing(release_id, ctx);
    let l = listing::new_for_testing<Currency>(release_id, p.id(), price, state, ctx);
    (p, admin, l)
}

//=== buy ===

#[test]
fun buy_presses_the_record_and_certifies_what_was_paid() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Floor of 5; the buyer pays 8 — a 3-over tip, kept, not refunded.
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_floor_price(5),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let pressing_id = p.id();

    let r = l.buy(&mut p, coin::mint_for_testing<SUI>(8, &mut ctx), &cfg, &clk, &ctx);

    // One certificate carries both halves: where in the run, and on what terms.
    let c = certificate::of(&r).destroy_some();
    assert_eq!(c.number(), 1);
    assert_eq!(c.purchase_price(), 8); // the full 8, tip included
    assert_eq!(c.purchase_currency(), std::type_name::with_defining_ids<SUI>());
    assert!(c.is_for(&r));
    assert_eq!(record::derive_id(pressing_id, 1), r.id());
    assert_eq!(p.supply(), 1);

    destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EInsufficientPayment)]
fun buy_aborts_on_underpayment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );

    let r = l.buy(&mut p, coin::mint_for_testing<SUI>(9, &mut ctx), &cfg, &clk, &ctx);

    destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EInsufficientPayment)]
fun a_fixed_price_rejects_overpayment_too() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // Fixed means exactly — a tip needs a Floor price.
    let r = l.buy(&mut p, coin::mint_for_testing<SUI>(11, &mut ctx), &cfg, &clk, &ctx);

    destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EWrongPressing)]
fun buy_aborts_with_a_pressing_this_listing_does_not_sell_from() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // A different pressing entirely — it must not be possible to draw its numbers down.
    let (mut other, other_admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);
    let r = l.buy(&mut other, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);

    destroy(r);
    other.destroy_for_testing(other_admin);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

//=== Two switches ===

#[test, expected_failure(abort_code = listing::EListingDisabled)]
fun a_disabled_listing_takes_no_payment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_disabled_state(),
        &mut ctx,
    );

    let r = l.buy(&mut p, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);

    destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = pressing::EPressingPaused)]
fun a_paused_pressing_beats_an_enabled_listing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // The run-wide switch wins: the listing is open, the pressing is not.
    p.set_state(&admin, pressing::new_paused_state());
    assert!(!l.is_live(&p, &clk));
    let r = l.buy(&mut p, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);

    destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = pressing::ENotStarted)]
fun an_enabled_listing_sells_nothing_before_the_drop_moment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(50);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // The drop is scheduled run-wide, so listing a currency early does not open it.
    p.set_state(&admin, pressing::new_scheduled_state(100));
    assert!(!l.is_live(&p, &clk));
    let r = l.buy(&mut p, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);

    destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test]
fun the_drop_moment_opens_every_currency_at_once() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(150);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);
    let mut sui_l = listing::new_for_testing<SUI>(
        id(@0xBEEF),
        p.id(),
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let usdx_l = listing::new_for_testing<USDX>(
        id(@0xBEEF),
        p.id(),
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // One schedule on the run, not one per rail — a drop moment is a fact about the
    // release going on sale, and both currencies open on it together.
    p.set_state(&admin, pressing::new_scheduled_state(100));
    assert!(sui_l.is_live(&p, &clk));
    assert!(usdx_l.is_live(&p, &clk));

    let r = sui_l.buy(&mut p, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);
    assert_eq!(certificate::of(&r).destroy_some().number(), 1);

    // The first buy settled the run for everyone — the other rail sees `Active`, not a
    // schedule it has to re-evaluate.
    assert!(p.is_active());
    assert!(usdx_l.is_live(&p, &clk));

    destroy(r);
    sui_l.destroy_for_testing();
    usdx_l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test]
fun set_state_flips_one_currency_without_touching_the_others() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );

    assert!(l.is_live(&p, &clk));

    l.set_state(&admin, listing::new_disabled_state());
    assert!(l.is_disabled_for_testing());
    assert!(!l.is_live(&p, &clk));
    // The run itself is untouched — only this currency closed.
    assert!(p.is_active());

    l.set_state(&admin, listing::new_enabled_state());
    assert!(l.is_enabled_for_testing());
    let r = l.buy(&mut p, coin::zero<SUI>(&mut ctx), &cfg, &clk, &ctx);
    assert_eq!(certificate::of(&r).destroy_some().number(), 1);

    destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EUnauthorized)]
fun set_state_aborts_with_a_cap_for_another_pressing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);

    l.set_state(&foreign, listing::new_disabled_state());

    destroy(foreign);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
}

//=== Repricing in place ===

#[test]
fun set_price_reprices_the_standing_listing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let listing_id = l.id();

    let r1 = l.buy(&mut p, coin::mint_for_testing<SUI>(10, &mut ctx), &cfg, &clk, &ctx);

    l.set_price(&admin, listing::new_fixed_price(20));
    assert_eq!(l.price().amount(), 20);
    let r2 = l.buy(&mut p, coin::mint_for_testing<SUI>(20, &mut ctx), &cfg, &clk, &ctx);

    // Same listing through the change; each record certifies what IT paid.
    assert_eq!(l.id(), listing_id);
    assert_eq!(certificate::of(&r1).destroy_some().purchase_price(), 10);
    assert_eq!(certificate::of(&r2).destroy_some().purchase_price(), 20);
    assert_eq!(p.supply(), 2);

    destroy(r1);
    destroy(r2);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EInsufficientPayment)]
fun a_stale_payment_aborts_against_a_new_price() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, settings_admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // The artist reprices while a payment for the old fixed price is in flight —
    // Fixed means exactly, so the stale coin is refused, never overcharged.
    l.set_price(&admin, listing::new_fixed_price(20));
    let r = l.buy(&mut p, coin::mint_for_testing<SUI>(10, &mut ctx), &cfg, &clk, &ctx);

    destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EUnauthorized)]
fun set_price_aborts_with_a_cap_for_another_pressing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);

    l.set_price(&foreign, listing::new_fixed_price(1));

    destroy(foreign);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
}

//=== One listing per currency, ever ===

#[test]
fun has_listing_reads_the_derived_slot_with_no_stored_currency_set() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    assert!(!listing::has_listing<SUI>(&p));
    listing::new<SUI>(&mut p, &admin, listing::new_fixed_price(10), listing::new_enabled_state());

    // The pressing keeps no set of currencies — existence IS the derived slot, and the
    // phantom-typed key keeps one currency's slot from answering for another's.
    assert!(listing::has_listing<SUI>(&p));
    assert!(!listing::has_listing<USDX>(&p));

    p.destroy_for_testing(admin);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
fun listing_new_aborts_with_a_cap_for_another_pressing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);

    listing::new<SUI>(&mut p, &foreign, listing::new_fixed_price(10), listing::new_enabled_state());

    destroy(foreign);
    p.destroy_for_testing(admin);
}

#[test, expected_failure] // derived_object::claim aborts: ListingKey<SUI>() is claim-once
fun a_pressing_cannot_be_listed_twice_in_one_currency() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    listing::new<SUI>(&mut p, &admin, listing::new_fixed_price(10), listing::new_enabled_state());
    // The slot is permanent — repricing or disabling the standing listing is the way,
    // never a second one. The phantom-typed key makes the claim itself the check.
    listing::new<SUI>(&mut p, &admin, listing::new_fixed_price(20), listing::new_enabled_state());

    p.destroy_for_testing(admin);
}

//=== The whole chain, end to end ===

#[test]
fun one_pressing_sells_in_two_currencies_off_one_number_sequence() {
    let mut sc = ts::begin(@0xA);
    let (cfg, settings_admin) = authorized_settings(sc.ctx());
    let clk = clock::create_for_testing(sc.ctx());
    let (mut rel, cap) = a_release(sc.ctx());
    let release_id = rel.id();

    // Open the pressing and list it in two currencies — all in one transaction,
    // because `new` hands the pressing back unshared. The release cap is used once,
    // here, and never again; the pressing cap governs everything after.
    let (mut p, admin) = pressing::new(&mut rel, &cap, pressing::new_active_state());
    let pressing_id = p.id();
    listing::new<SUI>(&mut p, &admin, listing::new_fixed_price(10), listing::new_enabled_state());
    listing::new<USDX>(&mut p, &admin, listing::new_fixed_price(25), listing::new_enabled_state());
    assert!(listing::has_listing<SUI>(&p) && listing::has_listing<USDX>(&p));
    p.share();

    sc.next_tx(@0xA);
    let mut p = sc.take_shared<Pressing>();
    let mut sui_listing = sc.take_shared<Listing<SUI>>();
    let mut usdx_listing = sc.take_shared<Listing<USDX>>();

    // Both listings sit exactly where the currency type says they should — every
    // address in the tree is pure math off the release id.
    assert_eq!(sui_listing.id(), listing::derive_id<SUI>(pressing_id));
    assert_eq!(usdx_listing.id(), listing::derive_id<USDX>(pressing_id));
    assert!(listing::derive_id<SUI>(pressing_id) != listing::derive_id<USDX>(pressing_id));
    assert_eq!(sui_listing.price().amount(), 10);
    assert_eq!(usdx_listing.price().amount(), 25);

    // One run, two payment rails: the numbers interleave.
    let r1 = sui_listing.buy(&mut p, coin::mint_for_testing<SUI>(10, sc.ctx()), &cfg, &clk, sc.ctx());
    let r2 = usdx_listing.buy(
        &mut p,
        coin::mint_for_testing<USDX>(25, sc.ctx()),
        &cfg,
        &clk,
        sc.ctx(),
    );
    let r3 = sui_listing.buy(&mut p, coin::mint_for_testing<SUI>(10, sc.ctx()), &cfg, &clk, sc.ctx());

    assert_eq!(certificate::of(&r1).destroy_some().number(), 1);
    assert_eq!(certificate::of(&r2).destroy_some().number(), 2);
    assert_eq!(certificate::of(&r3).destroy_some().number(), 3);
    assert_eq!(record::derive_id(pressing_id, 2), r2.id());
    assert_eq!(r1.release_id(), release_id);

    // Each record's certificate names the rail it actually came through.
    assert_eq!(
        certificate::of(&r1).destroy_some().purchase_currency(),
        std::type_name::with_defining_ids<SUI>(),
    );
    assert_eq!(
        certificate::of(&r2).destroy_some().purchase_currency(),
        std::type_name::with_defining_ids<USDX>(),
    );

    // Every one of them verifies from chain state alone.
    assert!(pressing::verify_record(&r1));
    assert!(pressing::verify_record(&r2));
    assert!(pressing::verify_record(&r3));
    assert_eq!(p.supply(), 3);

    // The artist stops selling. One call to the pressing closes every rail at once —
    // nothing comes down, and the listings keep their addresses and their terms.
    p.set_state(&admin, pressing::new_paused_state());
    assert!(!sui_listing.is_live(&p, &clk));
    assert!(!usdx_listing.is_live(&p, &clk));
    assert!(listing::has_listing<SUI>(&p) && listing::has_listing<USDX>(&p));
    assert_eq!(record::derive_id(pressing_id, 1), r1.id()); // sold records stay verifiable forever

    destroy(r1);
    destroy(r2);
    destroy(r3);
    ts::return_shared(p);
    ts::return_shared(sui_listing);
    ts::return_shared(usdx_listing);
    destroy(rel);
    destroy(cap);
    destroy(admin);
    settings::destroy_for_testing(cfg, settings_admin);
    clk.destroy_for_testing();
    sc.end();
}
