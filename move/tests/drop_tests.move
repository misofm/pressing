// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_drop::drop_tests;

use miso_drop::drop::{Self, Drop};
use miso_drop::edition;
use miso_drop::test_utils::{a_release, id};
use sui::test_scenario as ts;

/// Mirrors of the module-private abort codes (constants aren't importable).
const EUnauthorized: u64 = 0; // miso_drop::drop
const EReleaseUnauthorized: u64 = 0; // miso::release (uid_mut → authorize)

//=== The derivation chain ===

#[test]
fun new_derives_the_drop_off_the_release_and_edition_zero_off_the_drop() {
    let mut sc = ts::begin(@0xA);
    let (mut rel, cap) = a_release(sc.ctx());
    let release_id = rel.id();

    let e0 = drop::new(&mut rel, &cap, edition::new_uncapped_supply());

    // The first edition is number 0, and it knows where it came from.
    assert!(e0.number() == 0);
    assert!(e0.release_id() == release_id);
    assert!(e0.drop_id() == drop::derive_id(release_id));

    // Both addresses are pure math off the release id — no lookup needed.
    assert!(e0.id() == edition::derive_id(drop::derive_id(release_id), 0));
    e0.share();

    sc.next_tx(@0xA);
    let d = sc.take_shared<Drop>();
    assert!(d.id() == drop::derive_id(release_id));
    assert!(d.release_id() == release_id);
    assert!(d.editions() == 1);
    ts::return_shared(d);

    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    sc.end();
}

//=== The edition sequence ===

#[test]
fun editions_are_numbered_sequentially_with_no_gaps() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut d = drop::new_for_testing(id(@0xBEEF), &mut ctx);

    // The counter picks every number; a caller never gets to choose one.
    let e0 = d.open_edition_for_testing(edition::new_uncapped_supply());
    let e1 = d.open_edition_for_testing(edition::new_capped_supply(500));
    let e2 = d.open_edition_for_testing(edition::new_capped_supply(1));

    assert!(e0.number() == 0);
    assert!(e1.number() == 1);
    assert!(e2.number() == 2);
    assert!(d.editions() == 3);

    // Each sits at exactly the address its number derives to.
    let drop_id = d.id();
    assert!(e0.id() == edition::derive_id(drop_id, 0));
    assert!(e1.id() == edition::derive_id(drop_id, 1));
    assert!(e2.id() == edition::derive_id(drop_id, 2));

    e0.destroy_for_testing();
    e1.destroy_for_testing();
    e2.destroy_for_testing();
    d.destroy_for_testing();
}

#[test]
fun edition_id_views_track_the_counter() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut d = drop::new_for_testing(id(@0xBEEF), &mut ctx);

    // Nothing opened yet.
    assert!(d.latest_edition_id().is_none());
    assert!(d.edition_id(0).is_none());

    let e0 = d.open_edition_for_testing(edition::new_uncapped_supply());
    let e1 = d.open_edition_for_testing(edition::new_uncapped_supply());

    assert!(d.edition_id(0).borrow() == e0.id());
    assert!(d.edition_id(1).borrow() == e1.id());
    // Beyond the counter is not an address, it's a nonexistent edition.
    assert!(d.edition_id(2).is_none());
    assert!(d.latest_edition_id().borrow() == e1.id());

    e0.destroy_for_testing();
    e1.destroy_for_testing();
    d.destroy_for_testing();
}

#[test]
fun next_edition_does_not_close_the_previous_one() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let mut d = drop::new_for_testing(id(@0xBEEF), &mut ctx);

    let e0 = d.open_edition_for_testing(edition::new_capped_supply(100));
    let e1 = d.open_edition_for_testing(edition::new_capped_supply(100));

    // Both runs stay open — whether being early meant anything is the artist's call,
    // made with `edition::seal`, not a side effect of opening the next edition.
    assert!(e0.is_listed());
    assert!(e1.is_listed());

    e0.destroy_for_testing();
    e1.destroy_for_testing();
    d.destroy_for_testing();
}

//=== Authority ===

#[test]
#[expected_failure(abort_code = EReleaseUnauthorized, location = miso::release)]
fun new_aborts_with_a_cap_for_another_release() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);
    let (rel2, cap2) = a_release(&mut ctx);

    // cap2 authorizes rel2, not rel — the protocol's uid_mut rejects it.
    let e = drop::new(&mut rel, &cap2, edition::new_uncapped_supply());

    e.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
    std::unit_test::destroy(rel2);
    std::unit_test::destroy(cap2);
}

#[test]
#[expected_failure(abort_code = EUnauthorized, location = miso_drop::drop)]
fun next_edition_aborts_with_a_cap_for_another_release() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (rel, cap) = a_release(&mut ctx);

    // The drop belongs to a different release than the one this cap controls.
    let mut d = drop::new_for_testing(id(@0xBEEF), &mut ctx);
    let e = d.next_edition(&cap, edition::new_uncapped_supply());

    e.destroy_for_testing();
    d.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}

#[test]
#[expected_failure] // derived_object::claim aborts: DropKey() is claim-once
fun a_release_can_only_ever_open_one_drop() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);

    let e0 = drop::new(&mut rel, &cap, edition::new_uncapped_supply());
    // A second drop for the same release would be a second edition sequence.
    let e1 = drop::new(&mut rel, &cap, edition::new_uncapped_supply());

    e0.destroy_for_testing();
    e1.destroy_for_testing();
    std::unit_test::destroy(rel);
    std::unit_test::destroy(cap);
}
