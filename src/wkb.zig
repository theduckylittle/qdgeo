// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
const std = @import("std");
const g = @import("geometry.zig");

/// The whole pipeline shares one budget; see `geometry.Limits`.
pub const Limits = g.Limits;

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,
    points: usize = 0,
    rings: usize = 0,
    limits: Limits,

    fn take(self: *Reader, n: usize) ![]const u8 {
        if (n > self.bytes.len - self.pos) return error.TruncatedWkb;
        const result = self.bytes[self.pos..][0..n];
        self.pos += n;
        return result;
    }
    fn integer(self: *Reader, comptime T: type, endian: std.builtin.Endian) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], endian);
    }
    fn header(self: *Reader) !struct { endian: std.builtin.Endian, kind: u32 } {
        const endian: std.builtin.Endian = switch ((try self.take(1))[0]) {
            0 => .big,
            1 => .little,
            else => return error.InvalidByteOrder,
        };
        return .{ .endian = endian, .kind = try self.integer(u32, endian) };
    }
    fn coordinate(self: *Reader, endian: std.builtin.Endian) !g.Coordinate {
        if (self.points == self.limits.max_points) return error.LimitExceeded;
        self.points += 1;
        return .{ .x = @bitCast(try self.integer(u64, endian)), .y = @bitCast(try self.integer(u64, endian)) };
    }
    /// A run of coordinates. When the geometry's byte order matches the host's,
    /// WKB coordinates are already an array of x, y pairs, so the whole run is
    /// one copy rather than two `readInt` calls per point.
    fn coordinates(self: *Reader, a: std.mem.Allocator, n: u32, endian: std.builtin.Endian) ![]g.Coordinate {
        if (n > self.limits.max_points - self.points) return error.LimitExceeded;
        self.points += n;
        if (n > (self.bytes.len - self.pos) / 16) return error.TruncatedWkb;
        const points = try a.alloc(g.Coordinate, n);
        const source = try self.take(16 * @as(usize, n));
        if (endian == @import("builtin").cpu.arch.endian()) {
            @memcpy(std.mem.sliceAsBytes(points), source);
        } else {
            for (points, 0..) |*p, i| {
                p.* = .{
                    .x = @bitCast(std.mem.readInt(u64, source[16 * i ..][0..8], endian)),
                    .y = @bitCast(std.mem.readInt(u64, source[16 * i + 8 ..][0..8], endian)),
                };
            }
        }
        return points;
    }
    fn chain(self: *Reader, a: std.mem.Allocator, endian: std.builtin.Endian) ![]g.Coordinate {
        return self.coordinates(a, try self.integer(u32, endian), endian);
    }
    fn polygon(self: *Reader, a: std.mem.Allocator, endian: std.builtin.Endian) !g.Polygon {
        const nr = try self.integer(u32, endian);
        if (nr > self.limits.max_rings - self.rings) return error.LimitExceeded;
        self.rings += nr;
        if (nr > (self.bytes.len - self.pos) / 4) return error.TruncatedWkb;
        const rings = try a.alloc(g.LinearRing, nr);
        for (rings) |*ring| {
            const points = try self.coordinates(a, try self.integer(u32, endian), endian);
            try g.validateLinearRing(points);
            ring.* = points;
        }
        return .{ .rings = rings };
    }
};

const Collector = struct {
    a: std.mem.Allocator,
    reader: *Reader,
    polygons: std.ArrayList(g.Polygon) = .empty,
    line_strings: std.ArrayList(g.LineString) = .empty,
    points: std.ArrayList(g.Coordinate) = .empty,

    /// One OGC geometry, including nested collections. `depth` bounds recursion
    /// so a hostile collection cannot exhaust the stack.
    fn read(self: *Collector, depth: usize) !void {
        if (depth > self.reader.limits.max_depth) return error.LimitExceeded;
        const h = try self.reader.header();
        switch (h.kind) {
            1 => try self.points.append(self.a, try self.reader.coordinate(h.endian)),
            2 => {
                const line = try self.reader.chain(self.a, h.endian);
                // An empty LineString is legal WKB and contributes nothing.
                if (line.len == 0) return;
                try g.validateLineString(line);
                try self.line_strings.append(self.a, line);
            },
            3 => {
                if (self.polygons.items.len >= self.reader.limits.max_polygons) return error.LimitExceeded;
                try self.polygons.append(self.a, try self.reader.polygon(self.a, h.endian));
            },
            4, 5, 6, 7 => {
                const n = try self.reader.integer(u32, h.endian);
                // A declared count beyond the configured cap is a limit
                // violation whatever the buffer length, so check it first.
                const cap = if (h.kind == 4) self.reader.limits.max_points else self.reader.limits.max_polygons;
                if (n > cap) return error.LimitExceeded;
                if (n > (self.bytes() - self.reader.pos) / 5) return error.TruncatedWkb;
                for (0..n) |_| {
                    const before = self.reader.pos;
                    try self.read(depth + 1);
                    if (self.reader.pos == before) return error.MalformedWkb;
                    if (h.kind != 7) try self.checkMember(h.kind);
                }
            },
            else => return error.UnsupportedGeometry,
        }
    }

    fn bytes(self: *const Collector) usize {
        return self.reader.bytes.len;
    }

    /// A homogeneous multi-geometry may only hold its own member type.
    fn checkMember(self: *const Collector, kind: u32) !void {
        const wanted: usize = switch (kind) {
            4 => self.points.items.len,
            5 => self.line_strings.items.len,
            else => self.polygons.items.len,
        };
        if (wanted == 0) return error.UnsupportedGeometry;
    }
};

/// OGC 2D Coordinate (1), LineString (2), Polygon (3) and their Multi- forms (4, 5,
/// 6), plus GeometryCollection (7). EWKB/SRID, Z/M and trailing bytes are
/// rejected. Structural validation only; topology is checked by operations that
/// require it.
pub fn parse(a: std.mem.Allocator, bytes: []const u8, limits: Limits) !g.Geometry {
    var result: g.Geometry = .{ .arena = std.heap.ArenaAllocator.init(a), .polygons = &.{} };
    errdefer result.deinit();
    const alloc = result.arena.allocator();
    var reader: Reader = .{ .bytes = bytes, .limits = limits };
    var collector: Collector = .{ .a = alloc, .reader = &reader };
    try collector.read(0);
    if (reader.pos != bytes.len) return error.TrailingBytes;
    result.polygons = try collector.polygons.toOwnedSlice(alloc);
    result.line_strings = try collector.line_strings.toOwnedSlice(alloc);
    result.points = try collector.points.toOwnedSlice(alloc);
    return result;
}

const Writer = struct {
    list: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    endian: std.builtin.Endian,
    fn integer(self: *Writer, comptime T: type, value: T) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, self.endian);
        try self.list.appendSlice(self.a, &bytes);
    }
    fn count(self: *Writer, n: usize) !void {
        try self.integer(u32, std.math.cast(u32, n) orelse return error.LimitExceeded);
    }
    fn header(self: *Writer, kind: u32) !void {
        try self.list.append(self.a, if (self.endian == .little) 1 else 0);
        try self.integer(u32, kind);
    }
    /// Mirror of `Reader.coordinates`: matching byte order means the ring is
    /// already the bytes to emit.
    fn coordinates(self: *Writer, ring: g.LinearRing) !void {
        if (self.endian == @import("builtin").cpu.arch.endian()) {
            try self.list.appendSlice(self.a, std.mem.sliceAsBytes(ring));
            return;
        }
        for (ring) |point| {
            try self.integer(u64, @bitCast(point.x));
            try self.integer(u64, @bitCast(point.y));
        }
    }
};

/// Always emits MultiPolygon WKB. Caller frees the returned bytes with `a.free`.
pub fn write(a: std.mem.Allocator, polygons: []const g.Polygon, endian: std.builtin.Endian) ![]u8 {
    var w: Writer = .{ .a = a, .endian = endian };
    errdefer w.list.deinit(a);
    try w.header(6);
    try w.count(polygons.len);
    for (polygons) |p| {
        try w.header(3);
        try w.count(p.rings.len);
        for (p.rings) |r| {
            try g.validateLinearRing(r);
            try w.count(r.len);
            try w.coordinates(r);
        }
    }
    return w.list.toOwnedSlice(a);
}
