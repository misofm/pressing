// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The pressing's certificate on a record.
///
/// One struct holds everything the sale fixed about a copy: where it sits in the run,
/// and what was paid for it. These were two dynamic fields — a certificate and a
/// receipt — and separating them bought nothing: both are written once, in the same
/// transaction, by the same call, and neither is meaningful without the other.
///
/// A serial is only meaningful inside the sequence that issued it — a different
/// production package counts from 1 again — so the number never travels alone. It
/// does not need to carry its pressing's id to say which sequence it means: a release
/// has exactly one pressing, at a derived address, so `pressing::derive_id(
/// record.release_id())` recomputes it from the record itself. Storing it would be
/// storing a value that is pure arithmetic on values already present.
module miso_pressing::certificate;

use miso_record::record::Record;
use std::type_name::{Self, TypeName};
use sui::dynamic_field as df;

//=== Structs ===

/// Key for the `Certificate` dynamic field on a record. Constructible only inside
/// this module — written exactly once, at mint, and never removable by anyone else.
public struct CertificateKey() has copy, drop, store;

/// A record's position in its pressing's run, and the terms it sold on.
public struct Certificate has copy, drop, store {
    /// Position in the pressing's run (1-based).
    number: u64,
    /// The currency type the buyer paid in.
    purchase_currency: TypeName,
    /// The exact amount paid. Under a floor price this includes any tip above it.
    purchase_price: u64,
}

//=== Package Functions ===

/// Stamp the record with its certificate. Called once by `pressing::mint_next`, the
/// single path every record takes into being — same transaction as the mint itself.
public(package) fun attach<Currency>(record: &mut Record, number: u64, purchase_price: u64) {
    df::add(
        record.uid_mut(),
        CertificateKey(),
        Certificate {
            number,
            purchase_currency: type_name::with_defining_ids<Currency>(),
            purchase_price,
        },
    );
}

//=== View Functions ===

/// The certificate on `record`, or `none` for a record minted by some other package.
/// The only way to read the field, since only this module can construct its key.
public fun of(record: &Record): Option<Certificate> {
    if (df::exists(record.uid(), CertificateKey())) {
        option::some(*df::borrow(record.uid(), CertificateKey()))
    } else {
        option::none()
    }
}

public fun number(self: &Certificate): u64 {
    self.number
}

public fun purchase_currency(self: &Certificate): TypeName {
    self.purchase_currency
}

public fun purchase_price(self: &Certificate): u64 {
    self.purchase_price
}
