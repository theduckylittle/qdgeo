// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Offset curves, built the way JTS and GEOS build them.
//!
//! One raw, possibly self-intersecting curve per ring, per line and per point,
//! handed to the overlay whole. The overlay resolves the self-intersections by
//! winding depth: a point is in the buffer exactly where the curves wind it at
//! least once, which is JTS's `depth(RIGHT) >= 1 && depth(LEFT) <= 0`.
//!
//! This replaced a decomposition into one quad per edge plus one sector per
//! joint. That decomposition could not represent a point or a line at all — it
//! unioned its input and then banded the boundary of the result — and it handed
//! the overlay a pile of mutually overlapping pieces carrying no information:
//! 10,857 closed paths for a single 19,208-coordinate parcel. See
//! `docs/BUFFER_APPROACH.md`. The construction here is not an explosion: that
//! same parcel yields 7 curves and 32,031 segments, 1.67x its input.
//!
//! The constants are JTS's, and they are not decoration: every one of them
//! guards a case where the exact construction produces geometry too fine to
//! node. They are tolerances on an approximation that already has one — the
//! polygonal arcs — and never on a predicate.
const std = @import("std");
const g = @import("geometry.zig");
const pred = @import("predicates.zig");

/// Douglas-Peucker-ish input simplification, as a fraction of the distance.
/// Collapse an outside turn whose two offset points are this close.
const separation_factor = 1.0e-3;
/// Snap an inside turn whose offset points are this close.
const inside_turn_snap_factor = 1.0e-3;
/// Minimum spacing between emitted curve vertices.
const vertex_snap_factor = 1.0e-6;
/// Inside-turn closing segments are this fraction of the way to the vertex.
const closing_segment_factor = 80.0;
/// Sampling stride when checking that a whole span is shallow.
const sampled_checks = 10;

pub const Style = struct {
    quadrant_segments: u32 = 16,
    /// Input simplification tolerance as a fraction of the distance. JTS and
    /// GEOS default this to 0.01 because their noder needs the help; measured
    /// here it costs up to 0.01 * distance of accuracy and buys nothing, so it
    /// is off. Raise it only if a workload cannot be noded otherwise.
    simplify_factor: f64 = 0,
};

/// Which side of the direction of travel the curve is offset to. Rings arrive
/// with the interior on the left, so `.right` grows and `.left` erodes.
pub const Side = enum { left, right };

/// Drop shallow concavities, JTS's `BufferInputLineSimplifier`. Only vertices
/// that turn *into* the offset side are candidates, so simplification can shrink
/// a concavity the curve could not have resolved but never clips a convexity the
/// buffer is supposed to show. A negative tolerance selects the other side.
pub fn simplify(a: std.mem.Allocator, line: []const g.Coordinate, tolerance: f64) ![]const g.Coordinate {
    if (line.len < 3 or !(@abs(tolerance) > 0)) return line;
    const limit = @abs(tolerance);
    const wanted: i2 = if (tolerance < 0) -1 else 1;
    const deleted = try a.alloc(bool, line.len);
    @memset(deleted, false);

    var changed = true;
    while (changed) {
        changed = false;
        var index: usize = 0;
        var middle = nextKept(deleted, index);
        var last = nextKept(deleted, middle);
        while (last < line.len) {
            if (deletable(line, index, middle, last, limit, wanted)) {
                deleted[middle] = true;
                changed = true;
                index = last;
            } else index = middle;
            middle = nextKept(deleted, index);
            last = nextKept(deleted, middle);
        }
    }

    var out: std.ArrayList(g.Coordinate) = .empty;
    for (line, deleted) |p, gone| {
        if (!gone) try out.append(a, p);
    }
    if (out.items.len < 3) return line;
    return out.toOwnedSlice(a);
}

fn nextKept(deleted: []const bool, from: usize) usize {
    var next = from + 1;
    while (next < deleted.len and deleted[next]) next += 1;
    return next;
}

fn deletable(line: []const g.Coordinate, first: usize, middle: usize, last: usize, limit: f64, wanted: i2) bool {
    const p0 = line[first];
    const p1 = line[middle];
    const p2 = line[last];
    if (pred.orient(p0, p1, p2) != wanted) return false;
    if (g.distanceSquaredToSegment(p0, p2, p1) >= limit * limit) return false;
    // The chord has to clear every vertex it would swallow, not just the middle
    // one, or a long shallow bay collapses into a straight line.
    const stride = @max(1, (last - first) / sampled_checks);
    var i = first;
    while (i < last) : (i += stride) {
        if (g.distanceSquaredToSegment(p0, p2, line[i]) >= limit * limit) return false;
    }
    return true;
}

const Builder = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(g.Coordinate) = .empty,
    radius: f64,
    quantum: f64,
    min_vertex: f64,
    side: Side = .left,
    s0: g.Coordinate = undefined,
    s1: g.Coordinate = undefined,
    s2: g.Coordinate = undefined,
    offset0: [2]g.Coordinate = undefined,
    offset1: [2]g.Coordinate = undefined,

    fn init(a: std.mem.Allocator, radius: f64, style: Style) Builder {
        const quantum = std.math.pi / 2.0 / @as(f64, @floatFromInt(style.quadrant_segments));
        return .{ .a = a, .radius = radius, .quantum = quantum, .min_vertex = radius * vertex_snap_factor };
    }

    fn addPt(self: *Builder, p: g.Coordinate) !void {
        if (!g.finite(p)) return error.CoordinateRange;
        if (self.out.items.len != 0 and g.distance(self.out.items[self.out.items.len - 1], p) < self.min_vertex) return;
        try self.out.append(self.a, p);
    }

    fn closeRing(self: *Builder) !void {
        if (self.out.items.len == 0) return;
        const first = self.out.items[0];
        if (g.equal(self.out.items[self.out.items.len - 1], first)) return;
        try self.out.append(self.a, first);
    }

    fn offsetOf(p: g.Coordinate, q: g.Coordinate, side: Side, radius: f64) ![2]g.Coordinate {
        const dx = q.x - p.x;
        const dy = q.y - p.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (!(len > 0)) return error.PrecisionLoss;
        const sign: f64 = if (side == .left) 1 else -1;
        const ux = sign * radius * dx / len;
        const uy = sign * radius * dy / len;
        return .{
            .{ .x = p.x - uy, .y = p.y + ux },
            .{ .x = q.x - uy, .y = q.y + ux },
        };
    }

    fn arc(self: *Builder, centre: g.Coordinate, start: f64, end: f64, clockwise: bool) !void {
        const direction: f64 = if (clockwise) -1 else 1;
        const total = @abs(start - end);
        const steps: usize = @intFromFloat(@trunc(total / self.quantum + 0.5));
        if (steps < 1) return;
        const increment = total / @as(f64, @floatFromInt(steps));
        var swept: f64 = 0;
        while (swept < total) : (swept += increment) {
            const angle = start + direction * swept;
            try self.addPt(.{ .x = centre.x + self.radius * @cos(angle), .y = centre.y + self.radius * @sin(angle) });
        }
    }

    fn corner(self: *Builder, centre: g.Coordinate, from: g.Coordinate, to: g.Coordinate, clockwise: bool) !void {
        var start = std.math.atan2(from.y - centre.y, from.x - centre.x);
        const end = std.math.atan2(to.y - centre.y, to.x - centre.x);
        if (clockwise) {
            if (start <= end) start += 2 * std.math.pi;
        } else {
            if (start >= end) start -= 2 * std.math.pi;
        }
        try self.addPt(from);
        try self.arc(centre, start, end, clockwise);
        try self.addPt(to);
    }

    fn circle(self: *Builder, centre: g.Coordinate) !void {
        try self.addPt(.{ .x = centre.x + self.radius, .y = centre.y });
        try self.arc(centre, 0, 2 * std.math.pi, false);
        try self.closeRing();
    }

    fn initSide(self: *Builder, s1: g.Coordinate, s2: g.Coordinate, side: Side) !void {
        self.s1 = s1;
        self.s2 = s2;
        self.side = side;
        self.offset1 = try offsetOf(s1, s2, side, self.radius);
    }

    fn addNext(self: *Builder, p: g.Coordinate, add_start: bool) !void {
        self.s0 = self.s1;
        self.s1 = self.s2;
        self.s2 = p;
        if (g.equal(self.s0, self.s1) or g.equal(self.s1, self.s2)) return;
        self.offset0 = try offsetOf(self.s0, self.s1, self.side, self.radius);
        self.offset1 = try offsetOf(self.s1, self.s2, self.side, self.radius);
        const turn = pred.orient(self.s0, self.s1, self.s2);
        if (turn == 0) return self.addCollinear();
        const outside = (turn < 0 and self.side == .left) or (turn > 0 and self.side == .right);
        if (outside) try self.addOutsideTurn(turn < 0, add_start) else try self.addInsideTurn();
    }

    fn addLast(self: *Builder) !void {
        try self.addPt(self.offset1[1]);
    }

    /// A straight-through vertex needs nothing; a doubling back needs a half
    /// turn around it.
    fn addCollinear(self: *Builder) !void {
        const back = (self.s2.x - self.s1.x) * (self.s1.x - self.s0.x) + (self.s2.y - self.s1.y) * (self.s1.y - self.s0.y);
        if (back >= 0) return;
        try self.corner(self.s1, self.offset0[1], self.offset1[0], true);
    }

    fn addOutsideTurn(self: *Builder, clockwise: bool, add_start: bool) !void {
        // Two offset points this close describe a joint below the resolution the
        // arcs promise. Emitting an arc between them makes a needle whose long
        // edges are near-coincident, which is what noding cannot survive.
        if (g.distance(self.offset0[1], self.offset1[0]) < self.radius * separation_factor) {
            try self.addPt(self.offset0[1]);
            return;
        }
        if (add_start) try self.addPt(self.offset0[1]);
        try self.corner(self.s1, self.offset0[1], self.offset1[0], clockwise);
        try self.addPt(self.offset1[0]);
    }

    fn addInsideTurn(self: *Builder) !void {
        if (crossing(self.offset0[0], self.offset0[1], self.offset1[0], self.offset1[1])) |p| {
            try self.addPt(p);
            return;
        }
        // A concavity narrower than the buffer: the offsets never meet. Close
        // the gap explicitly rather than let the curve run away, and keep the
        // closing segments short so they cannot reach past the vertex.
        if (g.distance(self.offset0[1], self.offset1[0]) < self.radius * inside_turn_snap_factor) {
            try self.addPt(self.offset0[1]);
            return;
        }
        try self.addPt(self.offset0[1]);
        try self.addPt(.{
            .x = (closing_segment_factor * self.offset0[1].x + self.s1.x) / (closing_segment_factor + 1),
            .y = (closing_segment_factor * self.offset0[1].y + self.s1.y) / (closing_segment_factor + 1),
        });
        try self.addPt(.{
            .x = (closing_segment_factor * self.offset1[0].x + self.s1.x) / (closing_segment_factor + 1),
            .y = (closing_segment_factor * self.offset1[0].y + self.s1.y) / (closing_segment_factor + 1),
        });
        try self.addPt(self.offset1[0]);
    }

    fn addCap(self: *Builder, p0: g.Coordinate, p1: g.Coordinate) !void {
        const left = try offsetOf(p0, p1, .left, self.radius);
        const right = try offsetOf(p0, p1, .right, self.radius);
        const angle = std.math.atan2(p1.y - p0.y, p1.x - p0.x);
        try self.addPt(left[1]);
        try self.arc(p1, angle + std.math.pi / 2.0, angle - std.math.pi / 2.0, true);
        try self.addPt(right[1]);
    }
};

/// Proper crossing only: a shared endpoint or a touch is the collinear case,
/// which the caller has already handled.
fn crossing(a: g.Coordinate, b: g.Coordinate, c: g.Coordinate, d: g.Coordinate) ?g.Coordinate {
    const first = pred.orient2(a, b, c, d);
    if (first[0] == 0 or first[1] == 0 or first[0] == first[1]) return null;
    const second = pred.orient2(c, d, a, b);
    if (second[0] == 0 or second[1] == 0 or second[0] == second[1]) return null;
    return pred.intersection(a, b, c, d);
}

/// Offset curve of a closed ring. `ring` must close and carry its interior on
/// the left, which is what `operations.normalize` guarantees.
pub fn ringCurve(a: std.mem.Allocator, ring: g.LinearRing, side: Side, radius: f64, style: Style) ![]const g.Coordinate {
    if (ring.len < 4) return lineCurve(a, ring, radius, style);
    const tolerance = radius * style.simplify_factor;
    const simple = try simplify(a, ring, if (side == .right) -tolerance else tolerance);
    const corners = simple.len - 1;
    if (corners < 3) return lineCurve(a, simple, radius, style);
    var builder = Builder.init(a, radius, style);
    try builder.initSide(simple[corners - 1], simple[0], side);
    for (1..corners + 1) |i| try builder.addNext(simple[i], i != 1);
    try builder.closeRing();
    return builder.out.toOwnedSlice(a);
}

/// Offset curve of an open chain: one side out, a cap, the other side back, a
/// cap, closed. A single point becomes a circle.
pub fn lineCurve(a: std.mem.Allocator, line: g.LineString, radius: f64, style: Style) ![]const g.Coordinate {
    var builder = Builder.init(a, radius, style);
    const tolerance = radius * style.simplify_factor;
    const forward = try simplify(a, line, tolerance);
    if (forward.len < 2 or degenerate(forward)) {
        try builder.circle(forward[0]);
        return builder.out.toOwnedSlice(a);
    }
    const last = forward.len - 1;
    try builder.initSide(forward[0], forward[1], .left);
    for (2..last + 1) |i| try builder.addNext(forward[i], true);
    try builder.addLast();
    try builder.addCap(forward[last - 1], forward[last]);

    const backward = try simplify(a, line, -tolerance);
    const end = backward.len - 1;
    try builder.initSide(backward[end], backward[end - 1], .left);
    var i = end;
    while (i >= 2) : (i -= 1) try builder.addNext(backward[i - 2], true);
    try builder.addLast();
    try builder.addCap(backward[1], backward[0]);
    try builder.closeRing();
    // JTS walks both sides on the left and labels the result interior-on-right.
    // Winding depth reads orientation instead, so the curve is handed back the
    // other way round: interior on the left, winding the buffer positively, the
    // same convention a grown ring curve already satisfies.
    const curve = try builder.out.toOwnedSlice(a);
    std.mem.reverse(g.Coordinate, curve);
    return curve;
}

pub fn pointCurve(a: std.mem.Allocator, centre: g.Coordinate, radius: f64, style: Style) ![]const g.Coordinate {
    var builder = Builder.init(a, radius, style);
    try builder.circle(centre);
    return builder.out.toOwnedSlice(a);
}

fn degenerate(line: []const g.Coordinate) bool {
    for (line[1..]) |p| {
        if (!g.equal(p, line[0])) return false;
    }
    return true;
}
