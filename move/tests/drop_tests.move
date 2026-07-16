// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_drop::drop_tests;

use miso::release::{Self, Release, ReleaseAdminCap};
use miso_drop::drop::{Self, MintWitness};
use miso_record::record;
use miso_record::settings;
use std::type_name;
use sui::clock::{Self, Clock};
use sui::coin;
use sui::sui::SUI;

/// Mirrors of the module-private abort codes (constants aren't importable).
const ENotAuthorized: u64 = 0; // miso_record::record
const EReleaseUnauthorized: u64 = 0; // miso::release (uid_mut → authorize)
const EUnauthorized: u64 = 0; // miso_drop::drop
const EInsufficientPayment: u64 = 1;
const EDropNotStarted: u64 = 2;
const EDropClosed: u64 = 3;
const EInvalidWindow: u64 = 4;
const ESoldOut: u64 = 5;
const EInvalidSupply: u64 = 6;
const ENonSequentialEdition: u64 = 7;

/// A second currency, for testing a cross-currency `new_edition`.
public struct USDX has drop {}

fun id(addr: address): ID {
    object::id_from_address(addr)
}

/// A `Settings` with this drop's `MintWitness` authorized.
fun authorized_settings(ctx: &mut TxContext): (settings::Settings, settings::SettingsAdminCap) {
    let (mut cfg, admin) = settings::new_for_testing(ctx);
    settings::authorize<MintWitness>(&mut cfg, &admin);
    (cfg, admin)
}

fun clock_at(ms: u64, ctx: &mut TxContext): Clock {
    let mut c = clock::create_for_testing(ctx);
    c.set_for_testing(ms);
    c
}

fun a_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing(b"Test".to_string(), vector[], ctx)
}

//=== buy ===

#[test]
fun buy_mints_sequential_records_derived_off_the_drop() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx); // t = 0

    // Edition 3: uncapped, opens at 0, never closes, free.
    let mut d = drop::new_for_testing<SUI>(
        release, 3, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &mut ctx,
    );

    let r1 = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);
    let r2 = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);

    // 1-based, sequential; stamped with release, edition, and purchase terms.
    assert!(record::number(&r1) == 1);
    assert!(record::number(&r2) == 2);
    assert!(record::edition(&r1) == 3);
    assert!(record::release_id(&r1) == release);
    assert!(record::purchase_price(&r1) == 0);
    assert!(record::purchase_currency(&r1) == type_name::with_defining_ids<SUI>());
    assert!(drop::quantity_sold(&d) == 2);
    assert!(drop::is_live(&d, &clk));

    // Each record's UID is verifiably derived off this drop, not off some other object.
    assert!(record::is_derived_from(&r1, drop::id(&d)));
    assert!(!record::is_derived_from(&r1, id(@0xF00D)));

    record::destroy(r1);
    record::destroy(r2);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
fun buy_records_amount_paid() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Floor of 5; buyer pays 8 (a 3-over tip). purchase_price records the full 8.
    let mut d = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_floor_price(5), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &mut ctx,
    );
    let payment = coin::mint_for_testing<SUI>(8, &mut ctx);
    let r = drop::buy(&mut d, payment, &cfg, &clk, &mut ctx);

    assert!(record::purchase_price(&r) == 8);

    record::destroy(r);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
fun is_live_reflects_window() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    // Bounded window [100, 200], uncapped.
    let d = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_bounded_window(100, 200), &mut ctx,
    );
    let mut clk = clock::create_for_testing(&mut ctx);

    // The test clock only moves forward, so assert in ascending order.
    clk.set_for_testing(50);
    assert!(!drop::is_live(&d, &clk)); // before open
    clk.set_for_testing(150);
    assert!(drop::is_live(&d, &clk)); // inside
    clk.set_for_testing(250);
    assert!(!drop::is_live(&d, &clk)); // after close

    drop::destroy_for_testing(d);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ENotAuthorized, location = miso_record::record)]
fun buy_aborts_when_witness_not_authorized() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = settings::new_for_testing(&mut ctx); // never authorized MintWitness
    let clk = clock::create_for_testing(&mut ctx);

    let mut d = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &mut ctx,
    );
    let r = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);

    record::destroy(r);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EInsufficientPayment, location = miso_drop::drop)]
fun buy_aborts_on_underpayment() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    let mut d = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_fixed_price(100), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &mut ctx,
    );
    // Pay 0 against a fixed price of 100 — aborts before any funds move.
    let r = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);

    record::destroy(r);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EDropNotStarted, location = miso_drop::drop)]
fun buy_aborts_before_open() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock_at(0, &mut ctx);

    // Opens at 100; clock is at 0.
    let mut d = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(100), &mut ctx,
    );
    let r = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);

    record::destroy(r);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EDropClosed, location = miso_drop::drop)]
fun buy_aborts_after_close() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock_at(200, &mut ctx);

    // Closes at 100; clock is at 200.
    let mut d = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_bounded_window(0, 100), &mut ctx,
    );
    let r = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);

    record::destroy(r);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

//=== supply ===

#[test]
fun cap_sells_out() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Capped at 2, free.
    let mut d = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_fixed_price(0), drop::new_capped_supply(2),
        drop::new_unbounded_window(0), &mut ctx,
    );
    assert!(!drop::is_sold_out(&d));
    assert!(drop::max_supply(&d) == option::some(2));

    let r1 = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);
    assert!(!drop::is_sold_out(&d));
    let r2 = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);

    // Cap reached: sold out, and no longer live even inside its window.
    assert!(record::number(&r2) == 2);
    assert!(drop::is_sold_out(&d));
    assert!(!drop::is_live(&d, &clk));

    record::destroy(r1);
    record::destroy(r2);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ESoldOut, location = miso_drop::drop)]
fun buy_aborts_when_sold_out() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // Capped at 1: the second buy must abort.
    let mut d = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_fixed_price(0), drop::new_capped_supply(1),
        drop::new_unbounded_window(0), &mut ctx,
    );
    let r1 = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);
    let r2 = drop::buy(&mut d, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);

    record::destroy(r1);
    record::destroy(r2);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

//=== term constructors ===

#[test]
#[expected_failure(abort_code = EInvalidSupply, location = miso_drop::drop)]
fun zero_cap_aborts_at_construction() {
    // A cap of 0 could never sell anything.
    let _supply = drop::new_capped_supply(0);
}

#[test]
#[expected_failure(abort_code = EInvalidWindow, location = miso_drop::drop)]
fun empty_window_aborts_at_construction() {
    // Close (50) is not after open (100) — empty window.
    let _window = drop::new_bounded_window(100, 50);
}

#[test]
#[expected_failure(abort_code = EInvalidWindow, location = miso_drop::drop)]
fun elapsed_window_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);
    let clk = clock_at(200, &mut ctx);

    // Structurally valid window [0, 100], but the clock is already at 200 — the
    // temporal check in `new` rejects an already-closed drop.
    drop::new<SUI>(
        &mut rel, &cap, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_bounded_window(0, 100), &clk,
    );

    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}

//=== new / new_edition ===

#[test]
fun new_then_new_edition_supersedes() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // No drop yet.
    assert!(drop::current_drop_id(&rel).is_none());

    // Edition 0 (real path: claims DropKey(0) off the release and sets the pointer).
    drop::new<SUI>(
        &mut rel, &cap, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &clk,
    );
    let first = drop::current_drop_id(&rel);
    assert!(first.is_some());

    // A stand-in for the (shared, unreachable in a unit test) edition-0 drop: same
    // release, same edition. Sell one record from it, then supersede it.
    let mut old = drop::new_for_testing<SUI>(
        rel.id(), 0, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &mut ctx,
    );
    let old_id = drop::id(&old);
    let r = drop::buy(&mut old, coin::zero<SUI>(&mut ctx), &cfg, &clk, &mut ctx);
    assert!(record::is_derived_from(&r, old_id));

    // Edition 1: consumes the old drop, switches currency, caps the run.
    drop::new_edition<SUI, USDX>(
        &mut rel, old, &cap, drop::new_floor_price(10), drop::new_capped_supply(500),
        drop::new_unbounded_window(0), &clk,
    );

    // The release's pointer moved to the successor…
    let second = drop::current_drop_id(&rel);
    assert!(second.is_some());
    assert!(second.borrow() != first.borrow());

    // …and the record sold by the (now destroyed) predecessor is still verifiable.
    assert!(record::is_derived_from(&r, old_id));

    record::destroy(r);
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
fun new_edition_records_restart_serials() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // A successor edition mints "edition 1, #1" — serials restart per edition.
    let mut d = drop::new_for_testing<USDX>(
        id(@0xBEEF), 1, drop::new_fixed_price(0), drop::new_capped_supply(500),
        drop::new_unbounded_window(0), &mut ctx,
    );
    let r = drop::buy(&mut d, coin::zero<USDX>(&mut ctx), &cfg, &clk, &mut ctx);
    assert!(record::edition(&r) == 1);
    assert!(record::number(&r) == 1);
    assert!(record::purchase_currency(&r) == type_name::with_defining_ids<USDX>());

    record::destroy(r);
    drop::destroy_for_testing(d);
    settings::destroy_for_testing(cfg, admin);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EReleaseUnauthorized, location = miso::release)]
fun new_aborts_with_wrong_cap() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);
    let (rel2, cap2) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // cap2 authorizes rel2, not rel — the protocol's uid_mut rejects it.
    drop::new<SUI>(
        &mut rel, &cap2, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &clk,
    );

    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    std::unit_test::destroy(rel2);
    std::unit_test::destroy(cap2);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EUnauthorized, location = miso_drop::drop)]
fun new_edition_aborts_with_foreign_drop() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    // The old drop belongs to a DIFFERENT release than `rel` / its cap.
    let old = drop::new_for_testing<SUI>(
        id(@0xBEEF), 0, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &mut ctx,
    );
    drop::new_edition<SUI, SUI>(
        &mut rel, old, &cap, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &clk,
    );

    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = ENonSequentialEdition, location = miso_drop::drop)]
fun nonsequential_claim_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);

    // Edition 1 on a release that never claimed edition 0 — the claim-site guard
    // fires (unreachable through the public API; exercised via the test-only path).
    drop::share_drop_for_testing<SUI>(
        &mut rel, &cap, 1, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0),
    );

    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

#[test]
#[expected_failure] // derived_object::claim aborts: edition 0's key is claim-once
fun second_first_drop_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);
    let clk = clock::create_for_testing(&mut ctx);

    drop::new<SUI>(
        &mut rel, &cap, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &clk,
    );
    // A release's edition sequence can only ever start once.
    drop::new<SUI>(
        &mut rel, &cap, drop::new_fixed_price(0), drop::new_uncapped_supply(),
        drop::new_unbounded_window(0), &clk,
    );

    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    clk.destroy_for_testing();
}
