// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_pressing::pressing_tests;

use miso::release;
use miso_pressing::certificate;
use miso_pressing::pressing::{Self, Pressing};
use miso_pressing::test_utils::{a_release, clock_at, id};
use miso_record::record;
use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::sui::SUI;
use sui::test_scenario as ts;

//=== The derivation chain ===

#[test]
fun new_derives_the_pressing_and_its_cap_off_the_release() {
    let mut sc = ts::begin(@0xA);
    let (mut rel, cap) = a_release(sc.ctx());
    let release_id = object::id(&rel);

    let (p, admin) = pressing::new(&mut rel, &cap, pressing::new_active_state());

    // Every address in the tree is pure math — the pressing off the release, the cap
    // off the pressing. No lookup, no registry.
    assert_eq!(object::id(&p), pressing::derive_id(release_id));
    assert_eq!(object::id(&admin), pressing::derive_admin_cap_id(object::id(&p)));
    assert_eq!(admin.pressing_id(), object::id(&p));
    assert_eq!(p.release_id(), release_id);
    assert_eq!(p.supply(), 0);
    assert_eq!(p.state(), pressing::new_active_state());
    assert!(p.is_active());
    p.share();

    sc.next_tx(@0xA);
    let p = sc.take_shared<Pressing>();
    assert_eq!(object::id(&p), pressing::derive_id(release_id));
    ts::return_shared(p);

    destroy(rel);
    destroy(cap);
    destroy(admin);
    sc.end();
}

#[test]
fun events_capture_opening_and_every_state_transition() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(100, &mut ctx);
    let (mut rel, cap) = a_release(&mut ctx);
    let release_id = object::id(&rel);
    let scheduled = pressing::new_scheduled_state(100);

    let (mut p, admin) = pressing::new(&mut rel, &cap, scheduled);
    let pressing_id = object::id(&p);

    let opened = event::events_by_type<pressing::PressingOpenedEvent>();
    assert_eq!(opened.length(), 1);
    let (opened_pressing_id, opened_release_id, opened_state) =
        pressing::opened_event_fields(&opened[0]);
    assert_eq!(opened_pressing_id, pressing_id);
    assert_eq!(opened_release_id, release_id);
    assert_eq!(opened_state, scheduled);

    // The first sale settles Scheduled to Active, then an explicit pause emits the
    // next transition. Event order is the state history an indexer will replay.
    let record = p.mint_next<SUI>(0, &clk);
    p.set_state(&admin, pressing::new_paused_state());

    let changed = event::events_by_type<pressing::PressingStateChangedEvent>();
    assert_eq!(changed.length(), 2);
    let (active_pressing_id, active_state) = pressing::state_changed_event_fields(&changed[0]);
    assert_eq!(active_pressing_id, pressing_id);
    assert_eq!(active_state, pressing::new_active_state());
    let (paused_pressing_id, paused_state) = pressing::state_changed_event_fields(&changed[1]);
    assert_eq!(paused_pressing_id, pressing_id);
    assert_eq!(paused_state, pressing::new_paused_state());

    record::destroy(record);
    p.destroy_for_testing(admin);
    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}

//=== The number sequence ===

#[test]
fun numbers_advance_gap_free_and_records_are_addressable() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(1_000, &mut ctx);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);
    let pressing_id = object::id(&p);

    // Nothing pressed yet — number 0 does not exist, and neither does 1.
    assert!(p.record_id(0).is_none());
    assert!(p.record_id(1).is_none());

    // The counter picks every number; a caller never gets to choose one.
    let r1 = p.mint_next<SUI>(10, &clk);
    let r2 = p.mint_next<SUI>(10, &clk);
    let r3 = p.mint_next<SUI>(10, &clk);

    // The number is the pressing's certificate on the record, not a field of it.
    let c1 = r1.certificate();
    assert_eq!(c1.number(), 1);
    assert_eq!(r2.certificate().number(), 2);
    assert_eq!(r3.certificate().number(), 3);
    assert_eq!(p.supply(), 3);
    assert_eq!(c1.created_at_ms(), 1_000);
    assert_eq!(r1.release_id(), id(@0xBEEF));

    // Each sits at exactly the address its number derives to — the certificate is the
    // readable form of what the address already proves.
    assert_eq!(*p.record_id(1).borrow(), object::id(&r1));
    assert_eq!(*p.record_id(3).borrow(), object::id(&r3));
    assert!(p.record_id(4).is_none());
    assert_eq!(record::derive_address(pressing_id, c1.number()).to_id(), object::id(&r1));
    assert!(record::derive_address(id(@0xD0), c1.number()).to_id() != object::id(&r1));

    record::destroy(r1);
    record::destroy(r2);
    record::destroy(r3);
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

//=== The certificate ===

#[test]
fun the_certificate_carries_the_number_and_the_terms_it_sold_on() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(1_000, &mut ctx);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    let r = p.mint_next<SUI>(42, &clk);
    let c = r.certificate();

    assert_eq!(c.parent_id(), object::id(&p));
    assert_eq!(c.number(), 1);
    assert_eq!(c.purchase_price(), 42);
    assert_eq!(c.purchase_currency(), std::type_name::with_defining_ids<SUI>());
    assert_eq!(c.created_at_ms(), 1_000);

    record::destroy(r);
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

//=== The run-wide switch: Scheduled → Active → Paused → Active ===

#[test, expected_failure(abort_code = pressing::ENotStarted, location = pressing)]
fun a_scheduled_run_presses_nothing_before_its_start() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(50, &mut ctx);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    p.set_state(&admin, pressing::new_scheduled_state(100)); // opens later
    let r = p.mint_next<SUI>(0, &clk);

    record::destroy(r);
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test]
fun a_scheduled_run_opens_itself_at_its_start() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(150, &mut ctx);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    p.set_state(&admin, pressing::new_scheduled_state(100));

    // Past the start the run already sells, before anyone has touched it — nobody has
    // to go first for the drop to be open.
    assert!(p.is_selling(&clk));
    assert!(p.is_scheduled());
    assert!(!p.is_active());
    assert_eq!(*p.start_timestamp_ms().borrow(), 100);

    // The first sale settles the state on its way through.
    let r = p.mint_next<SUI>(0, &clk);
    assert_eq!(r.certificate().number(), 1);
    assert!(p.is_active());
    assert!(!p.is_scheduled());
    assert!(p.start_timestamp_ms().is_none());

    record::destroy(r);
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test]
fun the_start_is_inclusive() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(100, &mut ctx);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    // Exactly on the moment, not a millisecond after.
    p.set_state(&admin, pressing::new_scheduled_state(100));
    assert!(p.is_selling(&clk));
    let r = p.mint_next<SUI>(0, &clk);
    assert!(p.is_active());

    record::destroy(r);
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = pressing::EPressingPaused, location = pressing)]
fun pausing_a_scheduled_run_outranks_a_moment_that_has_passed() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(150, &mut ctx);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    // Scheduled, then called off before anyone bought — the clock passing the start
    // must not resurrect it. Pausing is the artist's decision and it replaces the
    // schedule outright.
    p.set_state(&admin, pressing::new_scheduled_state(100));
    p.set_state(&admin, pressing::new_paused_state());
    assert!(!p.is_selling(&clk));
    let r = p.mint_next<SUI>(0, &clk);

    record::destroy(r);
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test]
fun a_run_walks_scheduled_then_active_then_paused_then_active() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(50, &mut ctx);
    let (mut rel, cap) = a_release(&mut ctx);

    // Opened for a drop moment an hour out: nobody can buy early.
    let (mut p, admin) = pressing::new(&mut rel, &cap, pressing::new_scheduled_state(100));
    assert!(p.is_scheduled());
    assert!(!p.is_selling(&clk));

    // The artist opens it by hand ahead of the moment — Scheduled is a floor, not a
    // commitment the artist is locked out of.
    p.set_state(&admin, pressing::new_active_state());
    assert!(p.is_selling(&clk));
    assert!(p.start_timestamp_ms().is_none());
    let r1 = p.mint_next<SUI>(0, &clk);

    // Stopped, and the sequence holds where it was.
    p.set_state(&admin, pressing::new_paused_state());
    assert!(p.is_paused());
    assert!(!p.is_selling(&clk));
    assert_eq!(p.supply(), 1);

    // Started again: the run picks up at 2, never at 1.
    p.set_state(&admin, pressing::new_active_state());
    let r2 = p.mint_next<SUI>(0, &clk);
    assert_eq!(r1.certificate().number(), 1);
    assert_eq!(r2.certificate().number(), 2);

    record::destroy(r1);
    record::destroy(r2);
    p.destroy_for_testing(admin);
    destroy(rel);
    destroy(cap);
    clk.destroy_for_testing();
}

#[test]
fun set_state_pauses_and_resumes_the_whole_run() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(1_000, &mut ctx);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    p.set_state(&admin, pressing::new_paused_state());
    assert!(p.is_paused());
    assert!(!p.is_active());

    // Resuming picks the sequence back up where it left off — nothing came down.
    p.set_state(&admin, pressing::new_active_state());
    assert!(p.is_active());
    let r = p.mint_next<SUI>(0, &clk);
    assert_eq!(r.certificate().number(), 1);

    record::destroy(r);
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

#[test, expected_failure(abort_code = pressing::EPressingPaused, location = pressing)]
fun a_paused_pressing_presses_nothing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let clk = clock_at(1_000, &mut ctx);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);

    p.set_state(&admin, pressing::new_paused_state());
    let r = p.mint_next<SUI>(0, &clk);

    record::destroy(r);
    p.destroy_for_testing(admin);
    clk.destroy_for_testing();
}

//=== Authority ===

#[test, expected_failure(abort_code = pressing::EUnauthorized, location = pressing)]
fun set_state_aborts_with_a_cap_for_another_pressing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);

    p.set_state(&foreign, pressing::new_paused_state());

    destroy(foreign);
    p.destroy_for_testing(admin);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized, location = pressing)]
fun authorize_aborts_with_a_cap_for_another_pressing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (p, admin) = pressing::new_for_testing(id(@0xBEEF), &mut ctx);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);

    p.authorize(&foreign);

    destroy(foreign);
    p.destroy_for_testing(admin);
}

#[test, expected_failure(abort_code = miso::release::EUnauthorized, location = release)]
fun new_aborts_with_a_cap_for_another_release() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);
    let (rel2, cap2) = a_release(&mut ctx);

    // cap2 authorizes rel2, not rel — the protocol's uid_mut rejects it.
    let (p, admin) = pressing::new(&mut rel, &cap2, pressing::new_active_state());

    p.destroy_for_testing(admin);
    destroy(rel);
    destroy(cap);
    destroy(rel2);
    destroy(cap2);
}

#[test, expected_failure] // derived_object::claim aborts: PressingKey() is claim-once
fun a_release_can_only_ever_open_one_pressing() {
    let mut ctx = tx_context::new_from_hint(@0xA, 0, 0, 0, 0);
    let (mut rel, cap) = a_release(&mut ctx);

    let (p0, a0) = pressing::new(&mut rel, &cap, pressing::new_active_state());
    // A second pressing for the same release would be a second number sequence.
    let (p1, a1) = pressing::new(&mut rel, &cap, pressing::new_active_state());

    p0.destroy_for_testing(a0);
    p1.destroy_for_testing(a1);
    destroy(rel);
    destroy(cap);
}
