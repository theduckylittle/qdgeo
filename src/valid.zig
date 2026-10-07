// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! `makeValid`: the one place qdgeo repairs geometry, and only when asked.
//!
//! Every other operation rejects invalid input or reads it as given. This one
//! is for a caller who knows their polygons may be broken — hand-digitized
//! shapes that cross themselves, overshoot the closing vertex, or double back
//! — and wants a valid answer rather than an error.
//!
//! The rules are JTS's `GeometryFixer`, so code ported from JTS or from a
//! JSTS `buffer(0)` gets the answer it expects, without the lobes `buffer(0)`
//! drops:
//!
//! - A ring covers every point it winds around, in either direction. A bowtie
//!   keeps both lobes, and a loop that re-covers the body leaves no hole. In
//!   winding terms that is the non-zero rule, `Mode.nonzero`.
//! - Each ring is repaired on its own, so a hole drawn the other way round
//!   from its neighbour cannot cancel it.
//! - A hole that meets the shell is subtracted from it. A hole entirely
//!   outside the shell becomes a polygon of its own.
//! - The polygons of a collection are repaired separately and then unioned.
//! - Vertices with a non-finite ordinate are removed, repeated vertices are
//!   merged, and an open ring is closed. A ring left with no area — a spike,
//!   a collinear ring, fewer than three distinct points — is dropped, which is
//!   `GeometryFixer`'s default and keeps the result areal.
//!
//! Nothing is snapped. The repair is the same exact overlay every other
//! operation uses, so it can still fail with `error.UnnodableCrossing` on the
//! rare crossing `f64` cannot place a vertex on, and an out-of-range
//! coordinate is still `error.CoordinateRange`: that is a limit of the
//! arithmetic, not a defect in the shape.
const std = @import("std");
const g = @import("geometry.zig");
const sweep = @import("sweep.zig");
const operations = @import("operations.zig");
const relate = @import("relate.zig");

const A = std.mem.Allocator;

/// Repair `polygons` into valid ones. See the module comment for the rules.
pub fn makeValid(a: A, polygons: []const g.Polygon, options: operations.BooleanOptions) !g.Geometry {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();

    var budget = Budget{ .left = options.limits.max_segments };
    var parts: std.ArrayList(g.Polygon) = .empty;
    // Each entry is already valid on its own. More than one has to be
    // unioned, since repaired polygons may overlap one another.
    var pieces: usize = 0;
    for (polygons) |polygon| {
        const fixed = try fixPolygon(sa, polygon, options.limits, &budget);
        if (fixed.len == 0) continue;
        try parts.appendSlice(sa, fixed);
        pieces += 1;
    }
    if (pieces > 1) return operations.unionAll(a, parts.items, options);
    return own(a, parts.items);
}

/// The segment budget, shared by every ring of the call so a large input
/// cannot dodge `max_segments` by arriving in many small rings.
const Budget = struct {
    left: usize,

    fn take(b: *Budget, n: usize) !void {
        if (n > b.left) return error.LimitExceeded;
        b.left -= n;
    }
};

/// One polygon, repaired. The result is valid but may be several polygons.
fn fixPolygon(sa: A, polygon: g.Polygon, limits: g.Limits, budget: *Budget) ![]const g.Polygon {
    if (polygon.rings.len == 0) return &.{};
    const shell = try fixRing(sa, polygon.rings[0], limits, budget);
    if (shell.len == 0 or polygon.rings.len == 1) return shell;

    // A hole is classified whole, after its own repair, the way
    // `GeometryFixer.classifyHoles` does it.
    var cut: std.ArrayList(g.Polygon) = .empty;
    var outside: std.ArrayList(g.Polygon) = .empty;
    for (polygon.rings[1..]) |ring| {
        const hole = try fixRing(sa, ring, limits, budget);
        if (hole.len == 0) continue;
        const meets = try relate.intersects(sa, .{ .polygons = shell }, .{ .polygons = hole }, .{});
        try (if (meets) &cut else &outside).appendSlice(sa, hole);
    }

    var body = shell;
    if (cut.items.len != 0) {
        const options: operations.BooleanOptions = .{ .limits = limits };
        body = (try operations.boolean(sa, shell, cut.items, .difference, options)).polygons;
    }
    if (outside.items.len == 0) return body;
    try outside.appendSlice(sa, body);
    return (try operations.unionAll(sa, outside.items, .{ .limits = limits })).polygons;
}

/// One ring, repaired into the region it winds around. Empty when nothing
/// with area is left.
fn fixRing(sa: A, ring: g.LinearRing, limits: g.Limits, budget: *Budget) ![]const g.Polygon {
    var points: std.ArrayList(g.Coordinate) = .empty;
    try points.ensureTotalCapacity(sa, ring.len + 1);
    for (ring) |p| {
        if (!g.finite(p)) continue;
        if (!g.within(p, g.coordinate_limit)) return error.CoordinateRange;
        if (points.items.len != 0 and g.equal(points.items[points.items.len - 1], p)) continue;
        points.appendAssumeCapacity(p);
    }
    if (points.items.len != 0 and !g.equal(points.items[0], points.items[points.items.len - 1])) {
        points.appendAssumeCapacity(points.items[0]);
    }
    // Three distinct points and the closing one is the least that can hold
    // area. Anything less has collapsed to a point or a line.
    if (points.items.len < 4) return &.{};
    for (points.items[0 .. points.items.len - 1], points.items[1..]) |p, q| {
        if (@max(@abs(p.x - q.x), @abs(p.y - q.y)) < 1e-140) return error.CoordinateRange;
    }
    try budget.take(points.items.len - 1);

    const paths = [_]g.Path{.{ .points = points.items }};
    return (try sweep.execute(sa, &paths, .nonzero, limits, .crossings)).polygons;
}

/// `polygons` copied into a result of its own, for the one-piece case where
/// no final union runs to produce one.
fn own(a: A, polygons: []const g.Polygon) !g.Geometry {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const oa = arena.allocator();
    const out = try oa.alloc(g.Polygon, polygons.len);
    for (polygons, out) |polygon, *copy| {
        const rings = try oa.alloc(g.LinearRing, polygon.rings.len);
        for (polygon.rings, rings) |ring, *r| r.* = try oa.dupe(g.Coordinate, ring);
        copy.* = .{ .rings = rings };
    }
    return .{ .arena = arena, .polygons = out };
}
