// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! The host ABI: one coordinate block in, one out.
//!
//! This is the whole surface the browser gets, and the browser is 90% of the
//! target. WKB lives in `abi_wkb.zig` and links only into the native library:
//! no browser host wants it — OpenLayers holds flat coordinates and MapLibre
//! holds GeoJSON — and leaving it out drops six exports and 4 KiB gzipped. One
//! block in, one block out, reused across calls.
//!
//! Both remaining targets speak this layout natively. OpenLayers stores
//! `flatCoordinates` plus ends; Shapely's `to_ragged_array` returns coordinates
//! plus ring and polygon offsets. See `flat.zig`.
const std = @import("std");
pub const geo = @import("root.zig");
pub const flat = @import("flat.zig");
const wasm = @import("builtin").target.cpu.arch == .wasm32;
pub const allocator = if (wasm) std.heap.wasm_allocator else std.heap.page_allocator;
/// The WKB path's output. It lives here so `geom_clear` can release everything
/// the ABI owns, whichever half produced it.
pub var result: []u8 = &.{};
var block: []align(8) u8 = &.{};
var counts: flat.Counts = .{};
var flat_result: flat.Block = .{ .bytes = &.{}, .counts = .{} };

export fn geom_clear() void {
    releaseResults();
    if (block.len != 0) allocator.free(block);
    block = &.{};
    counts = .{};
}
pub fn status(err: anyerror) u32 {
    // The freestanding WASM target has no stderr, and reaching for one drags
    // std.posix into the build. Callers get the status code either way.
    if (!wasm) {
        std.debug.print("operation error: {s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
    }
    return switch (err) {
        error.OutOfMemory => 1,
        error.UnsupportedGeometry => 2,
        error.LimitExceeded => 3,
        error.PrecisionLoss, error.CoordinateRange => 4,
        error.InvalidOptions => 6,
        else => 5,
    };
}

// --- The coordinate ABI ------------------------------------------------------
//
// One block in, one block out, in the layout OpenLayers already holds. See
// `src/flat.zig` for the layout; `tests/wasm.mjs` has a working host. There is
// no other shape to contrast this with, so nothing here says "flat": the WKB
// entry points in `abi_wkb.zig` are the ones that need a qualifier.

/// Reserve the input block and hand back its address. The host then writes
/// `2 * coordinates` f64 followed by `rings + polygons + line_strings` u32 into
/// it. Reserving again, or `geom_clear`, releases the previous one.
export fn geom_input(coordinates: u32, rings: u32, polygons: u32, line_strings: u32, points: u32) usize {
    counts = .{ .coordinates = coordinates, .rings = rings, .polygons = polygons, .line_strings = line_strings, .points = points };
    // Counts that cannot describe a block are refused here, before anything is
    // allocated, the same way an allocation failure is.
    const wanted = flat.size(counts) catch {
        counts = .{};
        return 0;
    };
    if (wanted == 0) {
        counts = .{};
        return 0;
    }
    // A host that calls repeatedly — a map redrawing a selection buffer — pays
    // no allocator traffic once its block is big enough.
    if (block.len < wanted) {
        if (block.len != 0) allocator.free(block);
        block = allocator.alignedAlloc(u8, .@"8", wanted) catch {
            block = &.{};
            counts = .{};
            return 0;
        };
    }
    return @intFromPtr(block.ptr);
}

/// Every operation goes through one entry point, so adding one costs a value in
/// `geometry.Mode` rather than another export.
///
///   0 union, 1 intersection, 2 difference, 3 symmetric difference, 4 buffer.
///
/// `subject` is how many of the block's leading polygons form the first operand;
/// the rest are the second. Union cannot tell the difference and buffer takes
/// the whole block, so both ignore it in practice.
///
/// `distance` is the buffer distance, and it applies to every operation, not
/// just op 4. On a boolean operation a nonzero distance buffers the *result*,
/// so "intersect these, then grow the overlap by 5 m" is one call. Zero leaves
/// a boolean result alone, which is what a host that never wants a buffer
/// already passes. `steps` is segments per quarter circle on a rounded corner.
export fn geom_apply(op: u32, subject: u32, distance: f64, steps: u32) u32 {
    releaseResults();
    run(op, subject, distance, steps) catch |err| return status(err);
    return 0;
}

fn run(op: u32, subject: u32, distance: f64, steps: u32) !void {
    const borrowed = try flat.view(block[0..try flat.size(counts)], counts);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const input = try flat.input(scratch.allocator(), borrowed);
    if (op == 4) {
        var output = try geo.buffer(allocator, input, distance, .{ .quadrant_segments = steps });
        defer output.deinit();
        flat_result = try flat.output(allocator, output.polygons);
        return;
    }

    const mode: geo.Mode = switch (op) {
        0 => .union_all,
        1 => .intersection,
        2 => .difference,
        3 => .symmetric_difference,
        else => return error.InvalidOptions,
    };
    const split = @min(subject, input.polygons.len);
    var output = try geo.boolean(allocator, input.polygons[0..split], input.polygons[split..], mode, .{});
    defer output.deinit();

    // A nonzero distance buffers the result of the boolean operation. Doing it
    // here rather than in a second call keeps the intermediate geometry inside
    // the module: a host that wants "difference, then grow by 5 m" pays one
    // crossing instead of two, and never has to copy the intermediate out.
    if (distance != 0) {
        var grown = try geo.bufferAll(allocator, output.polygons, distance, .{ .quadrant_segments = steps });
        defer grown.deinit();
        flat_result = try flat.output(allocator, grown.polygons);
        return;
    }
    flat_result = try flat.output(allocator, output.polygons);
}

pub fn releaseResults() void {
    if (result.len != 0) allocator.free(result);
    result = &.{};
    if (flat_result.bytes.len != 0) allocator.free(flat_result.bytes);
    flat_result = .{ .bytes = &.{}, .counts = .{} };
}

export fn geom_result_ptr() usize {
    return if (flat_result.bytes.len == 0) 0 else @intFromPtr(flat_result.bytes.ptr);
}
export fn geom_result_coordinates() u32 {
    return flat_result.counts.coordinates;
}
export fn geom_result_rings() u32 {
    return flat_result.counts.rings;
}
export fn geom_result_polygons() u32 {
    return flat_result.counts.polygons;
}
