// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
const std = @import("std");
/// `extern` so a flat coordinate block can be reinterpreted as points with no
/// copy: the host writes x, y pairs and this is that memory.
pub const Coordinate = extern struct { x: f64, y: f64 };
pub const LinearRing = []const Coordinate;
/// An open polyline. Unlike a `LinearRing` it need not close and may have two points.
pub const LineString = []const Coordinate;
pub const Polygon = struct { rings: []const LinearRing };

/// The contract both overlay engines implement. `layer` selects which winding
/// counter an input path contributes to.
pub const Path = struct { points: []const Coordinate, layer: u1 = 0 };
/// What the overlay keeps, as a rule over the two winding counters a `Path`
/// contributes to. Every boolean operation is one of these; adding one costs a
/// line here and a line in each engine's `filled`, and nothing else.
pub const Mode = enum {
    /// Covered by either operand. Union, and what buffer asks for.
    union_all,
    intersection,
    /// In the first operand and not the second.
    difference,
    symmetric_difference,

    pub fn covers(mode: Mode, winding: [2]i32) bool {
        const subject = winding[0] > 0;
        const clip = winding[1] > 0;
        return switch (mode) {
            .union_all => subject or clip,
            .intersection => subject and clip,
            .difference => subject and !clip,
            .symmetric_difference => subject != clip,
        };
    }
};

/// One budget for the whole pipeline. Parsing, overlay and offset generation
/// used to declare their own caps, which meant the same four numbers were
/// written out in four places and copied between them by hand.
pub const Limits = struct {
    // Parsing.
    max_points: usize = 1_000_000,
    max_rings: usize = 100_000,
    max_polygons: usize = 100_000,
    /// Nesting depth allowed inside a GeometryCollection.
    max_depth: usize = 16,
    // Overlay.
    max_segments: usize = 1_000_000,
    max_nodes: usize = 4_000_000,
    max_work: usize = 100_000_000,
    max_output_points: usize = 4_000_000,
    /// Offset curves emit more segments than their input has.
    max_generated_segments: usize = 4_000_000,
};

/// All slices belong to this arena. Copying this value does not transfer ownership.
pub const Geometry = struct {
    arena: std.heap.ArenaAllocator,
    polygons: []const Polygon,
    /// Non-areal input. Operations that produce areas leave these empty.
    line_strings: []const LineString = &.{},
    points: []const Coordinate = &.{},
    pub fn deinit(self: *Geometry) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn equal(a: Coordinate, b: Coordinate) bool {
    return @reduce(.And, vec(a) == vec(b));
}

/// A coordinate as an f64x2, which is one `v128` on the WASM target. Every
/// routine below works in this form so a coordinate costs one instruction
/// rather than two.
pub const V2 = @Vector(2, f64);
pub inline fn vec(c: Coordinate) V2 {
    return .{ c.x, c.y };
}
pub inline fn coordinate(v: V2) Coordinate {
    return .{ .x = v[0], .y = v[1] };
}
inline fn splat(x: f64) V2 {
    return @splat(x);
}
/// Sum of lanes: the dot product of two coordinates is `dot(vec(a) * vec(b))`.
inline fn dot(v: V2) f64 {
    return @reduce(.Add, v);
}

pub fn finite(p: Coordinate) bool {
    return @reduce(.And, @abs(vec(p)) <= splat(std.math.floatMax(f64)));
}

pub fn within(p: Coordinate, limit: f64) bool {
    return @reduce(.And, @abs(vec(p)) <= splat(limit));
}

/// Two points per iteration, so the check runs as f64x4 rather than f64x2.
pub fn allWithin(points: []const Coordinate, limit: f64) bool {
    const V4 = @Vector(4, f64);
    const bound: V4 = @splat(limit);
    var i: usize = 0;
    while (i + 2 <= points.len) : (i += 2) {
        const v = V4{ points[i].x, points[i].y, points[i + 1].x, points[i + 1].y };
        if (!@reduce(.And, @abs(v) <= bound)) return false;
    }
    return i == points.len or within(points[i], limit);
}

/// Axis-aligned bounds. Every operation is a lane-wise minimum, maximum or
/// comparison, so a box test is two instructions and a reduce.
pub const Extent = struct {
    min: Coordinate,
    max: Coordinate,

    pub fn of(a: Coordinate, b: Coordinate) Extent {
        const u = vec(a);
        const v = vec(b);
        return .{ .min = coordinate(@min(u, v)), .max = coordinate(@max(u, v)) };
    }
    pub fn around(points: []const Coordinate) Extent {
        var low = vec(points[0]);
        var high = low;
        for (points[1..]) |p| {
            const v = vec(p);
            low = @min(low, v);
            high = @max(high, v);
        }
        return .{ .min = coordinate(low), .max = coordinate(high) };
    }
    pub fn merge(a: Extent, b: Extent) Extent {
        return .{ .min = coordinate(@min(vec(a.min), vec(b.min))), .max = coordinate(@max(vec(a.max), vec(b.max))) };
    }
    pub fn overlaps(a: Extent, b: Extent) bool {
        return @reduce(.And, vec(a.min) <= vec(b.max)) and @reduce(.And, vec(b.min) <= vec(a.max));
    }
    pub fn has(b: Extent, p: Coordinate) bool {
        const v = vec(p);
        return @reduce(.And, vec(b.min) <= v) and @reduce(.And, v <= vec(b.max));
    }
    pub fn span(b: Extent) Coordinate {
        return coordinate(vec(b.max) - vec(b.min));
    }
};

pub fn distance(a: Coordinate, b: Coordinate) f64 {
    const d = vec(b) - vec(a);
    return @sqrt(dot(d * d));
}

/// Squared distance from `p` to the segment `a`-`b`. Both dot products fold to a
/// multiply and a horizontal add.
pub fn distanceSquaredToSegment(a: Coordinate, b: Coordinate, p: Coordinate) f64 {
    const origin = vec(a);
    const along = vec(b) - origin;
    const to = vec(p) - origin;
    const length = dot(along * along);
    const t = if (length > 0) std.math.clamp(dot(to * along) / length, 0, 1) else 0;
    const gap = splat(t) * along - to;
    return dot(gap * gap);
}

pub fn distanceToSegment(a: Coordinate, b: Coordinate, p: Coordinate) f64 {
    return @sqrt(distanceSquaredToSegment(a, b, p));
}

pub fn validateLineString(c: LineString) !void {
    if (c.len < 2) return error.InvalidGeometry;
    if (!allWithin(c, std.math.floatMax(f64))) return error.NonFiniteCoordinate;
}

pub fn validateLinearRing(r: LinearRing) !void {
    if (r.len < 4 or !equal(r[0], r[r.len - 1])) return error.InvalidRing;
    if (!allWithin(r, std.math.floatMax(f64))) return error.NonFiniteCoordinate;
    // Repeated adjacent coordinates are legal in real parcel WKB. Operations
    // remove zero-length edges after quantization.
}

pub fn contains(r: LinearRing, p: Coordinate) bool {
    var inside = false;
    for (r[0 .. r.len - 1], r[1..]) |a, b| {
        if ((a.y > p.y) != (b.y > p.y)) {
            // Vertical edges need no arithmetic, avoiding overflow at large extents.
            const x = if (a.x == b.x) a.x else (b.x - a.x) * ((p.y - a.y) / (b.y - a.y)) + a.x;
            if (p.x < x) inside = !inside;
        }
    }
    return inside;
}

pub fn rectangle(a: std.mem.Allocator, min: Coordinate, max: Coordinate) !Polygon {
    const points = try a.alloc(Coordinate, 5);
    points[0..5].* = .{ min, .{ .x = max.x, .y = min.y }, max, .{ .x = min.x, .y = max.y }, min };
    const rings = try a.alloc(LinearRing, 1);
    rings[0] = points;
    return .{ .rings = rings };
}
