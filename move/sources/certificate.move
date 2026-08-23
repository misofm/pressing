// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Immutable provenance for a record pressed by `miso_pressing`.
///
/// `Certificate` is embedded in `Record<Certificate>`, never attached as a dynamic
/// field. Its private fields and package-only constructor mean an external package
/// cannot construct this certificate or mint the trusted record specialization.
module miso_pressing::certificate;

use std::type_name::{Self, TypeName};

//=== Structs ===

/// A pressing's immutable account of one record it produced.
public struct Certificate has drop, store {
    /// The object whose derived-UID namespace issued this record.
    parent_id: ID,
    /// Position in the pressing's run (1-based).
    number: u64,
    /// The transaction sender that purchased the record from its listing.
    purchased_by: address,
    /// The currency type the buyer paid in.
    purchase_currency: TypeName,
    /// The exact amount paid. Under a floor price this includes any tip above it.
    purchase_price: u64,
    /// The timestamp stamped from the shared Clock on the pressing path.
    created_at_ms: u64,
}

//=== Package Functions ===

/// Create a certificate for a pressing path. Only modules in this package can call
/// this constructor; `pressing::mint_next` is the sole production caller.
public(package) fun new<Currency>(
    parent_id: ID,
    number: u64,
    purchased_by: address,
    purchase_price: u64,
    created_at_ms: u64,
): Certificate {
    Certificate {
        parent_id,
        number,
        purchased_by,
        purchase_currency: type_name::with_defining_ids<Currency>(),
        purchase_price,
        created_at_ms,
    }
}

//=== View Functions ===

public fun parent_id(self: &Certificate): ID {
    self.parent_id
}

public fun number(self: &Certificate): u64 {
    self.number
}

public fun purchased_by(self: &Certificate): address {
    self.purchased_by
}

public fun purchase_currency(self: &Certificate): TypeName {
    self.purchase_currency
}

public fun purchase_price(self: &Certificate): u64 {
    self.purchase_price
}

public fun created_at_ms(self: &Certificate): u64 {
    self.created_at_ms
}
