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

fn process(ptr: usize, len: usize, distance: ?f64, steps: u32) !void {
    // A null pointer with a nonzero length is a caller bug, but it has to come
    // back as a status code like every other malformed input: building the
    // slice anyway kills the host process instead of failing the call.
    if (len != 0 and ptr == 0) return error.MalformedGeometry;
    const bytes: []const u8 = if (len == 0) &.{} else @as([*]const u8, @ptrFromInt(ptr))[0..len];
    var input = try geo.wkb.parse(allocator, bytes, .{});
    defer input.deinit();
    var output = if (distance) |d|
        try geo.buffer(allocator, .{
            .polygons = input.polygons,
            .line_strings = input.line_strings,
            .points = input.points,
        }, d, .{ .quadrant_segments = steps })
    else
        try geo.unionAll(allocator, input.polygons, .{});
    defer output.deinit();
    abi.result = try geo.wkb.write(allocator, output.polygons, .little);
}
export fn geom_wkb_union(ptr: usize, len: usize) u32 {
    abi.releaseResults();
    process(ptr, len, null, 16) catch |err| return status(err);
    return 0;
}
/// Buffer with a chosen arc resolution. There is no precision parameter: qdgeo
/// is floating precision only, and an option that is accepted and then always
/// rejected is worse than no option at all.
export fn geom_wkb_buffer(ptr: usize, len: usize, distance: f64, steps: u32) u32 {
    abi.releaseResults();
    process(ptr, len, distance, steps) catch |err| return status(err);
    return 0;
}
