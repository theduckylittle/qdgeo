// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Flat coordinate interchange: the layout OpenLayers already holds.
//!
//! `SimpleGeometry` stores `flatCoordinates` — one array of x, y, x, y — plus
//! `ends` per ring and `endss` per polygon, and its constructors take them back
//! unchanged. Handing that straight to WASM costs one bulk copy each way instead
//! of a serialiser: measured on 4,040 parcels, 21.6 ms of OL/GeoJSON/WKB
//! conversion becomes 0.6 ms, and 135,000 short-lived JavaScript arrays become
//! two typed arrays.
//!
//! One block carries everything, so a host makes one allocation:
//!
//!     [ 2 * coordinates f64 ][ rings u32 ][ polygons u32 ][ line strings u32 ]
//!
//! Every index is an exclusive end offset, and offsets into `coords` count
//! *points*, not numbers, so they do not depend on a stride. Coordinates run
//! bare points first, then line vertices, then polygon ring vertices; `parts`
//! ends index into `rings`. That covers every OpenLayers geometry: a Coordinate is
//! one bare point, a MultiLineString is `lines`, a MultiPolygon is `rings` cut
//! by `parts`, and a GeometryCollection is simply all three at once.
//!
//! WKB stays: it is how this library talks to GeoParquet, PostGIS and the
//! comparison suite. This is the browser's path, not a replacement.
const std = @import("std");
const g = @import("geometry.zig");
const operations = @import("operations.zig");

pub const Counts = extern struct {
    /// Total coordinates, the length of OpenLayers' `flatCoordinates` over two.
    coordinates: u32 = 0,
    rings: u32 = 0,
    polygons: u32 = 0,
    line_strings: u32 = 0,
    points: u32 = 0,
};

/// Bytes a block of this shape needs, or `error.LimitExceeded` if the counts
/// cannot describe one.
///
/// `usize` is **32 bits** on wasm32, the shipped target, and every count here
/// comes straight from an untrusted caller as a `u32`. `16 * coordinates`
/// therefore overflows for any count above 268,435,455 — long before the
/// allocator would have refused it. `output` below has always guarded its
/// counts this way; this is the same guard on the way in.
pub fn size(counts: Counts) error{LimitExceeded}!usize {
    const add = struct {
        fn f(a: usize, b: usize) error{LimitExceeded}!usize {
            return std.math.add(usize, a, b) catch error.LimitExceeded;
        }
    }.f;
    const mul = struct {
        fn f(a: usize, b: usize) error{LimitExceeded}!usize {
            return std.math.mul(usize, a, b) catch error.LimitExceeded;
        }
    }.f;
    const indices = try add(try add(counts.rings, counts.polygons), counts.line_strings);
    return try add(try mul(16, counts.coordinates), try mul(4, indices));
}

pub const View = struct {
    coordinates: []const g.Coordinate,
    /// OpenLayers' `Polygon.getEnds()`, in coordinates rather than numbers.
    ring_ends: []const u32,
    /// Where each polygon's run of rings finishes: `MultiPolygon.getEndss()`.
    polygon_ends: []const u32,
    line_string_ends: []const u32,
    points: u32,
};

/// Borrowed view of a host-written block. The coordinates are not copied: the
/// block *is* the point array, which is why `Coordinate` is `extern`.
pub fn view(block: []align(8) const u8, counts: Counts) !View {
    if (block.len < try size(counts)) return error.MalformedGeometry;
    const coordinates: [*]const g.Coordinate = @ptrCast(block.ptr);
    const indices: [*]const u32 = @ptrCast(@alignCast(block.ptr + 16 * @as(usize, counts.coordinates)));
    return .{
        .coordinates = coordinates[0..counts.coordinates],
        .ring_ends = indices[0..counts.rings],
        .polygon_ends = indices[counts.rings..][0..counts.polygons],
        .line_string_ends = indices[@as(usize, counts.rings) + counts.polygons ..][0..counts.line_strings],
        .points = counts.points,
    };
}

/// Cut the block into borrowed polygons, lines and points. Only the small index
/// structures are allocated; every coordinate slice points into the block.
pub fn input(a: std.mem.Allocator, v: View) !operations.Input {
    if (v.points > v.coordinates.len) return error.MalformedGeometry;
    var cursor: usize = v.points;

    const line_strings = try a.alloc(g.LineString, v.line_string_ends.len);
    for (v.line_string_ends, line_strings) |end, *line| {
        if (end <= cursor or end > v.coordinates.len) return error.MalformedGeometry;
        line.* = v.coordinates[cursor..end];
        cursor = end;
    }

    const polygons = try a.alloc(g.Polygon, v.polygon_ends.len);
    var boundary: usize = 0;
    for (v.polygon_ends, polygons) |part, *polygon| {
        if (part <= boundary or part > v.ring_ends.len) return error.MalformedGeometry;
        const rings = try a.alloc(g.LinearRing, part - boundary);
        for (v.ring_ends[boundary..part], rings) |end, *ring| {
            if (end <= cursor or end > v.coordinates.len) return error.MalformedGeometry;
            ring.* = v.coordinates[cursor..end];
            cursor = end;
        }
        polygon.* = .{ .rings = rings };
        boundary = part;
    }
    if (cursor != v.coordinates.len) return error.TrailingBytes;
    return .{ .polygons = polygons, .line_strings = line_strings, .points = v.coordinates[0..v.points] };
}

pub const Block = struct { bytes: []align(8) u8, counts: Counts };

/// Results are always areal, so the block carries coordinates, ring ends and
/// polygon ends and nothing else.
pub fn output(a: std.mem.Allocator, polygons: []const g.Polygon) !Block {
    var counts: Counts = .{ .polygons = std.math.cast(u32, polygons.len) orelse return error.LimitExceeded };
    for (polygons) |shape| {
        counts.rings +|= std.math.cast(u32, shape.rings.len) orelse return error.LimitExceeded;
        for (shape.rings) |ring| {
            counts.coordinates = std.math.add(u32, counts.coordinates, std.math.cast(u32, ring.len) orelse
                return error.LimitExceeded) catch return error.LimitExceeded;
        }
    }
    const bytes = try a.alignedAlloc(u8, .@"8", try size(counts));
    const coordinates: [*]g.Coordinate = @ptrCast(bytes.ptr);
    const indices: [*]u32 = @ptrCast(@alignCast(bytes.ptr + 16 * @as(usize, counts.coordinates)));
    var coordinate: u32 = 0;
    var ring_index: u32 = 0;
    for (polygons, 0..) |shape, polygon| {
        for (shape.rings) |ring| {
            // Contiguous either side, so the whole ring moves in one go.
            @memcpy(coordinates[coordinate..][0..ring.len], ring);
            coordinate += @intCast(ring.len);
            indices[ring_index] = coordinate;
            ring_index += 1;
        }
        indices[@as(usize, counts.rings) + polygon] = ring_index;
    }
    return .{ .bytes = bytes, .counts = counts };
}
