// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
const std = @import("std");
const geo = @import("root.zig");
const g = @import("geometry.zig");
const a = std.testing.allocator;

fn rect(x0: f64, y0: f64, x1: f64, y1: f64) [5]geo.Coordinate {
    return .{ .{ .x = x0, .y = y0 }, .{ .x = x1, .y = y0 }, .{ .x = x1, .y = y1 }, .{ .x = x0, .y = y1 }, .{ .x = x0, .y = y0 } };
}
fn area(polygons: []const geo.Polygon) f64 {
    var total: f64 = 0;
    for (polygons) |p| for (p.rings) |r| {
        for (r[0 .. r.len - 1], r[1..]) |u, v| total += (u.x * v.y - v.x * u.y) / 2;
    };
    return total;
}

test "WKB endian round trips, empty geometry, and every truncated prefix" {
    const r = rect(-2, 3, 4, 8);
    for ([_]std.builtin.Endian{ .big, .little }) |endian| {
        const bytes = try geo.wkb.write(a, &.{.{ .rings = &.{&r} }}, endian);
        defer a.free(bytes);
        var parsed = try geo.wkb.parse(a, bytes, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.polygons.len);
        try std.testing.expectEqualSlices(geo.Coordinate, &r, parsed.polygons[0].rings[0]);
        for (0..bytes.len) |n| {
            if (geo.wkb.parse(a, bytes[0..n], .{})) |value| {
                var unexpected = value;
                unexpected.deinit();
                return error.ExpectedParseFailure;
            } else |_| {}
        }
        try std.testing.expectError(error.LimitExceeded, geo.wkb.parse(a, bytes, .{ .max_points = 4 }));
        const trailing = try a.alloc(u8, bytes.len + 1);
        defer a.free(trailing);
        @memcpy(trailing[0..bytes.len], bytes);
        trailing[bytes.len] = 0;
        try std.testing.expectError(error.TrailingBytes, geo.wkb.parse(a, trailing, .{}));
    }
    const empty = try geo.wkb.write(a, &.{}, .little);
    defer a.free(empty);
    var parsed = try geo.wkb.parse(a, empty, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.polygons.len);
    // Standalone empty Polygon.
    var polygon = try geo.wkb.parse(a, &.{ 1, 3, 0, 0, 0, 0, 0, 0, 0 }, .{});
    defer polygon.deinit();
    try std.testing.expectEqual(@as(usize, 0), polygon.polygons[0].rings.len);
}

test "WKB rejects bad byte order, dimensions, counts, closure and nonfinite coordinates" {
    try std.testing.expectError(error.InvalidByteOrder, geo.wkb.parse(a, &.{2}, .{}));
    // Coordinate (1) is supported now, but truncated before its coordinates.
    try std.testing.expectError(error.TruncatedWkb, geo.wkb.parse(a, &.{ 1, 1, 0, 0, 0 }, .{}));
    // PolygonZ (0x80000003): Z/M and EWKB remain out of scope.
    try std.testing.expectError(error.UnsupportedGeometry, geo.wkb.parse(a, &.{ 1, 3, 0, 0, 128 }, .{}));
    try std.testing.expectError(error.UnsupportedGeometry, geo.wkb.parse(a, &.{ 1, 8, 0, 0, 0 }, .{}));
    try std.testing.expectError(error.LimitExceeded, geo.wkb.parse(a, &.{ 1, 6, 0, 0, 0, 255, 255, 255, 255 }, .{}));
    var r = rect(0, 0, 1, 1);
    r[4].x = 2;
    try std.testing.expectError(error.InvalidRing, geo.wkb.write(a, &.{.{ .rings = &.{&r} }}, .little));
    r = rect(0, 0, 1, 1);
    r[1].x = std.math.nan(f64);
    try std.testing.expectError(error.NonFiniteCoordinate, geo.wkb.write(a, &.{.{ .rings = &.{&r} }}, .little));
}

test "union overlap, containment, duplicates, disjoint, edge and point contacts" {
    const base = rect(0, 0, 2, 2);
    const cases = [_]struct { r: [5]geo.Coordinate, area: f64, count: usize }{
        .{ .r = rect(1, 1, 3, 3), .area = 7, .count = 1 },
        .{ .r = rect(0.5, 0.5, 1.5, 1.5), .area = 4, .count = 1 },
        .{ .r = base, .area = 4, .count = 1 },
        .{ .r = rect(3, 0, 4, 1), .area = 5, .count = 2 },
        .{ .r = rect(2, 0, 4, 2), .area = 8, .count = 1 },
        .{ .r = rect(2, 2, 4, 4), .area = 8, .count = 2 },
    };
    for (cases) |case| {
        var output = try geo.unionAll(a, &.{ .{ .rings = &.{&base} }, .{ .rings = &.{&case.r} } }, .{});
        defer output.deinit();
        try std.testing.expectEqual(case.count, output.polygons.len);
        try std.testing.expectEqual(case.area, area(output.polygons));
        var again = try geo.unionAll(a, output.polygons, .{});
        defer again.deinit();
        try std.testing.expectEqual(case.area, area(again.polygons));
    }
}

test "union preserves holes, fills holes, and constructs holes" {
    const outer = rect(0, 0, 4, 4);
    const hole = rect(1, 1, 3, 3);
    var donut = try geo.unionAll(a, &.{.{ .rings = &.{ &outer, &hole } }}, .{});
    defer donut.deinit();
    try std.testing.expectEqual(@as(f64, 12), area(donut.polygons));
    try std.testing.expectEqual(@as(usize, 2), donut.polygons[0].rings.len);
    var filled = try geo.unionAll(a, &.{ .{ .rings = &.{ &outer, &hole } }, .{ .rings = &.{&hole} } }, .{});
    defer filled.deinit();
    try std.testing.expectEqual(@as(f64, 16), area(filled.polygons));
    try std.testing.expectEqual(@as(usize, 1), filled.polygons[0].rings.len);
    const bottom = rect(0, 0, 4, 1);
    const top = rect(0, 3, 4, 4);
    const left = rect(0, 1, 1, 3);
    const right = rect(3, 1, 4, 3);
    var frame = try geo.unionAll(a, &.{ .{ .rings = &.{&bottom} }, .{ .rings = &.{&top} }, .{ .rings = &.{&left} }, .{ .rings = &.{&right} } }, .{});
    defer frame.deinit();
    try std.testing.expectEqual(@as(f64, 12), area(frame.polygons));
    try std.testing.expectEqual(@as(usize, 2), frame.polygons[0].rings.len);
}

test "union empty, reversed winding, sloped edges and limits" {
    var empty = try geo.unionAll(a, &.{}, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.polygons.len);
    var r = rect(0, 0, 2, 2);
    std.mem.reverse(geo.Coordinate, &r);
    var reversed = try geo.unionAll(a, &.{.{ .rings = &.{&r} }}, .{});
    defer reversed.deinit();
    try std.testing.expectEqual(@as(f64, 4), area(reversed.polygons));
    const triangle = [_]geo.Coordinate{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 0 } };
    var sloped = try geo.unionAll(a, &.{.{ .rings = &.{&triangle} }}, .{});
    defer sloped.deinit();
    try std.testing.expectEqual(@as(f64, 1), area(sloped.polygons));
    try std.testing.expectError(error.LimitExceeded, geo.unionAll(a, &.{.{ .rings = &.{&r} }}, .{ .limits = .{ .max_output_points = 0 } }));
    try std.testing.expectError(error.LimitExceeded, geo.unionAll(a, &.{.{ .rings = &.{&r} }}, .{ .limits = .{ .max_segments = 3 } }));
}

test "rounded rectangle buffer positive, zero, negative and collapse" {
    const r = rect(0, 0, 4, 4);
    for ([_]f64{ 1, 0, -1, -2, -3 }, [_]f64{ 32 + std.math.pi, 16, 4, 0, 0 }) |d, expected| {
        var output = try geo.buffer(a, .{ .polygons = &.{.{ .rings = &.{&r} }} }, d, .{});
        defer output.deinit();
        try std.testing.expectApproxEqAbs(expected, area(output.polygons), 0.01);
    }
    try std.testing.expectError(error.NonFiniteCoordinate, geo.buffer(a, .{ .polygons = &.{.{ .rings = &.{&r} }} }, std.math.inf(f64), .{}));
    try std.testing.expectError(error.InvalidOptions, geo.buffer(a, .{ .polygons = &.{.{ .rings = &.{&r} }} }, 1, .{ .quadrant_segments = 0 }));
}

fn allocationScenario(alloc: std.mem.Allocator) !void {
    const r = rect(0, 0, 4, 4);
    const s = rect(2, 2, 6, 6);
    const bytes = try geo.wkb.write(alloc, &.{ .{ .rings = &.{&r} }, .{ .rings = &.{&s} } }, .big);
    defer alloc.free(bytes);
    var input = try geo.wkb.parse(alloc, bytes, .{});
    defer input.deinit();
    var united = try geo.unionAll(alloc, input.polygons, .{});
    defer united.deinit();
    var buffered = try geo.buffer(alloc, .{ .polygons = &.{input.polygons[0]} }, 1, .{});
    defer buffered.deinit();
}
test "all Zig allocation failure paths release memory" {
    try std.testing.checkAllAllocationFailures(a, allocationScenario, .{});
}

test "random rectangle unions agree with integer-cell reference and are idempotent" {
    var random = std.Random.DefaultPrng.init(42);
    var accepted: usize = 0;
    for (0..100) |_| {
        var rings: [8][5]geo.Coordinate = undefined;
        var ring_slices: [8][1]geo.LinearRing = undefined;
        var polygons: [8]geo.Polygon = undefined;
        var cells: [100]bool = @splat(false);
        for (&rings, &ring_slices, &polygons) |*r, *rs, *p| {
            const x = random.random().uintLessThan(usize, 9);
            const y = random.random().uintLessThan(usize, 9);
            const x1 = x + 1 + random.random().uintLessThan(usize, 10 - x);
            const y1 = y + 1 + random.random().uintLessThan(usize, 10 - y);
            r.* = rect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(x1), @floatFromInt(y1));
            rs[0] = r;
            p.* = .{ .rings = rs };
            for (y..y1) |yy| for (x..x1) |xx| {
                cells[yy * 10 + xx] = true;
            };
        }
        var expected: f64 = 0;
        for (cells) |cell| {
            if (cell) expected += 1;
        }
        var output = try geo.unionAll(a, &polygons, .{});
        accepted += 1;
        defer output.deinit();
        try std.testing.expectEqual(expected, area(output.polygons));
        for (0..10) |y| for (0..10) |x| {
            const point: geo.Coordinate = .{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 };
            var actual = false;
            for (output.polygons) |p| {
                var inside = g.contains(p.rings[0], point);
                for (p.rings[1..]) |r| if (g.contains(r, point)) {
                    inside = false;
                };
                actual = actual or inside;
            }
            try std.testing.expectEqual(cells[y * 10 + x], actual);
        };
        var again = try geo.unionAll(a, output.polygons, .{});
        defer again.deinit();
        try std.testing.expectEqual(expected, area(again.polygons));
    }
    try std.testing.expectEqual(@as(usize, 100), accepted);
}

test "nested island holes belong to the innermost shell" {
    const outer = rect(0, 0, 10, 10);
    const lake = rect(1, 1, 9, 9);
    const island = rect(2, 2, 8, 8);
    const pond = rect(3, 3, 7, 7);
    var output = try geo.unionAll(a, &.{ .{ .rings = &.{ &outer, &lake } }, .{ .rings = &.{ &island, &pond } } }, .{});
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 2), output.polygons.len);
    for (output.polygons) |p| try std.testing.expectEqual(@as(usize, 2), p.rings.len);
    try std.testing.expectEqual(@as(f64, 56), area(output.polygons));
}

test "point contact between a shell and hole is supported" {
    // C shape closed by a rectangle that touches its upper arm at just one point.
    const bottom = rect(0, 0, 4, 1);
    const left = rect(0, 1, 1, 4);
    const top = rect(1, 3, 3, 4);
    const right = rect(3, 1, 4, 3);
    var output = try geo.unionAll(a, &.{
        .{ .rings = &.{&bottom} }, .{ .rings = &.{&left} },
        .{ .rings = &.{&top} },    .{ .rings = &.{&right} },
    }, .{});
    defer output.deinit();
    try std.testing.expectApproxEqAbs(@as(f64, 11), area(output.polygons), 1e-7);
}

test "mixed-endian child polygon and malformed coordinates" {
    const r = rect(0, 0, 2, 2);
    const bytes = try geo.wkb.write(a, &.{.{ .rings = &.{&r} }}, .big);
    defer a.free(bytes);
    // Only change MultiPolygon header to little endian; child remains big endian.
    bytes[0] = 1;
    std.mem.writeInt(u32, bytes[1..5], 6, .little);
    std.mem.writeInt(u32, bytes[5..9], 1, .little);
    var parsed = try geo.wkb.parse(a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualSlices(geo.Coordinate, &r, parsed.polygons[0].rings[0]);
    std.mem.writeInt(u64, bytes[22..30], @bitCast(std.math.inf(f64)), .big);
    // Closing vertex must also match to reach finite-coordinate validation.
    std.mem.writeInt(u64, bytes[86..94], @bitCast(std.math.inf(f64)), .big);
    try std.testing.expectError(error.NonFiniteCoordinate, geo.wkb.parse(a, bytes, .{}));
}

test "deterministic malformed WKB mutations never panic and valid parses round trip" {
    const r = rect(-1, -2, 3, 4);
    const source = try geo.wkb.write(a, &.{.{ .rings = &.{&r} }}, .little);
    defer a.free(source);
    const mutated = try a.dupe(u8, source);
    defer a.free(mutated);
    var prng = std.Random.DefaultPrng.init(123);
    for (0..2000) |_| {
        @memcpy(mutated, source);
        for (0..1 + prng.random().uintLessThan(usize, 8)) |_| {
            mutated[prng.random().uintLessThan(usize, mutated.len)] = prng.random().int(u8);
        }
        var parsed = geo.wkb.parse(a, mutated, .{}) catch continue;
        defer parsed.deinit();
        const encoded = try geo.wkb.write(a, parsed.polygons, .little);
        defer a.free(encoded);
        var reparsed = try geo.wkb.parse(a, encoded, .{});
        defer reparsed.deinit();
        try std.testing.expectEqual(parsed.polygons.len, reparsed.polygons.len);
        for (parsed.polygons, reparsed.polygons) |before, after| {
            try std.testing.expectEqual(before.rings.len, after.rings.len);
            for (before.rings, after.rings) |br, ar| try std.testing.expectEqualSlices(geo.Coordinate, br, ar);
        }
    }
}

test "adjacent floating coordinates are retained without quantization" {
    const r = rect(1, 0, 1 + std.math.floatEps(f64), 1);
    var output = try geo.unionAll(a, &.{.{ .rings = &.{&r} }}, .{});
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 1), output.polygons.len);
    try std.testing.expectEqual(std.math.floatEps(f64), area(output.polygons));
}

test "near-straight joints do not defeat noding at any distance" {
    // A parcel with two joints that turn by far less than one arc step. Building
    // a circular wedge at those produces a needle whose two long edges are a
    // hair apart, which used to break noding for every buffer distance at or
    // above about a quarter of the shortest edge.
    const parcel = [_]geo.Coordinate{
        .{ .x = 129.46164453019261, .y = -513.04699898387719 },
        .{ .x = 196.45229711585876, .y = -513.38103616221508 },
        .{ .x = 196.5520375997487, .y = -466.10840826468046 },
        .{ .x = 129.44365497322124, .y = -413.1847792053361 },
        .{ .x = 120.6598807263633, .y = -406.28039153675223 },
        .{ .x = 120.43539069099074, .y = -513.00208133496892 },
        .{ .x = 129.46164453019261, .y = -513.04699898387719 },
    };
    const reference = @abs(area(&.{.{ .rings = &.{&parcel} }}));
    for ([_]f64{ 1, 2, 5, 8, 9, 10, 11, 20 }) |distance| {
        var grown = try geo.buffer(a, .{ .polygons = &.{.{ .rings = &.{&parcel} }} }, distance, .{});
        defer grown.deinit();
        var shrunk = try geo.buffer(a, .{ .polygons = &.{.{ .rings = &.{&parcel} }} }, -distance, .{});
        defer shrunk.deinit();
        try std.testing.expectEqual(@as(usize, 1), grown.polygons.len);
        // Growing and shrinking bracket the original area, monotonically.
        try std.testing.expect(@abs(area(grown.polygons)) > reference);
        try std.testing.expect(@abs(area(shrunk.polygons)) < reference);
    }
}

test "a needle triangle buffers to the same region as its long axis" {
    // Reduced from parcel row 3933: three nearly collinear points enclosing
    // 2e-4 square metres. Every joint is below one arc step, so the whole band
    // is mitred and no wedge is emitted.
    const needle = [_]geo.Coordinate{
        .{ .x = 300.5074814349739, .y = -774.57112440553669 },
        .{ .x = 329.7537142148982, .y = -774.69200052758913 },
        .{ .x = 330.40332934209022, .y = -774.6946854317498 },
        .{ .x = 300.5074814349739, .y = -774.57112440553669 },
    };
    var output = try geo.buffer(a, .{ .polygons = &.{.{ .rings = &.{&needle} }} }, 2, .{});
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 1), output.polygons.len);
    // A 29.9 m axis swept by a 2 m disc: two flanks plus two end caps.
    try std.testing.expectApproxEqAbs(@as(f64, 29.9 * 4 + std.math.pi * 4), @abs(area(output.polygons)), 0.5);
}

fn wkb(list: *std.ArrayList(u8), kind: u32, count: ?u32) !void {
    try list.append(a, 1);
    var head: [4]u8 = undefined;
    std.mem.writeInt(u32, &head, kind, .little);
    try list.appendSlice(a, &head);
    if (count) |n| {
        std.mem.writeInt(u32, &head, n, .little);
        try list.appendSlice(a, &head);
    }
}
fn wkbPoint(list: *std.ArrayList(u8), x: f64, y: f64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(x), .little);
    try list.appendSlice(a, &bytes);
    std.mem.writeInt(u64, &bytes, @bitCast(y), .little);
    try list.appendSlice(a, &bytes);
}

test "WKB parses every 2D OGC type, including nested collections" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);

    try wkb(&bytes, 1, null);
    try wkbPoint(&bytes, 3, 4);
    var parsed = try geo.wkb.parse(a, bytes.items, .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.points.len);
    try std.testing.expectEqual(geo.Coordinate{ .x = 3, .y = 4 }, parsed.points[0]);
    parsed.deinit();

    bytes.clearRetainingCapacity();
    try wkb(&bytes, 2, 3);
    try wkbPoint(&bytes, 0, 0);
    try wkbPoint(&bytes, 1, 0);
    try wkbPoint(&bytes, 1, 1);
    parsed = try geo.wkb.parse(a, bytes.items, .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.line_strings.len);
    try std.testing.expectEqual(@as(usize, 3), parsed.line_strings[0].len);
    parsed.deinit();

    bytes.clearRetainingCapacity();
    try wkb(&bytes, 4, 2);
    try wkb(&bytes, 1, null);
    try wkbPoint(&bytes, 0, 0);
    try wkb(&bytes, 1, null);
    try wkbPoint(&bytes, 5, 0);
    parsed = try geo.wkb.parse(a, bytes.items, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.points.len);
    parsed.deinit();

    // A collection holding a point, a line and a nested collection.
    bytes.clearRetainingCapacity();
    try wkb(&bytes, 7, 3);
    try wkb(&bytes, 1, null);
    try wkbPoint(&bytes, 0, 0);
    try wkb(&bytes, 2, 2);
    try wkbPoint(&bytes, 2, 0);
    try wkbPoint(&bytes, 3, 0);
    try wkb(&bytes, 7, 1);
    try wkb(&bytes, 1, null);
    try wkbPoint(&bytes, 9, 9);
    parsed = try geo.wkb.parse(a, bytes.items, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.points.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.line_strings.len);
    parsed.deinit();

    // Trailing bytes are still rejected, and so is a runaway nest.
    try bytes.append(a, 0);
    try std.testing.expectError(error.TrailingBytes, geo.wkb.parse(a, bytes.items, .{}));
    bytes.clearRetainingCapacity();
    for (0..40) |_| try wkb(&bytes, 7, 1);
    try wkb(&bytes, 1, null);
    try wkbPoint(&bytes, 0, 0);
    try std.testing.expectError(error.LimitExceeded, geo.wkb.parse(a, bytes.items, .{}));
}

test "buffer accepts empty polygons and lines with repeated coordinates" {
    // Found by the JTS-shaped review, not by the suite: both are legal input
    // that real WKB contains, and both used to fail.
    var empty = try geo.buffer(a, .{ .polygons = &.{.{ .rings = &.{} }} }, 1, .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.polygons.len);

    // `geometry.zig` documents repeated adjacent coordinates as legal. Rings
    // were de-duplicated by `normalize`; lines reached `offsetOf` with a
    // zero-length segment and came back `error.PrecisionLoss`.
    const clean = [_]geo.Coordinate{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 1 } };
    var reference = try geo.buffer(a, .{ .line_strings = &.{&clean} }, 1, .{});
    defer reference.deinit();
    const expected = area(reference.polygons);

    const repeated = [_][]const geo.Coordinate{
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 1 } },
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 1 } },
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 1 } },
    };
    for (repeated) |line| {
        var out = try geo.buffer(a, .{ .line_strings = &.{line} }, 1, .{});
        defer out.deinit();
        try std.testing.expectApproxEqAbs(expected, area(out.polygons), 1e-9);
    }
}

test "a closed line buffers to a band around its ring, either winding" {
    // The JTS suite's "Closed Line" case, and its counter-clockwise twin. A
    // closed line is ring linework: the band is an annulus until the distance
    // is wide enough to swallow the middle.
    const clockwise = [_]geo.Coordinate{ .{ .x = 1, .y = 9 }, .{ .x = 9, .y = 9 }, .{ .x = 9, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 9 } };
    const counter = [_]geo.Coordinate{ .{ .x = 1, .y = 9 }, .{ .x = 1, .y = 1 }, .{ .x = 9, .y = 1 }, .{ .x = 9, .y = 9 }, .{ .x = 1, .y = 9 } };
    for ([_][]const geo.Coordinate{ &clockwise, &counter }) |line| {
        var thin = try geo.buffer(a, .{ .line_strings = &.{line} }, 1, .{ .quadrant_segments = 8 });
        defer thin.deinit();
        try std.testing.expectEqual(@as(usize, 1), thin.polygons.len);
        // Shell plus the hole the middle still leaves.
        try std.testing.expectEqual(@as(usize, 2), thin.polygons[0].rings.len);
        try std.testing.expectApproxEqAbs(@as(f64, 63.1214), area(thin.polygons), 1e-3);

        var wide = try geo.buffer(a, .{ .line_strings = &.{line} }, 10, .{ .quadrant_segments = 8 });
        defer wide.deinit();
        try std.testing.expectEqual(@as(usize, 1), wide.polygons.len);
        // Wide enough to close the middle, so the hole is gone.
        try std.testing.expectEqual(@as(usize, 1), wide.polygons[0].rings.len);
        try std.testing.expectApproxEqAbs(@as(f64, 696.1445), area(wide.polygons), 1e-3);

        // A line encloses no area, so there is nothing to erode.
        var eroded = try geo.buffer(a, .{ .line_strings = &.{line} }, -1, .{});
        defer eroded.deinit();
        try std.testing.expectEqual(@as(usize, 0), eroded.polygons.len);
    }
}

test "buffering a point is a disc and buffering a line is a stadium" {
    const radius = 10.0;
    const disc = std.math.pi * radius * radius;
    var dot = try geo.buffer(a, .{ .points = &.{.{ .x = 7, .y = -3 }} }, radius, .{});
    defer dot.deinit();
    try std.testing.expectEqual(@as(usize, 1), dot.polygons.len);
    // A 64-gon inscribed in the circle, so a little under the true area.
    try std.testing.expectApproxEqAbs(disc, @abs(area(dot.polygons)), disc * 0.01);

    const chain = [_]geo.Coordinate{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 } };
    var stadium = try geo.buffer(a, .{ .line_strings = &.{&chain} }, radius, .{});
    defer stadium.deinit();
    try std.testing.expectEqual(@as(usize, 1), stadium.polygons.len);
    const expected = 2 * radius * 100 + disc;
    try std.testing.expectApproxEqAbs(expected, @abs(area(stadium.polygons)), expected * 0.01);

    // Nothing zero-dimensional or one-dimensional survives an erosion.
    var eroded = try geo.buffer(a, .{
        .points = &.{.{ .x = 7, .y = -3 }},
        .line_strings = &.{&chain},
    }, -radius, .{});
    defer eroded.deinit();
    try std.testing.expectEqual(@as(usize, 0), eroded.polygons.len);

    // A point inside a polygon's own buffer adds nothing; one outside does.
    const square = rect(0, 0, 4, 4);
    var mixed = try geo.buffer(a, .{
        .polygons = &.{.{ .rings = &.{&square} }},
        .points = &.{.{ .x = 2, .y = 2 }},
    }, 1, .{});
    defer mixed.deinit();
    try std.testing.expectEqual(@as(usize, 1), mixed.polygons.len);
    try std.testing.expectApproxEqAbs(@as(f64, 32 + std.math.pi), @abs(area(mixed.polygons)), 0.02);
}

fn block(counts: geo.flat.Counts, coords: []const f64, ends: []const u32) ![]align(8) u8 {
    const bytes = try a.alignedAlloc(u8, .@"8", try geo.flat.size(counts));
    @memcpy(bytes[0 .. coords.len * 8], std.mem.sliceAsBytes(coords));
    @memcpy(bytes[coords.len * 8 ..][0 .. ends.len * 4], std.mem.sliceAsBytes(ends));
    return bytes;
}

test "flat blocks carry polygons, line strings and points without copying coordinates" {
    // A square with a hole, a two-coordinate LineString, and a Point.
    const counts: geo.flat.Counts = .{ .coordinates = 13, .rings = 2, .polygons = 1, .line_strings = 1, .points = 1 };
    const coords = [_]f64{
        9, 9, // Point
        0, 0, 4, 0, // line
        0, 0, 10, 0, 10, 10, 0, 10, 0, 0, // shell
        3, 3, 3, 7, 7, 7, 7, 3, 3, 3, // hole
    };
    const ends = [_]u32{ 8, 13, 2, 3 }; // ring ends, then polygon ends, then line-string ends
    const bytes = try block(counts, &coords, &ends);
    defer a.free(bytes);

    const view = try geo.flat.view(bytes, counts);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const input = try geo.flat.input(arena.allocator(), view);
    try std.testing.expectEqual(@as(usize, 1), input.points.len);
    try std.testing.expectEqual(geo.Coordinate{ .x = 9, .y = 9 }, input.points[0]);
    try std.testing.expectEqual(@as(usize, 1), input.line_strings.len);
    try std.testing.expectEqual(@as(usize, 2), input.line_strings[0].len);
    try std.testing.expectEqual(@as(usize, 1), input.polygons.len);
    try std.testing.expectEqual(@as(usize, 2), input.polygons[0].rings.len);
    // Borrowed, not copied: the ring points into the block itself.
    try std.testing.expectEqual(@intFromPtr(bytes.ptr) + 3 * 16, @intFromPtr(input.polygons[0].rings[0].ptr));

    var out = try geo.buffer(a, input, 0, .{});
    defer out.deinit();
    const written = try geo.flat.output(a, out.polygons);
    defer a.free(written.bytes);
    // Square minus hole, and the round trip preserves shell-then-hole order.
    try std.testing.expectEqual(@as(u32, 1), written.counts.polygons);
    try std.testing.expectEqual(@as(u32, 2), written.counts.rings);
    const back = try geo.flat.view(written.bytes, written.counts);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const again = try geo.flat.input(scratch.allocator(), back);
    try std.testing.expectEqual(@as(f64, 84), @abs(area(again.polygons)));
}

test "flat blocks reject indices that run backwards, overlap or fall short" {
    const counts: geo.flat.Counts = .{ .coordinates = 5, .rings = 1, .polygons = 1 };
    const coords = [_]f64{ 0, 0, 1, 0, 1, 1, 0, 1, 0, 0 };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_][2]u32{
        .{ 6, 1 }, // ring end past the coordinates
        .{ 0, 1 }, // empty ring
        .{ 4, 1 }, // ring stops short, leaving an orphan coordinate
        .{ 5, 2 }, // polygon end past the ring count
        .{ 5, 0 }, // empty polygon
    }) |ends| {
        const bytes = try block(counts, &coords, &ends);
        defer a.free(bytes);
        const view = try geo.flat.view(bytes, counts);
        try std.testing.expect(std.meta.isError(geo.flat.input(arena.allocator(), view)));
    }
    // A block shorter than its own counts is refused before anything is read.
    const short = try a.alignedAlloc(u8, .@"8", 8);
    defer a.free(short);
    try std.testing.expectError(error.MalformedGeometry, geo.flat.view(short, counts));
}

test "the four boolean operations over two overlapping squares" {
    const left = rect(0, 0, 2, 2);
    const right = rect(1, 1, 3, 3);
    const subject: []const geo.Polygon = &.{.{ .rings = &.{&left} }};
    const clip: []const geo.Polygon = &.{.{ .rings = &.{&right} }};
    for ([_]struct { mode: geo.Mode, area: f64, polygons: usize }{
        .{ .mode = .union_all, .area = 7, .polygons = 1 },
        .{ .mode = .intersection, .area = 1, .polygons = 1 },
        .{ .mode = .difference, .area = 3, .polygons = 1 },
        .{ .mode = .symmetric_difference, .area = 6, .polygons = 2 },
    }) |case| {
        var out = try geo.boolean(a, subject, clip, case.mode, .{});
        defer out.deinit();
        try std.testing.expectEqual(case.area, area(out.polygons));
        try std.testing.expectEqual(case.polygons, out.polygons.len);
    }
    // Difference is the asymmetric one: swapping the operands changes it.
    var flipped = try geo.boolean(a, clip, subject, .difference, .{});
    defer flipped.deinit();
    try std.testing.expectEqual(@as(f64, 3), area(flipped.polygons));
    // An empty clip leaves the subject alone under union and difference.
    for ([_]geo.Mode{ .union_all, .difference, .symmetric_difference }) |mode| {
        var alone = try geo.boolean(a, subject, &.{}, mode, .{});
        defer alone.deinit();
        try std.testing.expectEqual(@as(f64, 4), area(alone.polygons));
    }
    var nothing = try geo.boolean(a, subject, &.{}, .intersection, .{});
    defer nothing.deinit();
    try std.testing.expectEqual(@as(usize, 0), nothing.polygons.len);
}

test "boolean operations on a polygon with a hole and a disjoint clip" {
    const outer = rect(0, 0, 10, 10);
    const hole = rect(3, 3, 7, 7);
    const donut: []const geo.Polygon = &.{.{ .rings = &.{ &outer, &hole } }};
    // A bar crossing the donut, through the hole.
    const bar = rect(-1, 4, 11, 6);
    const clip: []const geo.Polygon = &.{.{ .rings = &.{&bar} }};
    var cut = try geo.boolean(a, donut, clip, .difference, .{});
    defer cut.deinit();
    // 100 - 16 for the hole, less the bar's overlap with the ring: the bar
    // spans y in [4,6] over x in [0,10] but the hole already removed x in [3,7].
    try std.testing.expectEqual(@as(f64, 84 - (10 * 2 - 4 * 2)), area(cut.polygons));
    var shared = try geo.boolean(a, donut, clip, .intersection, .{});
    defer shared.deinit();
    try std.testing.expectEqual(@as(f64, 10 * 2 - 4 * 2), area(shared.polygons));
    try std.testing.expectEqual(@as(usize, 2), shared.polygons.len);
}

test "buffers the sweep's own labelling cannot close fall back to the graph pass" {
    // Each of these returned NodingFailure until `sweep.execute` learned to
    // retry with the graph labelling. The expected areas are GEOS's, which the
    // retry now reproduces to well inside the tolerance below.
    const low = rect(0, 0, 2, 1);
    const high = rect(2, 2, 3, 3);
    var low_rings = [_]geo.LinearRing{&low};
    var high_rings = [_]geo.LinearRing{&high};
    const pair = [_]geo.Polygon{ .{ .rings = &low_rings }, .{ .rings = &high_rings } };
    for ([_]struct { steps: u32, expected: f64 }{
        .{ .steps = 1, .expected = 16.0 },
        .{ .steps = 16, .expected = 17.704822735818908 },
    }) |case| {
        var out = try geo.buffer(a, .{ .polygons = &pair }, 1.0, .{ .quadrant_segments = case.steps });
        defer out.deinit();
        try std.testing.expectApproxEqAbs(case.expected, area(out.polygons), 1e-9);
    }

    // An L narrower than twice the erosion distance everywhere: GEOS erodes it
    // away entirely, and so must this.
    const ell = [_]geo.Coordinate{
        .{ .x = 1, .y = 0 }, .{ .x = 3, .y = 0 }, .{ .x = 3, .y = 3 }, .{ .x = 0, .y = 3 },
        .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 0 },
    };
    var ell_rings = [_]geo.LinearRing{&ell};
    const shape = [_]geo.Polygon{.{ .rings = &ell_rings }};
    var eroded = try geo.buffer(a, .{ .polygons = &shape }, -1.25, .{ .quadrant_segments = 16 });
    defer eroded.deinit();
    try std.testing.expectEqual(@as(usize, 0), eroded.polygons.len);
}

test "a self-crossing closed line buffers once the arrangement is noded again" {
    // A figure eight: zero signed area, and the two offset curves cross at a
    // point that rounding puts on neither of them. One sweep cannot node that,
    // so this returned NodingFailure until `execute` learned to sweep its own
    // arrangement a second time. GEOS: one polygon with two holes, area
    // 4.2689251551415985.
    const eight = [_]geo.Coordinate{
        .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 },
        .{ .x = 0, .y = 2 }, .{ .x = 0, .y = 0 },
    };
    var lines = [_]geo.LineString{&eight};
    var out = try geo.buffer(a, .{ .line_strings = &lines }, 0.25, .{});
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 1), out.polygons.len);
    try std.testing.expectEqual(@as(usize, 3), out.polygons[0].rings.len);
    try std.testing.expectApproxEqAbs(4.2689251551415985, area(out.polygons), 1e-9);
}
