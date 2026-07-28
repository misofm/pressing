// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A release's primary sale — a *Drop*.
///
/// A drop is the namespace for everything a release sells. It holds no terms of its own:
/// it exists to own the edition sequence and to be the object every edition derives from.
/// Its three levels each answer one question and nothing else:
///
/// ```text
/// Release
///  └─ Drop                     which release is selling      DropKey()
///      └─ Edition (n)          which run, and how many       EditionKey(n)
///          ├─ Listing<SUI>     what it costs, and when       ListingKey(TypeName)
///          └─ Listing<USDC>
/// ```
///
/// # Everything is address math
///
/// A drop's UID is derived off its release's UID at a singleton key, an edition's off the
/// drop's at its number, a listing's off the edition's at its currency type. So every
/// object in the tree is reachable from the release id alone, by pure computation — no
/// registry, no package-level shared state, and no pointer that has to be maintained.
/// `editions` is the only thing a client needs beyond that: it says how far the sequence
/// runs, and `derive_id` does the rest.
///
/// That also makes the sequence gap-free for free. The counter picks the next number and
/// a derived key can be claimed only once, so `0, 1, 2, …` is the only shape the sequence
/// can take — there is no guard to enforce, and no way for a caller to skip a number.
///
/// # Nothing here is ever destroyed
///
/// Drops and editions are permanent. Their claim markers are what keep a sold record
/// verifiable and what stop an edition number or a currency slot from ever being reused,
/// so they have to outlive everything derived from them. Only listings are destroyed, and
/// only because the edition beneath them survives to remember that they existed.
///
/// # Authority
///
/// Opening a drop needs the release's `ReleaseAdminCap`, enforced by the protocol's
/// `release::uid_mut`. Every call after that authorizes against the cap directly — a drop
/// and its editions each remember their `release_id`, so the `Release` object itself is
/// only ever needed once, at the very start.
module miso_drop::drop;

use miso::release::{Release, ReleaseAdminCap};
use miso_drop::edition::{Self, Edition, Supply};
use sui::derived_object;
use sui::event::emit;

//=== Structs ===

/// Key for deriving a `Drop`'s UID off its RELEASE's UID. A singleton — a release has
/// exactly one drop, so the key carries no data and can be claimed exactly once.
public struct DropKey() has copy, drop, store;

/// A release's primary sale: the namespace its editions derive from, and the counter that
/// numbers them. Never destroyed, and holds no terms — those live on the edition (supply)
/// and the listing (price, window).
public struct Drop has key {
    id: UID,
    /// The release these records are copies of.
    release_id: ID,
    /// How many editions exist; also the number the next one will take.
    editions: u32,
}

//=== Events ===

public struct DropOpenedEvent has copy, drop {
    drop_id: ID,
    release_id: ID,
}

//=== Errors ===

/// The admin cap does not control this drop's release.
const EUnauthorized: u64 = 0;

//=== Public Functions ===

/// Open a release's drop and its first edition, and return that edition unshared.
///
/// The `Drop` is shared here; the `Edition` is handed back so the same transaction can
/// list it (`listing::new`) before `edition::share` puts it on chain. A caller that has
/// no listing to add just shares it straight away — the value has no `drop` ability, so
/// it cannot be lost by forgetting.
///
/// Claim-once on `DropKey()` means a release's drop can only ever be opened here, exactly
/// once; calling this twice for the same release aborts.
public fun new(release: &mut Release, cap: &ReleaseAdminCap, supply: Supply): Edition {
    let release_id = release.id();
    let id = derived_object::claim(release.uid_mut(cap), DropKey());

    emit(DropOpenedEvent { drop_id: id.to_inner(), release_id });

    let mut self = Drop { id, release_id, editions: 0 };
    let edition = self.open_edition(supply);
    transfer::share_object(self);
    edition
}

/// Open the next edition — a second pressing of the same record — and return it unshared,
/// so the same transaction can list it before sharing.
///
/// This does NOT close the previous edition. Whether being early meant anything is the
/// artist's decision, not the protocol's: seal edition `n` (`edition::seal`) before
/// opening `n + 1` and the first edition is genuinely finite; leave it open and both runs
/// sell side by side. Serial numbers restart at 1 for the new edition, and records already
/// sold stay verifiable against their own edition forever.
public fun next_edition(self: &mut Drop, cap: &ReleaseAdminCap, supply: Supply): Edition {
    self.authorize(cap);
    self.open_edition(supply)
}

//=== Internal ===

/// Take the next number off the counter and claim that edition's derived UID.
fun open_edition(self: &mut Drop, supply: Supply): Edition {
    let drop_id = self.id.to_inner();
    let release_id = self.release_id;
    let number = self.editions;
    self.editions = number + 1;

    edition::new(&mut self.id, release_id, drop_id, number, supply)
}

/// Abort unless `cap` controls this drop's release.
fun authorize(self: &Drop, cap: &ReleaseAdminCap) {
    assert!(cap.release_admin_cap_release_id() == self.release_id, EUnauthorized);
}

//=== View Functions ===

/// The address `release_id`'s drop occupies — pure address math, computable before the
/// drop has been opened.
public fun derive_id(release_id: ID): ID {
    derived_object::derive_address(release_id, DropKey()).to_id()
}

public fun id(self: &Drop): ID {
    self.id.to_inner()
}

public fun release_id(self: &Drop): ID {
    self.release_id
}

/// How many editions this drop has opened.
public fun editions(self: &Drop): u32 {
    self.editions
}

/// The id of edition `number`, or `none` if the drop has not opened that many.
public fun edition_id(self: &Drop, number: u32): Option<ID> {
    if (number >= self.editions) return option::none();
    option::some(edition::derive_id(self.id.to_inner(), number))
}

/// The id of the most recently opened edition, or `none` if there are none. Note this is
/// the LATEST edition, which is not necessarily the only one selling — an artist may
/// leave earlier editions open.
public fun latest_edition_id(self: &Drop): Option<ID> {
    if (self.editions == 0) return option::none();
    option::some(edition::derive_id(self.id.to_inner(), self.editions - 1))
}

//=== Test Helpers ===

/// Build an unshared `Drop` on a fresh UID, for tests that exercise the edition sequence
/// without a release to derive off.
#[test_only]
public fun new_for_testing(release_id: ID, ctx: &mut TxContext): Drop {
    Drop { id: object::new(ctx), release_id, editions: 0 }
}

#[test_only]
public fun open_edition_for_testing(self: &mut Drop, supply: Supply): Edition {
    self.open_edition(supply)
}

#[test_only]
public fun destroy_for_testing(self: Drop) {
    let Drop { id, .. } = self;
    id.delete();
}
