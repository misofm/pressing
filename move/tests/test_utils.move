// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_pressing::test_utils;

use miso::release::{Self, Release, ReleaseAdminCap};
use sui::clock::{Self, Clock};

/// A second currency, for testing a pressing listed in more than one.
public struct USDX has drop {}

public fun id(addr: address): ID {
    object::id_from_address(addr)
}

public fun clock_at(ms: u64, ctx: &mut TxContext): Clock {
    let mut c = clock::create_for_testing(ctx);
    c.set_for_testing(ms);
    c
}

public fun a_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing(b"Test".to_string(), vector[], ctx)
}
