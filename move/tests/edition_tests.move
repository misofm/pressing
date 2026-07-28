// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_drop::edition_tests;

use miso_drop::edition;
use miso_drop::test_utils::{a_release, authorized_settings, id, USDX};
use miso_record::record;
use miso_record::settings;
use std::type_name;
use sui::sui::SUI;

/// Mirrors of the module-private abort codes (constants aren't importable).
const EUnauthorized: u64 = 0; // miso_drop::edition
const EInvalidSupply: u64 = 1;
// `ESoldOut` (2) has no test: sealing-on-sell-out makes it unreachable.
const ENotListed: u64 = 3;
const EAlreadyClosed: u64 = 4;
const ENotAuthorized: u64 = 0; // miso_record::record

//=== Serials ===

#[test]
fun mint_next_advances_serials_and_derives_off_the_edition() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let release = id(@0xBEEF);
    let (cfg, admin) = authorized_settings(&mut ctx);

    // Edition 3 of some drop, uncapped.
    let mut e = edition::new_for_testing(
        release,
        id(@0xD0),
        3,
        edition::new_uncapped_supply(),
        &mut ctx,
    );
    let edition_id = e.id();

    let r1 = e.mint_next<SUI>(&cfg, 0, &ctx);
    let r2 = e.mint_next<SUI>(&cfg, 0, &ctx);

    // 1-based and sequential, stamped with the release and the edition number.
    assert!(r1.number() == 1);
    assert!(r2.number() == 2);
    assert!(r1.edition() == 3);
    assert!(r1.release_id() == release);
    assert!(e.minted() == 2);

    // Provenance is address math off the EDITION, not off a listing.
    assert!(r1.is_derived_from(edition_id));
    assert!(r2.is_derived_from(edition_id));
    assert!(!r1.is_derived_from(id(@0xD0)));

    record::destroy(r1);
    record::destroy(r2);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
}

#[test]
fun one_serial_sequence_is_shared_across_currencies() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_capped_supply(3),
        &mut ctx,
    );

    // This is the whole point of putting supply on the edition: paying in a different
    // currency gets you the same run, and #2 is #2 either way.
    let r1 = e.mint_next<SUI>(&cfg, 100, &ctx);
    let r2 = e.mint_next<USDX>(&cfg, 200, &ctx);
    let r3 = e.mint_next<SUI>(&cfg, 100, &ctx);

    assert!(r1.number() == 1);
    assert!(r2.number() == 2);
    assert!(r3.number() == 3);
    assert!(r1.purchase_currency() == type_name::with_defining_ids<SUI>());
    assert!(r2.purchase_currency() == type_name::with_defining_ids<USDX>());
    assert!(r2.purchase_price() == 200);

    // …and they draw down one shared cap.
    assert!(e.minted() == 3);
    assert!(e.is_sold_out());

    record::destroy(r1);
    record::destroy(r2);
    record::destroy(r3);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
}

//=== Supply ===

#[test]
fun capped_supply_counts_down_and_sells_out() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_capped_supply(2),
        &mut ctx,
    );

    assert!(e.max_supply().borrow() == 2);
    assert!(e.remaining().borrow() == 2);
    assert!(!e.is_sold_out());

    let r1 = e.mint_next<SUI>(&cfg, 0, &ctx);
    assert!(e.remaining().borrow() == 1);
    assert!(!e.is_sold_out());

    let r2 = e.mint_next<SUI>(&cfg, 0, &ctx);
    assert!(e.remaining().borrow() == 0);
    assert!(e.is_sold_out());

    record::destroy(r1);
    record::destroy(r2);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
}

#[test]
fun uncapped_supply_never_sells_out() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    assert!(e.max_supply().is_none());
    assert!(e.remaining().is_none());

    let r = e.mint_next<SUI>(&cfg, 0, &ctx);
    assert!(!e.is_sold_out());

    record::destroy(r);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
}

#[test]
#[expected_failure(abort_code = ENotListed, location = miso_drop::edition)]
fun mint_next_aborts_once_the_run_has_sold_itself_out() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_capped_supply(1),
        &mut ctx,
    );

    // The first mint exhausts the cap and seals the run, so the second is turned away by
    // the state, not by the cap — `ESoldOut` never gets a chance to fire.
    let r1 = e.mint_next<SUI>(&cfg, 0, &ctx);
    let r2 = e.mint_next<SUI>(&cfg, 0, &ctx); // one past the cap

    record::destroy(r1);
    record::destroy(r2);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
}

#[test]
#[expected_failure(abort_code = EInvalidSupply, location = miso_drop::edition)]
fun a_capped_run_of_zero_aborts_at_construction() {
    edition::new_capped_supply(0);
}

//=== Sealing ===

#[test]
fun sealing_a_run_with_nothing_standing_closes_it_outright() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);
    let mut e = edition::new_for_testing(
        rel.id(),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    assert!(e.is_listed());
    assert!(e.outstanding_listings() == 0);

    e.seal(&cap);

    // Nothing was listed, so there is nothing to wind down — it skips `Sealed` entirely.
    assert!(!e.is_listed());
    assert!(!e.is_sealed());
    assert!(e.is_closed());
    assert!(!e.is_sold_out()); // still uncapped — closed is not sold out

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

#[test]
fun a_run_walks_listed_to_sealed_to_closed_as_its_listings_come_down() {
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
    e.register_currency<USDX>();

    e.seal(&cap);

    // Sealed, not Closed: two listings are still standing in its name.
    assert!(e.is_sealed());
    assert!(!e.is_closed());
    assert!(e.outstanding_listings() == 2);

    e.unregister_currency<SUI>();
    assert!(e.is_sealed()); // one still out there
    assert!(e.outstanding_listings() == 1);
    assert!(!e.has_currency<SUI>());
    assert!(e.has_currency<USDX>());

    e.unregister_currency<USDX>();

    // The last one came down, so the run wound itself down with it.
    assert!(e.is_closed());
    assert!(e.outstanding_listings() == 0);
    assert!(e.currencies().is_empty());

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

#[test]
fun a_listing_coming_off_a_live_run_leaves_it_listed() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );
    e.register_currency<SUI>();
    e.register_currency<USDX>();

    // An expired or withdrawn listing can be cleared up without ending the run — it just
    // stops being one of the things the run is carrying.
    e.unregister_currency<SUI>();

    assert!(e.is_listed());
    assert!(!e.is_closed());
    assert!(e.outstanding_listings() == 1);

    // Down to nothing standing, and still selling — an artist can relist elsewhere.
    e.unregister_currency<USDX>();
    assert!(e.is_listed());
    assert!(e.outstanding_listings() == 0);

    e.destroy_for_testing();
}

#[test]
fun a_capped_run_seals_itself_on_its_last_record() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_capped_supply(2),
        &mut ctx,
    );
    e.register_currency<SUI>();

    let r1 = e.mint_next<SUI>(&cfg, 0, &ctx);
    assert!(e.is_listed());

    // The sale that exhausts the cap ends the run in the same transaction — cleanup
    // never waits on the artist noticing it sold out.
    let r2 = e.mint_next<SUI>(&cfg, 0, &ctx);
    assert!(e.is_sold_out());
    assert!(e.is_sealed());
    assert!(e.outstanding_listings() == 1);

    record::destroy(r1);
    record::destroy(r2);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
}

#[test]
#[expected_failure(abort_code = EAlreadyClosed, location = miso_drop::edition)]
fun nothing_can_come_off_a_closed_run() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);
    let mut e = edition::new_for_testing(
        rel.id(),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    e.seal(&cap); // nothing standing → straight to Closed
    e.unregister_currency<SUI>();

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

#[test]
#[expected_failure(abort_code = ENotListed, location = miso_drop::edition)]
fun a_sealed_run_takes_no_new_currency() {
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
    e.seal(&cap); // Sealed, carrying SUI

    // Sealed is a one-way street: it takes listings down, never on.
    e.register_currency<USDX>();

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

#[test]
#[expected_failure(abort_code = ENotListed, location = miso_drop::edition)]
fun a_sealed_run_mints_no_more_records() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (cfg, admin) = authorized_settings(&mut ctx);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );
    e.seal_for_testing();

    let r = e.mint_next<SUI>(&cfg, 0, &ctx);

    record::destroy(r);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
}

#[test]
#[expected_failure(abort_code = ENotListed, location = miso_drop::edition)]
fun sealing_twice_aborts() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);
    let mut e = edition::new_for_testing(
        rel.id(),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    e.seal(&cap);
    e.seal(&cap); // irreversible, and not idempotent

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

#[test]
#[expected_failure(abort_code = EUnauthorized, location = miso_drop::edition)]
fun seal_aborts_with_a_cap_for_another_release() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);

    // The edition belongs to a different release than the one this cap controls.
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );
    e.seal(&cap);

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

//=== Currencies ===

#[test]
fun currencies_is_what_is_standing_right_now() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    assert!(e.currencies().is_empty());
    assert!(!e.has_currency<SUI>());

    e.register_currency<SUI>();
    e.register_currency<USDX>();

    assert!(e.has_currency<SUI>());
    assert!(e.has_currency<USDX>());
    assert!(e.currencies().length() == 2);

    e.destroy_for_testing();
}

#[test]
#[expected_failure] // vec_set::insert aborts on a duplicate key
fun a_currency_cannot_be_registered_twice() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    e.register_currency<SUI>();
    e.register_currency<SUI>();

    e.destroy_for_testing();
}

//=== Mint authority ===

#[test]
#[expected_failure(abort_code = ENotAuthorized, location = miso_record::record)]
fun mint_next_aborts_when_the_witness_is_not_authorized() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    // Settings that does NOT authorize this package's MintWitness.
    let (cfg, admin) = settings::new_for_testing(&mut ctx);
    let mut e = edition::new_for_testing(
        id(@0xBEEF),
        id(@0xD0),
        0,
        edition::new_uncapped_supply(),
        &mut ctx,
    );

    let r = e.mint_next<SUI>(&cfg, 0, &ctx);

    record::destroy(r);
    e.destroy_for_testing();
    settings::destroy_for_testing(cfg, admin);
}
