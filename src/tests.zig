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

test "the ABI separates a precision limit from malformed input" {
    // Status 7 is the one case where valid input fails — an arrangement f64
    // cannot hold — and a host must be able to tell it from status 5, which
    // means the input itself was bad. The split is a compatibility promise;
    // this pins it.
    const abi = @import("abi.zig");
    try std.testing.expectEqual(@as(u32, 7), abi.code(error.UnnodableCrossing));
    try std.testing.expectEqual(@as(u32, 5), abi.code(error.NodingFailure));
    try std.testing.expectEqual(@as(u32, 1), abi.code(error.OutOfMemory));
}

/// Polygon storage a `Collection` can borrow for the length of a test. A ring
/// slice handed to a struct literal in an argument list only lives for that
/// call, so the rings and polygons are held here instead.
const Shapes = struct {
    rings: [3]geo.LinearRing = undefined,
    polygons: [2]geo.Polygon = undefined,
    count: usize = 0,

    fn one(self: *Shapes, shell: []const geo.Coordinate) geo.Collection {
        self.rings[0] = shell;
        self.polygons[0] = .{ .rings = self.rings[0..1] };
        self.count = 1;
        return self.collection();
    }
    fn donut(self: *Shapes, shell: []const geo.Coordinate, hole: []const geo.Coordinate) geo.Collection {
        self.rings[0] = shell;
        self.rings[1] = hole;
        self.polygons[0] = .{ .rings = self.rings[0..2] };
        self.count = 1;
        return self.collection();
    }
    fn two(self: *Shapes, first: []const geo.Coordinate, second: []const geo.Coordinate) geo.Collection {
        self.rings[0] = first;
        self.rings[1] = second;
        self.polygons[0] = .{ .rings = self.rings[0..1] };
        self.polygons[1] = .{ .rings = self.rings[1..2] };
        self.count = 2;
        return self.collection();
    }
    fn collection(self: *const Shapes) geo.Collection {
        return .{ .polygons = self.polygons[0..self.count] };
    }
};

fn xy(x: f64, y: f64) geo.Coordinate {
    return .{ .x = x, .y = y };
}

// The overlay cases below are the reduced forms of failures a fuzz corpus of
// digitized-style polygons found in 1.1.0 (`tests/compare/fuzz.py`). Every
// one of them was a wrong answer handed back as a right one — invalid rings,
// or valid rings around the wrong region — and every expected area is GEOS's,
// which the exact-arithmetic adjudication in that script agrees with.

test "orient compares points, not rounded differences from the third" {
    // a and b are 5e-16 apart and 14 units from c, so a - c and b - c round
    // to the same pair. The shortcut for bit-identical points used to compare
    // those differences and call this triple collinear, and ring assembly then
    // dropped a vertex and the ring with it.
    const pred = @import("predicates.zig");
    try std.testing.expectEqual(@as(i2, 1), pred.orient(xy(0, -50), xy(-5e-16, -50), xy(10, -60)));
    try std.testing.expectEqual(@as(i2, -1), pred.orient(xy(-5e-16, -50), xy(0, -50), xy(10, -60)));
    try std.testing.expectEqual(@as(i2, 0), pred.orient(xy(0, -50), xy(0, -50), xy(10, -60)));
}

test "overlay: a closing tests the pair it brings together, not one an opening shifted into place" {
    // The segments that open at a point go in before the gap the closings
    // left is tested, and one opening below the gap moved every index above
    // it — so the gap test compared the wrong pair and two crossings were
    // never noded. The union came back self-intersecting, area 1077.44.
    const t1 = [_]geo.Coordinate{ xy(15, 90), xy(5, 45), xy(-5, -45), xy(15, 90) };
    const t2 = [_]geo.Coordinate{ xy(-30, 80), xy(-0.5555555555555556, 50.55555555555556), xy(35, 55), xy(-30, 80) };
    const t3 = [_]geo.Coordinate{ xy(-5, 50), xy(110, -60), xy(-0.5555555555555556, 50.55555555555556), xy(-5, 50) };
    var rings = [_]geo.LinearRing{ &t1, &t2, &t3 };
    const polygons = [_]geo.Polygon{ .{ .rings = rings[0..1] }, .{ .rings = rings[1..2] }, .{ .rings = rings[2..3] } };
    var out = try geo.unionAll(a, &polygons, .{});
    defer out.deinit();
    try std.testing.expectApproxEqAbs(1046.9292931260045, area(out.polygons), 1e-9);
}

test "overlay: windings are read again when a split lands on the point just swept" {
    // b's edge passes exactly through a's vertex (45, -10), which is only
    // found by the crossing tests after a's edges went in on top of it. They
    // kept the winding they read from it, and the intersection came back as
    // the whole of a, area 8.33.
    var sa: Shapes = .{};
    var sb: Shapes = .{};
    const ta = [_]geo.Coordinate{ xy(45, -10), xy(45, -6.666666666666667), xy(50, -10), xy(45, -10) };
    const tb = [_]geo.Coordinate{ xy(49.6, -5.4), xy(30, -25), xy(80, 140), xy(49.6, -5.4) };
    var out = try geo.boolean(a, sa.one(&ta).polygons, sb.one(&tb).polygons, .intersection, .{});
    defer out.deinit();
    try std.testing.expectApproxEqAbs(3.333333333333333, area(out.polygons), 1e-9);
}

test "overlay: openings that leave the queue out of order, and a vertex an ulp off a line" {
    // Two segments opening at a rounded crossing came out of the event heap
    // top first, and the vertex (-5.4e-16, -50) was then judged collinear by
    // `orient`. The difference came back empty.
    var sa: Shapes = .{};
    var sb: Shapes = .{};
    const ta = [_]geo.Coordinate{ xy(10, -60), xy(-6.521739130434782, -43.47826086956522), xy(-1.949685534591195, -38.490566037735846), xy(10, -60) };
    const tb = [_]geo.Coordinate{ xy(10, -50), xy(0, -50), xy(-60, -50), xy(10, 70), xy(10, -50) };
    var out = try geo.boolean(a, sa.one(&ta).polygons, sb.one(&tb).polygons, .difference, .{});
    defer out.deinit();
    try std.testing.expectApproxEqAbs(22.222222222222232, area(out.polygons), 1e-9);
}

test "overlay: a lost crossing between operands that would flip an edge is declined" {
    // b's edge passes within half an ulp of a's vertex (41, 9), so the
    // crossing rounds to a point before a's edge begins and a's edge is
    // inserted on the wrong side of b for its whole length. The difference
    // dropped the piece at (83, -16), area 434.80 against 678.87.
    var sa: Shapes = .{};
    var sb: Shapes = .{};
    const ta = [_]geo.Coordinate{ xy(1, 82), xy(41, 9), xy(83, -16), xy(1, 82) };
    const tb = [_]geo.Coordinate{ xy(75, 20), xy(49.296875, 5.3125), xy(-31.21951219512195, 41.09756097560975), xy(75, 20) };
    var out = try geo.boolean(a, sa.one(&ta).polygons, sb.one(&tb).polygons, .difference, .{});
    defer out.deinit();
    try std.testing.expectApproxEqAbs(678.8706444878115, area(out.polygons), 1e-9);
}

test "overlay: result edges that cross are declined, and the graph labelling is not asked" {
    // Dividing a segment rotates its supporting line by a rounding step, and
    // here that put a vertex the sweep had already passed on the other side
    // of it: a crossing behind the sweep line. The sweep labelling assembled
    // crossing rings, and the graph labelling, asked next, labelled an
    // arrangement with a crossing and no node in it. Both now decline and the
    // re-noding pass answers.
    const shell = [_]geo.Coordinate{ xy(-20, -130), xy(-160, -20), xy(-10, 110), xy(-20, -130) };
    const hole = [_]geo.Coordinate{ xy(-70, -10), xy(-80, 20), xy(-86.66666666666667, 6.666666666666667), xy(-70, -10) };
    const tri = [_]geo.Coordinate{ xy(-75, -10), xy(-85, 5), xy(40, 60), xy(-75, -10) };
    var rings = [_]geo.LinearRing{ &shell, &hole, &tri };
    const polygons = [_]geo.Polygon{ .{ .rings = rings[0..2] }, .{ .rings = rings[2..3] } };
    var out = try geo.unionAll(a, &polygons, .{});
    defer out.deinit();
    try std.testing.expectApproxEqAbs(17515.070399214415, area(out.polygons), 1e-9);

    // And where no pass can node it — a vertex within an ulp of the other
    // triangle's edge — the answer is the precision error, not invalid rings.
    const t1 = [_]geo.Coordinate{ xy(-40, 30), xy(-50, 50), xy(48.75, 48.75), xy(-40, 30) };
    const t2 = [_]geo.Coordinate{ xy(-50, 40), xy(-36.666666666666664, 26.666666666666668), xy(50, -70), xy(-50, 40) };
    var pair = [_]geo.LinearRing{ &t1, &t2 };
    const both = [_]geo.Polygon{ .{ .rings = pair[0..1] }, .{ .rings = pair[1..2] } };
    try std.testing.expectError(error.UnnodableCrossing, geo.unionAll(a, &both, .{}));
}

test "makeValid: JTS GeometryFixer's rules on hand-digitized mistakes" {
    // Expected areas are Shapely's make_valid(method='structure'), which
    // follows the same rules.
    const cases = [_]struct { ring: []const geo.Coordinate, expected: f64 }{
        // A bowtie keeps both lobes, whichever way each one turns.
        .{ .ring = &.{ xy(0, 0), xy(10, 10), xy(10, 0), xy(0, 5), xy(0, 0) }, .expected = 41.666666666666664 },
        // Two twists, three lobes.
        .{ .ring = &.{ xy(0, 0), xy(10, 10), xy(20, 0), xy(30, 10), xy(30, 0), xy(20, 10), xy(10, 0), xy(0, 10), xy(0, 0) }, .expected = 150 },
        // A loop that re-covers the body leaves no hole.
        .{ .ring = &.{ xy(0, 0), xy(10, 0), xy(10, 10), xy(4, 10), xy(4, 4), xy(14, 4), xy(14, 6), xy(2, 6), xy(2, 10), xy(0, 10), xy(0, 0) }, .expected = 100 },
        // Overshooting the closing vertex adds the overshoot.
        .{ .ring = &.{ xy(0, 0), xy(10, 0), xy(10, 10), xy(0, 10), xy(0, -2), xy(-1, -2), xy(-1, 0), xy(0, 0) }, .expected = 102 },
        // A spike, a ring traced twice, and a clockwise shell.
        .{ .ring = &.{ xy(0, 0), xy(10, 0), xy(10, 5), xy(14, 5), xy(12, 5), xy(10, 5), xy(10, 10), xy(0, 10), xy(0, 0) }, .expected = 100 },
        .{ .ring = &.{ xy(0, 0), xy(10, 0), xy(10, 10), xy(0, 10), xy(0, 0), xy(10, 0), xy(10, 10), xy(0, 10), xy(0, 0) }, .expected = 100 },
        .{ .ring = &.{ xy(0, 0), xy(0, 10), xy(10, 10), xy(10, 0), xy(0, 0) }, .expected = 100 },
        // Open, and with a vertex that is not a number: closed, and removed.
        .{ .ring = &.{ xy(0, 0), xy(10, 0), xy(10, 10), xy(0, 10) }, .expected = 100 },
        .{ .ring = &.{ xy(0, 0), xy(10, 0), xy(std.math.nan(f64), 3), xy(10, 10), xy(0, 10), xy(0, 0) }, .expected = 100 },
        // Collapsed to a line: nothing with area is left.
        .{ .ring = &.{ xy(0, 0), xy(5, 0), xy(10, 0), xy(0, 0) }, .expected = 0 },
    };
    for (cases) |case| {
        var s: Shapes = .{};
        var out = try geo.makeValid(a, s.one(case.ring).polygons, .{});
        defer out.deinit();
        try std.testing.expectApproxEqAbs(case.expected, area(out.polygons), 1e-9);
    }
}

test "makeValid: holes are repaired alone, cut where they meet the shell, kept where they do not" {
    const shell = rect(0, 0, 10, 10);
    const inner = rect(2, 2, 6, 6);
    const overlap = rect(4, 4, 8, 8);
    // The same square wound the other way. Holes swept together would let
    // the two cancel where they overlap; repaired one at a time, they cannot.
    const reversed = [_]geo.Coordinate{ xy(4, 4), xy(4, 8), xy(8, 8), xy(8, 4), xy(4, 4) };
    const outside = rect(20, 20, 22, 22);
    const across = rect(5, 5, 15, 8);
    const cases = [_]struct { holes: []const []const geo.Coordinate, expected: f64 }{
        .{ .holes = &.{ &inner, &overlap }, .expected = 72 },
        .{ .holes = &.{ &inner, &reversed }, .expected = 72 },
        .{ .holes = &.{&outside}, .expected = 104 },
        .{ .holes = &.{&across}, .expected = 85 },
    };
    for (cases) |case| {
        var rings: [3]geo.LinearRing = undefined;
        rings[0] = &shell;
        for (case.holes, 1..) |hole, k| rings[k] = hole;
        const polygon = [_]geo.Polygon{.{ .rings = rings[0 .. case.holes.len + 1] }};
        var out = try geo.makeValid(a, &polygon, .{});
        defer out.deinit();
        try std.testing.expectApproxEqAbs(case.expected, area(out.polygons), 1e-9);
    }

    // An island in a donut's hole is a second polygon, and survives the union.
    const ring = rect(0, 0, 10, 10);
    const hole = rect(2, 2, 8, 8);
    const island = rect(4, 4, 6, 6);
    var rings = [_]geo.LinearRing{ &ring, &hole, &island };
    const pair = [_]geo.Polygon{ .{ .rings = rings[0..2] }, .{ .rings = rings[2..3] } };
    var out = try geo.makeValid(a, &pair, .{});
    defer out.deinit();
    try std.testing.expectApproxEqAbs(68, area(out.polygons), 1e-9);
}

test "makeValid leaves valid polygons as they are" {
    var s: Shapes = .{};
    const shell = rect(0, 0, 10, 10);
    const hole = rect(2, 2, 6, 6);
    var out = try geo.makeValid(a, s.donut(&shell, &hole).polygons, .{});
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 1), out.polygons.len);
    try std.testing.expectEqual(@as(usize, 2), out.polygons[0].rings.len);
    try std.testing.expectApproxEqAbs(84, area(out.polygons), 1e-12);
}

test "relate: the matrix for the textbook polygon cases, in JTS's order" {
    const unit = rect(0, 0, 10, 10);
    const inner = rect(2, 2, 8, 8);
    const beside = rect(10, 0, 20, 10);
    const corner = rect(10, 10, 20, 20);
    const far = rect(30, 30, 40, 40);
    const overlap = rect(5, 5, 15, 15);
    var reversed = unit;
    std.mem.reverse(geo.Coordinate, &reversed);
    const cases = [_]struct { b: []const geo.Coordinate, expect: []const u8 }{
        .{ .b = &far, .expect = "FF2FF1212" },
        .{ .b = &beside, .expect = "FF2F11212" },
        .{ .b = &corner, .expect = "FF2F01212" },
        .{ .b = &overlap, .expect = "212101212" },
        .{ .b = &inner, .expect = "212FF1FF2" },
        .{ .b = &reversed, .expect = "2FFF1FFF2" },
        .{ .b = &unit, .expect = "2FFF1FFF2" },
    };
    var first: Shapes = .{};
    var second: Shapes = .{};
    const square = first.one(&unit);
    for (cases) |case| {
        const other = second.one(case.b);
        const m = try geo.relate(a, square, other, .{});
        try std.testing.expectEqualStrings(case.expect, &m.string());
        try std.testing.expect(try m.matches(case.expect));
        // The matrix and the early-exit path must agree.
        try std.testing.expectEqual(m.evaluate(.intersects), try geo.intersects(a, square, other, .{}));
    }
}

test "relate: lines and points against a polygon, and the named predicates" {
    const unit = rect(0, 0, 10, 10);
    var shapes: Shapes = .{};
    const square = shapes.one(&unit);
    const across = [_]geo.Coordinate{ .{ .x = -5, .y = 5 }, .{ .x = 15, .y = 5 } };
    const inside = [_]geo.Coordinate{ .{ .x = 2, .y = 2 }, .{ .x = 8, .y = 8 } };
    const along = [_]geo.Coordinate{ .{ .x = 0, .y = 2 }, .{ .x = 0, .y = 8 } };
    const touching = [_]geo.Coordinate{ .{ .x = -5, .y = 5 }, .{ .x = 0, .y = 5 } };
    const away = [_]geo.Coordinate{ .{ .x = 20, .y = 20 }, .{ .x = 30, .y = 20 } };

    var m = try geo.relate(a, square, .{ .line_strings = &.{&across} }, .{});
    try std.testing.expectEqualStrings("1F20F1102", &m.string());
    try std.testing.expect(m.evaluate(.crosses));
    try std.testing.expect(!m.evaluate(.contains));

    m = try geo.relate(a, square, .{ .line_strings = &.{&inside} }, .{});
    try std.testing.expectEqualStrings("102FF1FF2", &m.string());
    try std.testing.expect(m.evaluate(.contains));
    try std.testing.expect(m.evaluate(.covers));

    // A line along the boundary is covered but not contained: no interior
    // point. Its ends are boundary points sitting on the boundary.
    m = try geo.relate(a, square, .{ .line_strings = &.{&along} }, .{});
    try std.testing.expectEqualStrings("FF2101FF2", &m.string());
    try std.testing.expect(m.evaluate(.covers));
    try std.testing.expect(!m.evaluate(.contains));
    try std.testing.expect(m.evaluate(.touches));

    m = try geo.relate(a, square, .{ .line_strings = &.{&touching} }, .{});
    try std.testing.expectEqualStrings("FF2F01102", &m.string());
    try std.testing.expect(m.evaluate(.touches));
    try std.testing.expect(!m.evaluate(.crosses));

    m = try geo.relate(a, square, .{ .line_strings = &.{&away} }, .{});
    try std.testing.expectEqualStrings("FF2FF1102", &m.string());
    try std.testing.expect(m.evaluate(.disjoint));

    const centre: geo.Coordinate = .{ .x = 5, .y = 5 };
    const edge: geo.Coordinate = .{ .x = 10, .y = 5 };
    const vertex: geo.Coordinate = .{ .x = 10, .y = 10 };
    const outside: geo.Coordinate = .{ .x = 11, .y = 5 };
    try std.testing.expectEqualStrings("0F2FF1FF2", &(try geo.relate(a, square, .{ .points = &.{centre} }, .{})).string());
    try std.testing.expectEqualStrings("FF20F1FF2", &(try geo.relate(a, square, .{ .points = &.{edge} }, .{})).string());
    try std.testing.expectEqualStrings("FF20F1FF2", &(try geo.relate(a, square, .{ .points = &.{vertex} }, .{})).string());
    try std.testing.expectEqualStrings("FF2FF10F2", &(try geo.relate(a, square, .{ .points = &.{outside} }, .{})).string());
    try std.testing.expect(try geo.intersects(a, square, .{ .points = &.{edge} }, .{}));
    try std.testing.expect(!try geo.intersects(a, square, .{ .points = &.{outside} }, .{}));
    try std.testing.expect(try geo.predicate(a, square, .{ .points = &.{centre} }, .contains, .{}));
    try std.testing.expect(!try geo.predicate(a, square, .{ .points = &.{edge} }, .contains, .{}));
    try std.testing.expect(try geo.predicate(a, square, .{ .points = &.{edge} }, .covers, .{}));

    // Point against point, and against a line's interior and its end.
    try std.testing.expectEqualStrings("0FFFFFFF2", &(try geo.relate(a, .{ .points = &.{centre} }, .{ .points = &.{centre} }, .{})).string());
    try std.testing.expectEqualStrings("FF0FFF0F2", &(try geo.relate(a, .{ .points = &.{centre} }, .{ .points = &.{edge} }, .{})).string());
    try std.testing.expectEqualStrings("0FFFFF102", &(try geo.relate(a, .{ .points = &.{centre} }, .{ .line_strings = &.{&inside} }, .{})).string());
    try std.testing.expectEqualStrings("F0FFFF102", &(try geo.relate(a, .{ .points = &.{.{ .x = 2, .y = 2 }} }, .{ .line_strings = &.{&inside} }, .{})).string());
}

test "relate: a collection is read as a union" {
    // Two squares sharing an edge: a line along that edge is inside the pair,
    // and the pair as one operand covers a square spanning both.
    const left = rect(0, 0, 10, 10);
    const right = rect(10, 0, 20, 10);
    var shapes: Shapes = .{};
    var other: Shapes = .{};
    const pair = shapes.two(&left, &right);
    const seam = [_]geo.Coordinate{ .{ .x = 10, .y = 2 }, .{ .x = 10, .y = 8 } };
    var m = try geo.relate(a, pair, .{ .line_strings = &.{&seam} }, .{});
    try std.testing.expectEqualStrings("102FF1FF2", &m.string());
    try std.testing.expect(m.evaluate(.contains));
    const spanning = rect(5, 2, 15, 8);
    m = try geo.relate(a, pair, other.one(&spanning), .{});
    try std.testing.expectEqualStrings("212FF1FF2", &m.string());
    try std.testing.expect(m.evaluate(.contains));
    // The seam vertex (10, 10) is interior to neither alone but boundary of the union.
    try std.testing.expectEqualStrings("FF20F1FF2", &(try geo.relate(a, pair, .{ .points = &.{.{ .x = 10, .y = 10 }} }, .{})).string());
    try std.testing.expectEqualStrings("0F2FF1FF2", &(try geo.relate(a, pair, .{ .points = &.{.{ .x = 10, .y = 5 }} }, .{})).string());

    // Two lines meeting end to end have no boundary at the meeting point.
    const one = [_]geo.Coordinate{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 } };
    const two = [_]geo.Coordinate{ .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 0 } };
    const chain: geo.Collection = .{ .line_strings = &.{ &one, &two } };
    try std.testing.expectEqualStrings("0FFFFF102", &(try geo.relate(a, .{ .points = &.{.{ .x = 5, .y = 0 }} }, chain, .{})).string());
    try std.testing.expectEqualStrings("F0FFFF102", &(try geo.relate(a, .{ .points = &.{.{ .x = 0, .y = 0 }} }, chain, .{})).string());

    // A hole: the point in it is outside, the island in it touches nothing.
    const shell = rect(0, 0, 10, 10);
    const hole = rect(3, 3, 7, 7);
    const donut = shapes.donut(&shell, &hole);
    try std.testing.expect(!try geo.intersects(a, donut, .{ .points = &.{.{ .x = 5, .y = 5 }} }, .{}));
    const island = rect(4, 4, 6, 6);
    try std.testing.expectEqualStrings("FF2FF1212", &(try geo.relate(a, donut, other.one(&island), .{})).string());
    try std.testing.expect(!try geo.intersects(a, donut, other.one(&island), .{}));
    // Filling the hole exactly: touches along the hole's ring, which is
    // the whole of the filler's boundary.
    try std.testing.expectEqualStrings("FF2F112F2", &(try geo.relate(a, donut, other.one(&hole), .{})).string());
}

test "relate: empty operands, invalid input and the ABI entry point" {
    const unit = rect(0, 0, 10, 10);
    var shapes: Shapes = .{};
    var other: Shapes = .{};
    const square = shapes.one(&unit);
    try std.testing.expectEqualStrings("FF2FF1FF2", &(try geo.relate(a, square, .{}, .{})).string());
    try std.testing.expect(!try geo.intersects(a, square, .{}, .{}));
    try std.testing.expect(!try geo.intersects(a, .{}, .{}, .{}));
    const flat_ring = [_]geo.Coordinate{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 0, .y = 0 } };
    try std.testing.expectError(error.InvalidTopology, geo.intersects(a, square, other.one(&flat_ring), .{}));
    const dot = [_]geo.Coordinate{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 } };
    try std.testing.expectError(error.InvalidGeometry, geo.relate(a, square, .{ .line_strings = &.{&dot} }, .{}));
    try std.testing.expectError(error.InvalidOptions, (try geo.relate(a, square, square, .{})).matches("T*F"));

    // The packed matrix the ABI hands a host, and the named codes.
    const overlap = rect(5, 5, 15, 15);
    const m = try geo.relate(a, square, other.one(&overlap), .{});
    var unpacked: [9]u8 = undefined;
    for (&unpacked, 0..) |*c, i| c.* = "F012"[(m.bits() >> @intCast(2 * i)) & 3];
    try std.testing.expectEqualStrings("212101212", &unpacked);
}

test "relate: a probe far outside the other operand's polygon grid" {
    // The grid covers polygon boxes only. A line stretches the first
    // operand's extent across the second, so the second's pieces are probed
    // far outside the grid; converting that cell index before clamping it
    // overflowed `u32` and trapped. GEOS 3.13 gives 102FF1212 here. JSTS
    // gives 212101212, which cannot be right — only the line reaches B.
    const unit = rect(0, 0, 1, 1);
    const line = [_]geo.Coordinate{ .{ .x = 0, .y = 0 }, .{ .x = 1e12, .y = 0 } };
    const far = rect(5e11, -1, 5e11 + 1, 1);
    var shapes: Shapes = .{};
    var other: Shapes = .{};
    const first: geo.Collection = .{ .polygons = shapes.one(&unit).polygons, .line_strings = &.{&line} };
    try std.testing.expectEqualStrings("102FF1212", &(try geo.relate(a, first, other.one(&far), .{})).string());
}

test "relate: a polygon with no rings does not make its operand areal" {
    // `POLYGON EMPTY` beside a line is a line. The named predicates pick
    // their pattern from the operands' dimensions; reading them off the raw
    // input counted the empty polygon, picked `crosses`' area-against-area
    // rule — always false — and missed a line crossing the square. GEOS
    // 3.13 says true, and its matrix is the one below.
    const unit = rect(0, 0, 10, 10);
    const across = [_]geo.Coordinate{ .{ .x = -5, .y = 5 }, .{ .x = 15, .y = 5 } };
    var shapes: Shapes = .{};
    const first: geo.Collection = .{ .polygons = &.{.{ .rings = &.{} }}, .line_strings = &.{&across} };
    const square = shapes.one(&unit);
    try std.testing.expect(try geo.predicate(a, first, square, .crosses, .{}));
    try std.testing.expectEqualStrings("101FF0212", &(try geo.relate(a, first, square, .{})).string());
}

test "relate: patterns decide lazily, and disjoint extents decide from dimensions" {
    const unit = rect(0, 0, 10, 10);
    const overlap = rect(5, 5, 15, 15);
    const far = rect(30, 30, 40, 40);
    var shapes: Shapes = .{};
    var other: Shapes = .{};
    const square = shapes.one(&unit);

    // The pattern language, in and out of its packed form.
    const p = try geo.Pattern.parse("AA*AA*FF*");
    try std.testing.expectEqual(p.codes, (try geo.Pattern.fromBits(p.bits())).codes);
    try std.testing.expectEqual(@as(u32, 0), (try geo.Pattern.parse("*********")).bits());
    try std.testing.expectError(error.InvalidOptions, geo.Pattern.parse("T*X******"));
    try std.testing.expectError(error.InvalidOptions, geo.Pattern.fromBits(7));
    try std.testing.expectError(error.InvalidOptions, geo.Pattern.fromBits(1 << 27));

    // `check` on a matrix still growing: an F that filled is failed for good,
    // a filled T is matched once nothing else waits, and an F that holds is
    // not yet anything.
    var m: geo.Matrix = .{ .dims = .{ 2, 2 } };
    try std.testing.expectEqual(geo.Pattern.Verdict.undecided, (try geo.Pattern.parse("T*****FF*")).verdict(m, false));
    m.cells[0][0] = .area;
    try std.testing.expectEqual(geo.Pattern.Verdict.matched, (try geo.Pattern.parse("T********")).verdict(m, false));
    try std.testing.expectEqual(geo.Pattern.Verdict.undecided, (try geo.Pattern.parse("T*****FF*")).verdict(m, false));
    m.cells[2][0] = .area;
    try std.testing.expectEqual(geo.Pattern.Verdict.failed, (try geo.Pattern.parse("T*****FF*")).verdict(m, false));
    try std.testing.expectEqual(geo.Pattern.Verdict.failed, (try geo.Pattern.parse("1********")).verdict(m, false));
    try std.testing.expectEqual(geo.Pattern.Verdict.matched, (try geo.Pattern.parse("2********")).verdict(m, false));

    // The lazy answer agrees with the full matrix on every named predicate.
    for ([_][]const geo.Coordinate{ &overlap, &far, &unit }) |ring| {
        const second = other.one(ring);
        const full = try geo.relate(a, square, second, .{});
        inline for (std.meta.fields(geo.Predicate)) |field| {
            const predicate: geo.Predicate = @enumFromInt(field.value);
            try std.testing.expectEqual(full.evaluate(predicate), try geo.predicate(a, square, second, predicate, .{}));
        }
        try std.testing.expectEqual(try full.matches("T*T***T**"), try geo.matches(a, square, second, "T*T***T**", .{}));
    }
    // Disjoint extents: polygons settle every cell; lines leave their
    // boundary cell open, and a pattern that asks about it still gets the
    // right answer by the long way round.
    const line = [_]geo.Coordinate{ .{ .x = 30, .y = 30 }, .{ .x = 40, .y = 40 } };
    const ring = [_]geo.Coordinate{ .{ .x = 30, .y = 30 }, .{ .x = 40, .y = 30 }, .{ .x = 40, .y = 40 }, .{ .x = 30, .y = 30 } };
    try std.testing.expect(try geo.matches(a, square, .{ .line_strings = &.{&line} }, "FF2FF1102", .{}));
    try std.testing.expect(try geo.matches(a, square, .{ .line_strings = &.{&ring} }, "FF2FF11F2", .{}));
    try std.testing.expect(try geo.predicate(a, square, .{ .line_strings = &.{&line} }, .disjoint, .{}));
    try std.testing.expect(!try geo.predicate(a, square, .{ .points = &.{.{ .x = 5, .y = 5 }} }, .touches, .{}));
    try std.testing.expect(!try geo.predicate(a, .{ .points = &.{.{ .x = 5, .y = 5 }} }, .{ .points = &.{.{ .x = 5, .y = 5 }} }, .touches, .{}));
}
