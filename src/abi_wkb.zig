// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! WKB conversion, native only.
//!
//! WKB is how this library reaches GeoParquet, PostGIS and the comparison
//! suite. All of those run against the native library, which is also what a
//! Python module would link, so WKB stays here and out of the browser build.
//!
//! Every export here carries `wkb` in its name. The unqualified `geom_*` names
//! belong to the primary surface in `abi.zig`, which is what a browser calls;
//! these exist for hosts that already hold WKB and would rather not convert.
const std = @import("std");
const abi = @import("abi.zig");
const geo = abi.geo;
const allocator = abi.allocator;
const status = abi.status;

/// Input bytes are **borrowed** for the duration of the call: they are parsed
/// into the library's own allocations and never taken ownership of. A caller
/// passes a stack array, a `malloc` block or an `mmap`ed file, whichever it
/// already has. There is no allocate/free pair here, because a native caller
/// has its own allocator and never needed one — that pairing only makes sense
/// for a WASM host, which cannot reach into the module's linear memory, and the
/// WASM build has `geom_input` for exactly that.
export fn geom_wkb_result_ptr() usize {
    return if (abi.result.len == 0) 0 else @intFromPtr(abi.result.ptr);
}
export fn geom_wkb_result_len() usize {
    return abi.result.len;
}

/// Every operation, the same five the coordinate ABI has, over WKB bytes.
///
/// One entry point rather than one per operation: the operation is a value, so
/// adding one costs nothing here. See `geom_apply` in `abi.zig`, whose argument
/// list this mirrors after the two that say where the bytes are.
export fn geom_wkb_apply(op: u32, ptr: usize, len: usize, subject: u32, distance: f64, steps: u32) u32 {
    abi.releaseResults();
    process(op, ptr, len, subject, distance, steps) catch |err| return status(err);
    return 0;
}

fn process(op: u32, ptr: usize, len: usize, subject: u32, distance: f64, steps: u32) !void {
    // A null pointer with a nonzero length is a caller bug, but it has to come
    // back as a status code like every other malformed input: building the
    // slice anyway kills the host process instead of failing the call.
    if (len != 0 and ptr == 0) return error.MalformedGeometry;
    const bytes: []const u8 = if (len == 0) &.{} else @as([*]const u8, @ptrFromInt(ptr))[0..len];
    var input = try geo.wkb.parse(allocator, bytes, .{});
    defer input.deinit();
    var output = try abi.execute(.{
        .polygons = input.polygons,
        .line_strings = input.line_strings,
        .points = input.points,
    }, op, subject, distance, steps);
    defer output.deinit();
    abi.result = try geo.wkb.write(allocator, output.polygons, .little);
}
