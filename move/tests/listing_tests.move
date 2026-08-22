// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_pressing::listing_tests;

use miso::release::{Self, Release};
use miso_pressing::certificate::{Self, Certificate};
use miso_pressing::listing::{Self, Listing};
use miso_pressing::pressing::{Self, Pressing, PressingAdminCap};
use miso_pressing::test_utils::{a_release, id, USDX};
use miso_record::record::{Self, Record};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock::{Self, Clock};
use sui::event;
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
    let l = listing::new_for_testing<Currency>(release_id, object::id(&p), price, state, ctx);
    (p, admin, l)
}

//=== buy ===

#[test]
fun buy_presses_the_record_and_certifies_what_was_paid() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);

    // Floor of 5; the buyer pays 8 — a 3-over tip, kept, not refunded.
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_floor_price(5),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let pressing_id = object::id(&p);
    assert_eq!(l.release_id(), id(@0xBEEF));
    assert_eq!(l.pressing_id(), pressing_id);
    assert_eq!(l.state(), listing::new_enabled_state());
    assert_eq!(l.price().amount(), 5);

    let r = l.buy(&mut p, balance::create_for_testing<SUI>(8), &clk, &ctx);

    // One certificate carries both halves: where in the run, and on what terms.
    let c = r.certificate();
    assert_eq!(c.parent_id(), pressing_id);
    assert_eq!(c.number(), 1);
    assert_eq!(c.purchase_price(), 8); // the full 8, tip included
    assert_eq!(c.purchase_currency(), std::type_name::with_defining_ids<SUI>());
    assert_eq!(c.created_at_ms(), 0);
    assert_eq!(record::derive_address(pressing_id, 1).to_id(), object::id(&r));
    assert_eq!(p.supply(), 1);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test]
fun sale_event_captures_the_accepted_offer_and_result() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let release_id = id(@0xBEEF);
    let (mut p, admin, mut l) = a_listing_for<SUI>(
        release_id,
        listing::new_floor_price(5),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let pressing_id = object::id(&p);
    let listing_id = object::id(&l);

    let record = l.buy(&mut p, balance::create_for_testing<SUI>(8), &clk, &ctx);

    let sold = event::events_by_type<listing::RecordSoldEvent<SUI>>();
    assert_eq!(sold.length(), 1);
    let (
        sold_listing_id,
        sold_pressing_id,
        sold_release_id,
        sold_record_id,
        number,
        price,
        paid,
        buyer,
    ) = listing::sold_event_fields(&sold[0]);
    assert_eq!(sold_listing_id, listing_id);
    assert_eq!(sold_pressing_id, pressing_id);
    assert_eq!(sold_release_id, release_id);
    assert_eq!(sold_record_id, object::id(&record));
    assert_eq!(number, 1);
    assert_eq!(price, listing::new_floor_price(5));
    assert_eq!(paid, 8);
    assert_eq!(buyer, @0xA);

    record::destroy(record);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EInsufficientPayment, location = listing)]
fun buy_aborts_on_underpayment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );

    let r = l.buy(&mut p, balance::create_for_testing<SUI>(9), &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EInsufficientPayment, location = listing)]
fun a_fixed_price_rejects_overpayment_too() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // Fixed means exactly — a tip needs a Floor price.
    let r = l.buy(&mut p, balance::create_for_testing<SUI>(11), &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EWrongPressing, location = listing)]
fun buy_aborts_with_a_pressing_this_listing_does_not_sell_from() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // A different pressing entirely — it must not be possible to draw its numbers down.
    let (mut other, other_admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);
    assert!(!l.is_live(&other, &clk));
    let r = l.buy(&mut other, balance::zero<SUI>(), &clk, &ctx);

    record::destroy(r);
    other.destroy_for_testing(other_admin);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EInsufficientPayment, location = listing)]
fun a_floor_price_rejects_underpayment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_floor_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );

    let r = l.buy(&mut p, balance::create_for_testing<SUI>(9), &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

//=== Two switches ===

#[test, expected_failure(abort_code = listing::EListingDisabled, location = listing)]
fun a_disabled_listing_takes_no_payment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_disabled_state(),
        &mut ctx,
    );

    let r = l.buy(&mut p, balance::zero<SUI>(), &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = pressing::EPressingPaused, location = pressing)]
fun a_paused_pressing_beats_an_enabled_listing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // The run-wide switch wins: the listing is open, the pressing is not.
    p.set_state(&admin, pressing::new_paused_state());
    assert!(!l.is_live(&p, &clk));
    let r = l.buy(&mut p, balance::zero<SUI>(), &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = pressing::ENotStarted, location = pressing)]
fun an_enabled_listing_sells_nothing_before_the_drop_moment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
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
    let r = l.buy(&mut p, balance::zero<SUI>(), &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test]
fun the_drop_moment_opens_every_currency_at_once() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut clk = clock::create_for_testing(&mut ctx);
    clk.set_for_testing(150);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);
    let mut sui_l = listing::new_for_testing<SUI>(
        id(@0xBEEF),
        object::id(&p),
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let usdx_l = listing::new_for_testing<USDX>(
        id(@0xBEEF),
        object::id(&p),
        listing::new_fixed_price(0),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // One schedule on the run, not one per rail — a drop moment is a fact about the
    // release going on sale, and both currencies open on it together.
    p.set_state(&admin, pressing::new_scheduled_state(100));
    assert!(sui_l.is_live(&p, &clk));
    assert!(usdx_l.is_live(&p, &clk));

    let r = sui_l.buy(&mut p, balance::zero<SUI>(), &clk, &ctx);
    assert_eq!(r.certificate().number(), 1);

    // The first buy settled the run for everyone — the other rail sees `Active`, not a
    // schedule it has to re-evaluate.
    assert!(p.is_active());
    assert!(usdx_l.is_live(&p, &clk));

    record::destroy(r);
    sui_l.destroy_for_testing();
    usdx_l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test]
fun set_state_flips_one_currency_without_touching_the_others() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
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
    let r = l.buy(&mut p, balance::zero<SUI>(), &clk, &ctx);
    assert_eq!(r.certificate().number(), 1);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EUnauthorized, location = listing)]
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
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );
    let listing_id = object::id(&l);

    let r1 = l.buy(&mut p, balance::create_for_testing<SUI>(10), &clk, &ctx);

    l.set_price(&admin, listing::new_fixed_price(20));
    assert_eq!(l.price().amount(), 20);
    let r2 = l.buy(&mut p, balance::create_for_testing<SUI>(20), &clk, &ctx);

    // Same listing through the change; each record certifies what IT paid.
    assert_eq!(object::id(&l), listing_id);
    assert_eq!(r1.certificate().purchase_price(), 10);
    assert_eq!(r2.certificate().purchase_price(), 20);
    assert_eq!(p.supply(), 2);

    record::destroy(r1);
    record::destroy(r2);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EInsufficientPayment, location = listing)]
fun a_stale_payment_aborts_against_a_new_price() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock::create_for_testing(&mut ctx);
    let (mut p, admin, mut l) = a_listing<SUI>(
        listing::new_fixed_price(10),
        listing::new_enabled_state(),
        &mut ctx,
    );

    // The artist reprices while a payment for the old fixed price is in flight —
    // Fixed means exactly, so the stale payment is refused, never overcharged.
    l.set_price(&admin, listing::new_fixed_price(20));
    let r = l.buy(&mut p, balance::create_for_testing<SUI>(10), &clk, &ctx);

    record::destroy(r);
    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = listing::EUnauthorized, location = listing)]
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
fun listing_events_capture_the_initial_offer_and_each_edit() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release_id = id(@0xBEEF);
    let (mut p, admin) = pressing::new_for_testing(release_id, &mut ctx);
    let pressing_id = object::id(&p);
    let initial_price = listing::new_fixed_price(10);
    let initial_state = listing::new_enabled_state();

    listing::new<SUI>(&mut p, &admin, initial_price, initial_state);

    let opened = event::events_by_type<listing::ListingOpenedEvent<SUI>>();
    assert_eq!(opened.length(), 1);
    let (listing_id, opened_pressing_id, opened_release_id, opened_price, opened_state) =
        listing::opened_event_fields(&opened[0]);
    assert_eq!(listing_id, listing::derive_id<SUI>(pressing_id));
    assert_eq!(opened_pressing_id, pressing_id);
    assert_eq!(opened_release_id, release_id);
    assert_eq!(opened_price, initial_price);
    assert_eq!(opened_state, initial_state);

    let mut listing = listing::new_for_testing<SUI>(
        release_id,
        pressing_id,
        initial_price,
        initial_state,
        &mut ctx,
    );
    let editable_listing_id = object::id(&listing);
    let disabled = listing::new_disabled_state();
    let new_price = listing::new_floor_price(7);
    listing.set_state(&admin, disabled);
    listing.set_price(&admin, new_price);

    let state_changed = event::events_by_type<listing::ListingStateChangedEvent<SUI>>();
    assert_eq!(state_changed.length(), 1);
    let (state_listing_id, state_pressing_id, state) =
        listing::state_changed_event_fields(&state_changed[0]);
    assert_eq!(state_listing_id, editable_listing_id);
    assert_eq!(state_pressing_id, pressing_id);
    assert_eq!(state, disabled);

    let price_changed = event::events_by_type<listing::ListingPriceChangedEvent<SUI>>();
    assert_eq!(price_changed.length(), 1);
    let (price_listing_id, price_pressing_id, price) =
        listing::price_changed_event_fields(&price_changed[0]);
    assert_eq!(price_listing_id, editable_listing_id);
    assert_eq!(price_pressing_id, pressing_id);
    assert_eq!(price, new_price);

    listing.destroy_for_testing();
    p.destroy_for_testing(admin);
}

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

#[test, expected_failure(abort_code = pressing::EUnauthorized, location = pressing)]
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
    let clk = clock::create_for_testing(sc.ctx());
    let (mut rel, cap) = a_release(sc.ctx());
    let release_id = object::id(&rel);

    // Open the pressing and list it in two currencies — all in one transaction,
    // because `new` hands the pressing back unshared. The release cap is used once,
    // here, and never again; the pressing cap governs everything after.
    let (mut p, admin) = pressing::new(&mut rel, &cap, pressing::new_active_state());
    let pressing_id = object::id(&p);
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
    assert_eq!(object::id(&sui_listing), listing::derive_id<SUI>(pressing_id));
    assert_eq!(object::id(&usdx_listing), listing::derive_id<USDX>(pressing_id));
    assert!(listing::derive_id<SUI>(pressing_id) != listing::derive_id<USDX>(pressing_id));
    assert_eq!(sui_listing.price().amount(), 10);
    assert_eq!(usdx_listing.price().amount(), 25);

    // One run, two payment rails: the numbers interleave.
    let r1 = sui_listing.buy(&mut p, balance::create_for_testing<SUI>(10), &clk, sc.ctx());
    let r2 = usdx_listing.buy(&mut p, balance::create_for_testing<USDX>(25), &clk, sc.ctx());
    let r3 = sui_listing.buy(&mut p, balance::create_for_testing<SUI>(10), &clk, sc.ctx());

    assert_eq!(r1.certificate().number(), 1);
    assert_eq!(r2.certificate().number(), 2);
    assert_eq!(r3.certificate().number(), 3);
    assert_eq!(record::derive_address(pressing_id, 2).to_id(), object::id(&r2));
    assert_eq!(r1.release_id(), release_id);

    // Each record's certificate names the rail it actually came through.
    assert_eq!(
        r1.certificate().purchase_currency(),
        std::type_name::with_defining_ids<SUI>(),
    );
    assert_eq!(
        r2.certificate().purchase_currency(),
        std::type_name::with_defining_ids<USDX>(),
    );

    assert_eq!(r1.certificate().parent_id(), pressing_id);
    assert_eq!(r2.certificate().parent_id(), pressing_id);
    assert_eq!(r3.certificate().parent_id(), pressing_id);
    assert_eq!(p.supply(), 3);

    // The artist stops selling. One call to the pressing closes every rail at once —
    // nothing comes down, and the listings keep their addresses and their terms.
    p.set_state(&admin, pressing::new_paused_state());
    assert!(!sui_listing.is_live(&p, &clk));
    assert!(!usdx_listing.is_live(&p, &clk));
    assert!(listing::has_listing<SUI>(&p) && listing::has_listing<USDX>(&p));
    assert_eq!(record::derive_address(pressing_id, 1).to_id(), object::id(&r1));

    record::destroy(r1);
    record::destroy(r2);
    record::destroy(r3);
    ts::return_shared(p);
    ts::return_shared(sui_listing);
    ts::return_shared(usdx_listing);
    destroy(rel);
    destroy(cap);
    destroy(admin);
    clk.destroy_for_testing();
    sc.end();
}

#[test]
fun buyer_purchase_is_end_to_end_across_transactions() {
    let seller = @0xA11CE;
    let buyer = @0xB0B;
    let mut sc = ts::begin(seller);
    let mut clk = clock::create_for_testing(sc.ctx());
    clk.set_for_testing(1_726_000_123);
    let (mut rel, release_cap) = a_release(sc.ctx());
    let release_id = object::id(&rel);

    // Tx 1 (seller): establish the complete production path and put the shop on chain.
    let (mut p, admin) = pressing::new(&mut rel, &release_cap, pressing::new_active_state());
    let pressing_id = object::id(&p);
    listing::new<SUI>(
        &mut p,
        &admin,
        listing::new_floor_price(5),
        listing::new_enabled_state(),
    );
    let listing_id = listing::derive_id<SUI>(pressing_id);
    p.share();
    rel.publish(&release_cap, &clk);
    clk.share_for_testing();
    transfer::public_transfer(release_cap, seller);
    transfer::public_transfer(admin, seller);

    // Tx 2 (buyer): pay above the floor, receive the returned record, and explicitly
    // transfer it to the buyer. Both shared shop objects persist for later buyers.
    sc.next_tx(buyer);
    let mut p = sc.take_shared<Pressing>();
    let mut l = sc.take_shared<Listing<SUI>>();
    let clk = sc.take_shared<Clock>();
    let purchased = l.buy(
        &mut p,
        balance::create_for_testing<SUI>(8),
        &clk,
        sc.ctx(),
    );
    let record_id = object::id(&purchased);
    let cert = purchased.certificate();
    assert_eq!(p.supply(), 1);
    assert_eq!(record_id, record::derive_address(pressing_id, 1).to_id());
    assert_eq!(purchased.release_id(), release_id);
    assert_eq!(cert.parent_id(), pressing_id);
    assert_eq!(cert.number(), 1);
    assert_eq!(cert.purchase_currency(), std::type_name::with_defining_ids<SUI>());
    assert_eq!(cert.purchase_price(), 8);
    assert_eq!(cert.created_at_ms(), 1_726_000_123);

    let mut created = event::events_by_type<record::RecordCreatedEvent<Certificate>>();
    assert_eq!(created.length(), 1);
    let (created_record_id, created_parent_id, created_release_id, created_number) =
        record::record_created_event_fields(created.pop_back());
    assert_eq!(created_record_id, record_id);
    assert_eq!(created_parent_id, pressing_id);
    assert_eq!(created_release_id, release_id);
    assert_eq!(created_number, 1);

    let sold = event::events_by_type<listing::RecordSoldEvent<SUI>>();
    assert_eq!(sold.length(), 1);
    let (
        sold_listing_id,
        sold_pressing_id,
        sold_release_id,
        sold_record_id,
        number,
        price,
        paid,
        sold_to,
    ) = listing::sold_event_fields(&sold[0]);
    assert_eq!(sold_listing_id, listing_id);
    assert_eq!(sold_pressing_id, pressing_id);
    assert_eq!(sold_release_id, release_id);
    assert_eq!(sold_record_id, record_id);
    assert_eq!(number, 1);
    assert_eq!(price, listing::new_floor_price(5));
    assert_eq!(paid, 8);
    assert_eq!(sold_to, buyer);

    transfer::public_transfer(purchased, buyer);
    ts::return_shared(clk);
    ts::return_shared(p);
    ts::return_shared(l);

    // Tx 3 (buyer): taking the transferred object proves address ownership survived
    // the transaction boundary together with its embedded, non-copyable certificate.
    sc.next_tx(buyer);
    let purchased = sc.take_from_sender<Record<Certificate>>();
    assert_eq!(object::id(&purchased), record_id);
    assert_eq!(purchased.certificate().purchase_price(), 8);
    record::destroy(purchased);
    let mut destroyed = event::events_by_type<record::RecordDestroyedEvent<Certificate>>();
    assert_eq!(destroyed.length(), 1);
    let (destroyed_record_id, destroyed_release_id) =
        record::record_destroyed_event_fields(destroyed.pop_back());
    assert_eq!(destroyed_record_id, record_id);
    assert_eq!(destroyed_release_id, release_id);

    // Tx 4 (seller): the entire payment, including the tip, is redeemable from the
    // release's funds accumulator; the shared listing and pressing remain intact.
    sc.next_tx(seller);
    let admin = sc.take_from_sender<PressingAdminCap>();
    let release_cap = sc.take_from_sender<miso::release::ReleaseAdminCap>();
    let mut rel = sc.take_shared<Release>();
    let payout = balance::redeem_funds(
        balance::withdraw_funds_from_object<SUI>(rel.uid_mut(&release_cap), 8),
    );
    assert_eq!(payout.destroy_for_testing(), 8);
    let p = sc.take_shared<Pressing>();
    let l = sc.take_shared<Listing<SUI>>();
    assert_eq!(p.supply(), 1);
    assert_eq!(object::id(&l), listing_id);

    l.destroy_for_testing();
    p.destroy_for_testing(admin);
    destroy(rel);
    destroy(release_cap);
    let clk = sc.take_shared<Clock>();
    clk.destroy_for_testing();
    sc.end();
}
