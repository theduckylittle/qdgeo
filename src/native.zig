// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Root of the native shared library: the flat ABI plus WKB.
comptime {
    _ = @import("abi.zig");
    _ = @import("abi_wkb.zig");
}
