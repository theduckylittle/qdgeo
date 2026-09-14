// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! The WKB half of the host ABI, native only.
//!
//! WKB is how this library reaches GeoParquet, PostGIS and the comparison
//! suite. All of those run against the native library, which is also what a
//! Python module would link, so WKB stays here and out of the browser build.
const std = @import("std");
const abi = @import("abi.zig");
const geo = abi.geo;
const allocator = abi.allocator;
const status = abi.status;

export fn geom_alloc(len: usize) usize {
    if (len == 0) return 0;
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}
export fn geom_free(ptr: usize, len: usize) void {
    if (ptr != 0 and len != 0) allocator.free(@as([*]u8, @ptrFromInt(ptr))[0..len]);
}
export fn geom_result_ptr() usize {
    return if (abi.result.len == 0) 0 else @intFromPtr(abi.result.ptr);
}
export fn geom_result_len() usize {
    return abi.result.len;
}

fn process(ptr: usize, len: usize, distance: ?f64, steps: u32) !void {
    const bytes: []const u8 = if (len == 0) &.{} else @as([*]const u8, @ptrFromInt(ptr))[0..len];
    var input = try geo.wkb.parse(allocator, bytes, .{});
    defer input.deinit();
    var output = if (distance) |d|
        try geo.bufferInput(allocator, .{
            .polygons = input.polygons,
            .line_strings = input.line_strings,
            .points = input.points,
        }, d, .{ .quadrant_segments = steps })
    else
        try geo.unionAll(allocator, input.polygons, .{});
    defer output.deinit();
    abi.result = try geo.wkb.write(allocator, output.polygons, .little);
}
export fn geom_union(ptr: usize, len: usize) u32 {
    abi.releaseResults();
    process(ptr, len, null, 16) catch |err| return status(err);
    return 0;
}
/// Buffer with a chosen arc resolution. There is no precision parameter: qdgeo
/// is floating precision only, and an option that is accepted and then always
/// rejected is worse than no option at all.
export fn geom_buffer_with_options(ptr: usize, len: usize, distance: f64, steps: u32) u32 {
    abi.releaseResults();
    process(ptr, len, distance, steps) catch |err| return status(err);
    return 0;
}
export fn geom_buffer(ptr: usize, len: usize, distance: f64) u32 {
    abi.releaseResults();
    process(ptr, len, distance, 16) catch |err| return status(err);
    return 0;
}
