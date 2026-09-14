// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
const std = @import("std");
const g = @import("geometry.zig");
const offset = @import("offset.zig");
const sweep = @import("sweep.zig");
const pred = @import("predicates.zig");

pub const UnionOptions = struct {
    limits: g.Limits = .{},
};
pub const BufferOptions = struct {
    quadrant_segments: u32 = 16,
    /// See `offset.Style.simplify_factor`. Off by default.
    simplify_factor: f64 = 0,
    limits: g.Limits = .{},
};

fn normalize(a: std.mem.Allocator, paths: *std.ArrayList(g.Path), segments: *usize, polygons: []const g.Polygon, limit: usize, layer: u1) !void {
    for (polygons) |poly| {
        for (poly.rings, 0..) |ring, index| {
            try g.validateLinearRing(ring);
            if (ring.len - 1 > limit - segments.*) return error.LimitExceeded;
            segments.* += ring.len - 1;
            var points: std.ArrayList(g.Coordinate) = .empty;
            // The ring is the upper bound and repeated points only shrink it.
            try points.ensureTotalCapacity(a, ring.len);
            for (ring) |p| {
                if (!g.within(p, 1e140)) return error.CoordinateRange;
                if (points.items.len != 0 and g.equal(points.items[points.items.len - 1], p)) continue;
                points.appendAssumeCapacity(p);
            }
            if (points.items.len < 4) return error.InvalidRing;
            const winding = pred.areaSign(points.items);
            if (winding == 0) return error.InvalidTopology;
            if ((winding > 0) != (index == 0)) std.mem.reverse(g.Coordinate, points.items);
            for (points.items[0 .. points.items.len - 1], points.items[1..]) |p, q| {
                if (@max(@abs(p.x - q.x), @abs(p.y - q.y)) < 1e-140) return error.CoordinateRange;
            }
            try paths.append(a, .{ .points = try points.toOwnedSlice(a), .layer = layer });
        }
    }
}

/// Planar boolean operation with adaptive noding and winding-depth labelling.
/// Input polygons must have valid OGC topology. No snapping, no integer lattice.
///
/// `subject` becomes winding layer 0 and `clip` layer 1, which is the whole of
/// what separates the four operations — see `geometry.Mode.covers`.
pub fn boolean(
    a: std.mem.Allocator,
    subject: []const g.Polygon,
    clip: []const g.Polygon,
    mode: g.Mode,
    options: UnionOptions,
) !g.Geometry {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var paths: std.ArrayList(g.Path) = .empty;
    var segments: usize = 0;
    try normalize(sa, &paths, &segments, subject, options.limits.max_segments, 0);
    try normalize(sa, &paths, &segments, clip, options.limits.max_segments, 1);
    return sweep.execute(a, paths.items, mode, options.limits);
}

/// N-ary union: everything is one operand, so overlapping input simply stacks.
pub fn unionAll(a: std.mem.Allocator, polygons: []const g.Polygon, options: UnionOptions) !g.Geometry {
    return boolean(a, polygons, &.{}, .union_all, options);
}

pub fn buffer(a: std.mem.Allocator, polygon: g.Polygon, distance: f64) !g.Geometry {
    return bufferAll(a, &.{polygon}, distance, .{});
}
pub fn bufferWithOptions(a: std.mem.Allocator, polygon: g.Polygon, distance: f64, options: BufferOptions) !g.Geometry {
    return bufferAll(a, &.{polygon}, distance, options);
}

/// Everything a buffer can be asked to grow. Areal input is unioned first so
/// overlapping polygons behave as one region; the rest contributes only when the
/// distance is positive, because a point and a line have no interior to erode.
pub const Input = struct {
    polygons: []const g.Polygon = &.{},
    line_strings: []const g.LineString = &.{},
    points: []const g.Coordinate = &.{},
};

/// JTS's `isErodedCompletely`. A ring narrower than twice the erosion distance
/// has no point far enough from its own boundary to survive, and offsetting it
/// anyway emits a curve that has turned inside out — still closed, still wound
/// positively, and enclosing a region that is not in the buffer at all. The
/// envelope test is exact in the direction it measures; the triangle case needs
/// the incircle.
fn erodedCompletely(ring: g.LinearRing, distance: f64) bool {
    if (distance >= 0) return false;
    if (ring.len < 4) return true;
    if (ring.len == 4) {
        const centre = incentre(ring[0], ring[1], ring[2]);
        return g.distanceToSegment(ring[0], ring[1], centre) < @abs(distance);
    }
    const extent = g.Extent.around(ring).span();
    return 2 * @abs(distance) > @min(extent.x, extent.y);
}

fn incentre(a: g.Coordinate, b: g.Coordinate, c: g.Coordinate) g.Coordinate {
    const la = g.distance(b, c);
    const lb = g.distance(a, c);
    const lc = g.distance(a, b);
    const total = la + lb + lc;
    if (!(total > 0)) return a;
    return .{
        .x = (la * a.x + lb * b.x + lc * c.x) / total,
        .y = (la * a.y + lb * b.y + lc * c.y) / total,
    };
}

fn addCurve(a: std.mem.Allocator, paths: *std.ArrayList(g.Path), curve: []const g.Coordinate, count: *usize, limit: usize) !void {
    // A curve too short to enclose anything encloses nothing.
    if (curve.len < 4) return;
    if (!g.allWithin(curve, 1e140)) return error.CoordinateRange;
    if (curve.len - 1 > limit - count.*) return error.LimitExceeded;
    count.* += curve.len - 1;
    // Orientation is the answer, not a detail: an outward shell curve winds
    // positively over the buffer and an inward hole curve winds negatively out
    // of it. Nothing here may normalise it.
    try paths.append(a, .{ .points = curve });
}

/// What the input union pass does apart from the overlay itself. Rings come
/// back validated, de-duplicated and oriented, in the order they were given,
/// so ring 0 stays the shell.
fn normalized(a: std.mem.Allocator, polygons: []const g.Polygon, limits: g.Limits) !g.Geometry {
    var result: g.Geometry = .{ .arena = std.heap.ArenaAllocator.init(a), .polygons = &.{} };
    errdefer result.deinit();
    const oa = result.arena.allocator();
    var paths: std.ArrayList(g.Path) = .empty;
    var segments: usize = 0;
    try normalize(oa, &paths, &segments, polygons, limits.max_segments, 0);
    const out = try oa.alloc(g.Polygon, polygons.len);
    var taken: usize = 0;
    for (polygons, out) |poly, *shape| {
        const rings = try oa.alloc(g.LinearRing, poly.rings.len);
        for (paths.items[taken..][0..poly.rings.len], rings) |path, *ring| ring.* = path.points;
        taken += poly.rings.len;
        shape.* = .{ .rings = rings };
    }
    result.polygons = out;
    return result;
}

/// Rounded buffer by offset curves, the JTS/GEOS construction. Each ring, line
/// and point contributes one raw curve, self-intersections and all, and the
/// overlay keeps what those curves wind at least once. Inward collapse, neck
/// splitting and the spurious loops an offset curve makes at a concavity all
/// fall out of that count rather than out of repair heuristics.
pub fn bufferInput(a: std.mem.Allocator, input: Input, distance: f64, options: BufferOptions) !g.Geometry {
    if (!std.math.isFinite(distance)) return error.NonFiniteCoordinate;
    if (@abs(distance) > 1e140) return error.CoordinateRange;
    if (options.quadrant_segments < 1 or options.quadrant_segments > 1024) return error.InvalidOptions;
    // A lone polygon is not unioned first. JTS and GEOS build offset curves
    // straight from the rings, and a union pass here made us disagree with GEOS
    // on every self-intersecting single polygon while costing 37% of the buffer
    // on a 19,208-coordinate parcel. `normalize` still runs: validation,
    // repeated-point removal, shell-CCW/hole-CW orientation, degenerate edges.
    //
    // Several polygons still are. The operation is buffer-of-the-union — which
    // is what `shapely.union_all(gs).buffer(d)` means, and what the suite holds
    // us to — and adjacent parcels sharing a boundary emit coincident offset
    // curves that the single overlay pass cannot node. Dropping it here was
    // measured: `parcels-buffer-100-+2` fails outright, and the eroding cases
    // come back with 101,061 m2 of symmetric difference.
    var united = if (input.polygons.len == 1)
        try normalized(a, input.polygons, options.limits)
    else
        try unionAll(a, input.polygons, .{ .limits = options.limits });
    if (distance == 0) return united;
    defer united.deinit();

    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const radius = @abs(distance);
    const style: offset.Style = .{ .quadrant_segments = options.quadrant_segments, .simplify_factor = options.simplify_factor };
    // Rings arrive with their interior on the left, so growing offsets to the
    // right and eroding offsets to the left, for shells and holes alike.
    const side: offset.Side = if (distance > 0) .right else .left;
    var paths: std.ArrayList(g.Path) = .empty;
    var count: usize = 0;
    for (united.polygons) |poly| {
        // A shell that erodes away takes its holes with it; a hole that fills in
        // simply stops being a hole.
        if (erodedCompletely(poly.rings[0], distance)) continue;
        for (poly.rings, 0..) |ring, index| {
            if (index > 0 and erodedCompletely(ring, -distance)) continue;
            try addCurve(sa, &paths, try offset.ringCurve(sa, ring, side, radius, style), &count, options.limits.max_generated_segments);
        }
    }
    if (distance > 0) {
        for (input.line_strings) |line| {
            try g.validateLineString(line);
            // A closed line is ring linework, not an open chain, and buffering
            // it means the band either side of that ring — an annulus, until
            // the distance is wide enough to swallow the middle. Capping it as
            // an open line instead puts both caps on the same point and hands
            // the overlay a curve it cannot node. Offsetting the ring and its
            // reverse gives one curve winding +1 around the outside and one
            // winding -1 inside, so `winding >= 1` is the annulus exactly.
            const closed = line.len >= 4 and g.equal(line[0], line[line.len - 1]);
            const winding = if (closed) pred.areaSign(line) else 0;
            if (closed and winding != 0) {
                const reversed = try sa.alloc(g.Coordinate, line.len);
                for (reversed, 0..) |*point, i| point.* = line[line.len - 1 - i];
                // `.right` is outward only for a ring wound counter-clockwise,
                // which is the convention every other curve here arrives in. A
                // clockwise line has to be reversed first or both curves offset
                // inward and the buffer comes back inside out.
                const outward = if (winding > 0) line else reversed;
                const inward = if (winding > 0) reversed else line;
                try addCurve(sa, &paths, try offset.ringCurve(sa, outward, .right, radius, style), &count, options.limits.max_generated_segments);
                // Once the band is wider than the ring is across, the middle is
                // swallowed and there is no hole left. The inward curve has
                // turned inside out by then and would still wind, so it needs
                // the same guard a shrinking shell gets.
                if (!erodedCompletely(outward, -radius)) {
                    try addCurve(sa, &paths, try offset.ringCurve(sa, inward, .right, radius, style), &count, options.limits.max_generated_segments);
                }
                continue;
            }
            try addCurve(sa, &paths, try offset.lineCurve(sa, line, radius, style), &count, options.limits.max_generated_segments);
        }
        for (input.points) |point| {
            if (!g.finite(point)) return error.NonFiniteCoordinate;
            try addCurve(sa, &paths, try offset.pointCurve(sa, point, radius, style), &count, options.limits.max_generated_segments);
        }
    }
    if (paths.items.len == 0) return .{ .arena = std.heap.ArenaAllocator.init(a), .polygons = &.{} };
    var limits = options.limits;
    limits.max_segments = limits.max_generated_segments;
    return sweep.execute(a, paths.items, .union_all, limits);
}

pub fn bufferAll(a: std.mem.Allocator, polygons: []const g.Polygon, distance: f64, options: BufferOptions) !g.Geometry {
    return bufferInput(a, .{ .polygons = polygons }, distance, options);
}
