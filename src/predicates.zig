// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Adaptive 2D predicates. The fast determinant is filtered by its roundoff
//! bound; uncertain signs use error-free floating-point expansion arithmetic.
const g = @import("geometry.zig");
const std = @import("std");

const Expansion = struct {
    terms: [64]f64 = undefined,
    len: usize = 0,
    fn add(self: *Expansion, value: f64) void {
        var q = value;
        var n: usize = 0;
        for (self.terms[0..self.len]) |e| {
            const sum = q + e;
            const bv = sum - q;
            const error_term = (q - (sum - bv)) + (e - bv);
            if (error_term != 0) {
                self.terms[n] = error_term;
                n += 1;
            }
            q = sum;
        }
        if (q != 0 or n == 0) {
            self.terms[n] = q;
            n += 1;
        }
        self.len = n;
    }
    fn product(self: *Expansion, a: f64, b: f64, polarity: f64) void {
        const p = a * b;
        const tail = @mulAdd(f64, a, b, -p);
        self.add(tail * polarity);
        self.add(p * polarity);
    }
};
fn diff(a: f64, b: f64) [2]f64 {
    const x = a - b;
    const bv = a - x;
    return .{ (a - (x + bv)) + (bv - b), x };
}
fn sign(v: f64) i2 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

/// Shewchuk's roundoff bound for the filtered `orient2d` determinant.
const filter = 3.3306690738754716e-16;

pub fn orient(a: g.Coordinate, b: g.Coordinate, c: g.Coordinate) i2 {
    const origin = g.vec(c);
    const u = g.vec(a) - origin;
    const v = g.vec(b) - origin;
    // {ax, ay} * {by, bx} gives both halves of the cross product at once.
    const products = u * @shuffle(f64, v, undefined, [2]i32{ 1, 0 });
    const determinant = products[0] - products[1];
    if (@abs(determinant) > filter * @reduce(.Add, @abs(products))) return sign(determinant);
    // A degenerate triple is the overwhelmingly common filter failure on real
    // data: adjacent rings share vertices, so two of the three points are
    // bit-identical and the determinant is exactly zero. Two compares answer it.
    if (@reduce(.And, u == @as(g.V2, @splat(0))) or @reduce(.And, v == @as(g.V2, @splat(0))) or @reduce(.And, u == v)) {
        return 0;
    }
    var expansion: Expansion = .{};
    const ex = diff(a.x, c.x);
    const ey = diff(a.y, c.y);
    const fx = diff(b.x, c.x);
    const fy = diff(b.y, c.y);
    for (ex) |x| for (fy) |y| {
        expansion.product(x, y, 1);
    };
    for (ey) |y| for (fx) |x| {
        expansion.product(y, x, -1);
    };
    return sign(expansion.terms[expansion.len - 1]);
}

/// Two orientations sharing the base segment (a, b), filtered with one f64x2
/// determinant. Lanes whose roundoff filter fails fall back to the exact path.
/// `orient2(a, b, c, d) == .{ orient(a, b, c), orient(a, b, d) }`.
pub fn orient2(a: g.Coordinate, b: g.Coordinate, c: g.Coordinate, d: g.Coordinate) [2]i2 {
    const V = @Vector(2, f64);
    const bx: V = @splat(b.x - a.x);
    const by: V = @splat(b.y - a.y);
    const cx: V = .{ c.x - a.x, d.x - a.x };
    const cy: V = .{ c.y - a.y, d.y - a.y };
    const left = bx * cy;
    const right = by * cx;
    const determinant = left - right;
    const certain = @abs(determinant) > @as(V, @splat(filter)) * (@abs(left) + @abs(right));
    return .{
        if (certain[0]) sign(determinant[0]) else orient(a, b, c),
        if (certain[1]) sign(determinant[1]) else orient(a, b, d),
    };
}

/// Sign of the signed area, exactly, for the two callers that only ever ask
/// which way a ring winds. The `f128` accumulation those callers used costs two
/// `__multf3` libcalls per vertex — 25% of a union on 135,080 coordinates — and
/// the sign almost never needs that precision.
///
/// The `f64` sum carries a running bound on its own roundoff. Each term loses
/// at most four ulps to its two subtractions, its multiply and the difference,
/// and each of the `n` accumulation steps adds one more, so `(n + 4)` ulps of
/// the accumulated magnitude bounds the whole error; `floatEps` is 2^-52 where
/// the analysis needs 2^-53, so the bound applied is twice what is required.
/// A sum that bound cannot separate from zero falls back to `area`.
pub fn areaSign(ring: []const g.Coordinate) i2 {
    if (ring.len < 3) return 0;
    const o = ring[0];
    var sum: f64 = 0;
    var magnitude: f64 = 0;
    for (ring, 0..) |a, i| {
        const b = ring[(i + 1) % ring.len];
        const p = (a.x - o.x) * (b.y - o.y);
        const q = (a.y - o.y) * (b.x - o.x);
        sum += p - q;
        magnitude += @abs(p) + @abs(q);
    }
    const bound = @as(f64, @floatFromInt(ring.len + 4)) * std.math.floatEps(f64) * magnitude;
    // Non-finite intermediates make `bound` infinite or NaN, and both fail this
    // test, so an overflowing ring takes the exact path rather than a wrong sign.
    if (@abs(sum) > bound) return if (sum > 0) 1 else -1;
    const exact = area(ring);
    return if (exact > 0) 1 else if (exact < 0) -1 else 0;
}

pub fn area(ring: []const g.Coordinate) f128 {
    if (ring.len < 3) return 0;
    const o = ring[0];
    var sum: f128 = 0;
    for (ring, 0..) |a, i| {
        const b = ring[(i + 1) % ring.len];
        sum += (@as(f128, a.x) - o.x) * (@as(f128, b.y) - o.y) - (@as(f128, a.y) - o.y) * (@as(f128, b.x) - o.x);
    }
    return sum / 2;
}

/// Proper intersection: wide intermediates avoid cancellation in nearly parallel
/// segment parameter calculations. Endpoint/collinear cases are handled by noding.
pub fn intersection(a: g.Coordinate, b: g.Coordinate, c: g.Coordinate, d: g.Coordinate) g.Coordinate {
    const ax: f128 = a.x;
    const ay: f128 = a.y;
    const dx = @as(f128, b.x) - ax;
    const dy = @as(f128, b.y) - ay;
    const ex = @as(f128, d.x) - c.x;
    const ey = @as(f128, d.y) - c.y;
    const cx = @as(f128, c.x) - ax;
    const cy = @as(f128, c.y) - ay;
    const denominator = dx * ey - dy * ex;
    const t = (cx * ey - cy * ex) / denominator;
    const p: g.Coordinate = .{ .x = @floatCast(ax + t * dx), .y = @floatCast(ay + t * dy) };
    return .{
        .x = std.math.clamp(p.x, @max(@min(a.x, b.x), @min(c.x, d.x)), @min(@max(a.x, b.x), @max(c.x, d.x))),
        .y = std.math.clamp(p.y, @max(@min(a.y, b.y), @min(c.y, d.y)), @min(@max(a.y, b.y), @max(c.y, d.y))),
    };
}

test "area sign falls back to exact arithmetic when the filter cannot decide" {
    // A bowtie: the two lobes cancel exactly, so the filtered sum is zero while
    // the accumulated magnitude is not. Only the exact path can call this 0.
    const bowtie = [_]g.Coordinate{
        .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = 0 }, .{ .x = 0, .y = 4 }, .{ .x = 0, .y = 0 },
    };
    try std.testing.expectEqual(@as(i2, 0), areaSign(&bowtie));
    // Far from the origin, where the products are large and their difference small.
    const far = [_]g.Coordinate{
        .{ .x = 1e9, .y = 1e9 }, .{ .x = 1e9 + 1, .y = 1e9 }, .{ .x = 1e9 + 1, .y = 1e9 + 1 }, .{ .x = 1e9, .y = 1e9 + 1 }, .{ .x = 1e9, .y = 1e9 },
    };
    try std.testing.expectEqual(@as(i2, 1), areaSign(&far));
    var reversed = far;
    std.mem.reverse(g.Coordinate, &reversed);
    try std.testing.expectEqual(@as(i2, -1), areaSign(&reversed));
    // Agrees with the exact predicate wherever the exact predicate has a sign.
    for ([_][]const g.Coordinate{ &bowtie, &far, &reversed }) |ring| {
        const exact = area(ring);
        const expected: i2 = if (exact > 0) 1 else if (exact < 0) -1 else 0;
        try std.testing.expectEqual(expected, areaSign(ring));
    }
}

test "adaptive orientation detects a determinant lost to rounded products" {
    const a: g.Coordinate = .{ .x = 0, .y = 0 };
    const b: g.Coordinate = .{ .x = 1, .y = 1 + std.math.floatEps(f64) };
    const c: g.Coordinate = .{ .x = 1 - std.math.floatEps(f64), .y = 1 };
    try std.testing.expectEqual(@as(i2, 1), orient(a, b, c));
    try std.testing.expectEqual(@as(i2, -1), orient(a, c, b));
}

test "paired orientation matches the scalar predicate on filtered and exact lanes" {
    const a: g.Coordinate = .{ .x = 0, .y = 0 };
    const b: g.Coordinate = .{ .x = 1, .y = 1 + std.math.floatEps(f64) };
    const c: g.Coordinate = .{ .x = 1 - std.math.floatEps(f64), .y = 1 };
    const d: g.Coordinate = .{ .x = 3, .y = -4 };
    try std.testing.expectEqual([2]i2{ orient(a, b, c), orient(a, b, d) }, orient2(a, b, c, d));
    try std.testing.expectEqual([2]i2{ 0, 0 }, orient2(a, b, a, b));
}
