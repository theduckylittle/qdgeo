// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Spatial predicates: `intersects`, and every other named predicate through
//! the DE-9IM `relate` matrix, over two collections of points, lines and
//! polygons.
//!
//! Each operand is a collection and is read with union semantics: a point on
//! the edge two polygons of the same operand share is *inside* that operand,
//! and a line's endpoint is only a boundary point when an odd number of the
//! operand's lines end there. That is what makes `intersects([a, b, c],
//! [d, e, f])` mean "does a ∪ b ∪ c meet d ∪ e ∪ f", and it is the rule JTS
//! applies to a GeometryCollection.
//!
//! The matrix is built from an arrangement rather than from an overlay. Every
//! vertex and every crossing is a node, each segment is cut into pieces at its
//! nodes, and each node and piece is located in both operands with the same
//! exact `orient` the overlay uses. A piece also knows the winding on either
//! side of itself, which is what tells a shared edge whose interiors lie on
//! the same side from one whose interiors lie on opposite sides, and what lets
//! the regions beside a piece fill the two-dimensional cells.
//!
//! Evaluation is lazy. A predicate arrives as a pattern over the matrix, and
//! since cells only grow as the arrangement is walked, the walk stops the
//! moment the pattern is decided: an `F` cell that fills, a dimension that is
//! passed, or the last required cell filling. Disjoint extents answer from the
//! dimensions alone, before a segment is read. `intersects` goes one step
//! further, because it is the question a map asks thousands of times: the
//! first contact between the operands answers `true` inside the sweep, before
//! anything is located.
const std = @import("std");
const g = @import("geometry.zig");
const pred = @import("predicates.zig");
const operations = @import("operations.zig");
const sweep = @import("sweep.zig");

pub const Collection = g.Collection;

pub const Options = struct {
    limits: g.Limits = .{},
};

/// One cell of the matrix: empty, or the dimension of that intersection.
pub const Cell = enum(u2) {
    empty,
    point,
    line,
    area,

    /// The character JTS prints for it: `F`, `0`, `1` or `2`.
    pub fn char(c: Cell) u8 {
        return "F012"[@intFromEnum(c)];
    }

    /// Where a piece or point lies in two things at once, it lies in the
    /// lower-dimensional of the two.
    fn lower(a: Cell, b: Cell) Cell {
        return @enumFromInt(@min(@intFromEnum(a), @intFromEnum(b)));
    }
};

pub const Location = enum(u2) { interior, boundary, exterior };

/// A DE-9IM pattern: what JTS's `relate(a, b, pattern)` takes, plus one
/// extension. `T` is any non-empty cell, `F` an empty one, `0`, `1` and `2`
/// an exact dimension, `*` anything, and `A` marks a group of cells of which
/// at least one must be non-empty — which is how `intersects`, `covers` and
/// `touches` are one pattern each rather than a disjunction of four.
///
/// A pattern is also what makes `relate` lazy. Cells only ever grow as the
/// arrangement is walked, so an `F` that fills or a dimension that is passed
/// decides the answer at once, and so does the last `T` filling when nothing
/// else is left to wait for. `check` is that reading; `matches` is the final
/// one.
pub const Pattern = struct {
    pub const Code = enum(u3) { any, filled, empty, point, line, area, group };
    codes: [9]Code,

    pub fn parse(text: []const u8) !Pattern {
        if (text.len != 9) return error.InvalidOptions;
        var p: Pattern = undefined;
        for (text, &p.codes) |c, *code| code.* = switch (c) {
            '*' => .any,
            'T', 't' => .filled,
            'F', 'f' => .empty,
            '0' => .point,
            '1' => .line,
            '2' => .area,
            'A', 'a' => .group,
            else => return error.InvalidOptions,
        };
        return p;
    }

    /// Three bits per cell, first cell lowest, so `*********` is zero. What
    /// the ABI takes.
    pub fn fromBits(value: u32) !Pattern {
        var p: Pattern = undefined;
        for (&p.codes, 0..) |*code, i| {
            code.* = std.enums.fromInt(Code, (value >> @intCast(3 * i)) & 7) orelse return error.InvalidOptions;
        }
        if (value >> 27 != 0) return error.InvalidOptions;
        return p;
    }

    pub fn bits(p: Pattern) u32 {
        var out: u32 = 0;
        for (p.codes, 0..) |code, i| out |= @as(u32, @intFromEnum(code)) << @intCast(3 * i);
        return out;
    }

    pub const Verdict = enum { undecided, matched, failed };

    /// What a matrix says about the pattern. While the matrix is still being
    /// built, cells only grow: an empty cell that filled, or a dimension that
    /// was passed, is a failure for good; a filled `T`, a reached `2` and a
    /// group with a filled cell are satisfied for good; an `F`, a `0` or a
    /// `1` that holds so far may still be broken, so it is undecided. Over a
    /// `final` matrix those hold for good too.
    pub fn verdict(p: Pattern, m: Matrix, final: bool) Verdict {
        var settled = true;
        var group = false;
        var met = false;
        for (p.codes, 0..) |code, i| {
            const cell = m.cells[i / 3][i % 3];
            switch (code) {
                .any => {},
                .filled => if (cell == .empty) {
                    settled = false;
                },
                .empty => if (cell != .empty) return .failed else if (!final) {
                    settled = false;
                },
                .point, .line, .area => {
                    const want: Cell = @enumFromInt(@intFromEnum(code) - 2);
                    if (@intFromEnum(cell) > @intFromEnum(want)) return .failed;
                    if (cell != want or (want != .area and !final)) settled = false;
                },
                .group => {
                    group = true;
                    if (cell != .empty) met = true;
                },
            }
        }
        if (group and !met) settled = false;
        return if (settled) .matched else if (final) .failed else .undecided;
    }

    /// The answer over a finished matrix.
    pub fn matches(p: Pattern, m: Matrix) bool {
        return p.verdict(m, true) == .matched;
    }

    /// Whether this is `intersects`, which has an exit of its own inside the
    /// sweep: any contact at all fills one of its four cells.
    fn isIntersects(p: Pattern) bool {
        return std.mem.eql(Code, &p.codes, &(parse("AA*AA****") catch unreachable).codes);
    }
};

/// The named predicates, each a pattern over the matrix with JTS's
/// definition. The binding carries the same table; the ABI takes the pattern.
pub const Predicate = enum {
    intersects,
    disjoint,
    contains,
    within,
    covers,
    covered_by,
    touches,
    crosses,
    overlaps,
    equals,

    /// The pattern for operands of dimensions `a` and `b` (-1 for empty), or
    /// null where the predicate is false for those dimensions outright: two
    /// points cannot touch, and only equal dimensions can overlap.
    pub fn pattern(p: Predicate, a: i8, b: i8) ?[]const u8 {
        return switch (p) {
            .intersects => "AA*AA****",
            .disjoint => "FF*FF****",
            .contains => "T*****FF*",
            .within => "T*F**F***",
            .covers => "AA*AA*FF*",
            .covered_by => "AAFAAF***",
            .equals => "T*F**FFF*",
            .touches => if (a == 0 and b == 0) null else "FA*AA****",
            .crosses => if (a < b) "T*T******" else if (a > b) "T*****T**" else if (a == 1) "0********" else null,
            .overlaps => if (a != b) null else if (a == 1) "1*T***T**" else "T*T***T**",
        };
    }
};

/// The DE-9IM matrix: rows are the first operand's interior, boundary and
/// exterior, columns the second's, and each cell holds the dimension of that
/// intersection. `string` prints it the way JTS does, `II IB IE BI BB BE EI
/// EB EE`, and `matches` reads a pattern in the same order.
pub const Matrix = struct {
    cells: [3][3]Cell = @splat(@splat(.empty)),
    /// Each operand's dimension, -1 when it is empty. `touches`, `crosses`
    /// and `overlaps` are defined in terms of it.
    dims: [2]i8,

    pub fn get(m: Matrix, row: Location, column: Location) Cell {
        return m.cells[@intFromEnum(row)][@intFromEnum(column)];
    }

    fn raise(m: *Matrix, row: Location, column: Location, cell: Cell) void {
        const at = &m.cells[@intFromEnum(row)][@intFromEnum(column)];
        if (@intFromEnum(cell) > @intFromEnum(at.*)) at.* = cell;
    }

    pub fn string(m: Matrix) [9]u8 {
        var out: [9]u8 = undefined;
        for (m.cells, 0..) |row, r| for (row, 0..) |cell, c| {
            out[3 * r + c] = cell.char();
        };
        return out;
    }

    /// Two bits per cell in string order, the first cell lowest. What the
    /// ABI returns, since a host unpacks eighteen bits faster than it parses
    /// nine characters.
    pub fn bits(m: Matrix) u32 {
        var out: u32 = 0;
        for (m.cells, 0..) |row, r| for (row, 0..) |cell, c| {
            out |= @as(u32, @intFromEnum(cell)) << @intCast(2 * (3 * r + c));
        };
        return out;
    }

    pub fn matches(m: Matrix, pattern: []const u8) !bool {
        return (try Pattern.parse(pattern)).matches(m);
    }

    /// A named predicate, read off a finished matrix.
    pub fn evaluate(m: Matrix, predicate: Predicate) bool {
        const text = predicate.pattern(m.dims[0], m.dims[1]) orelse return false;
        return (Pattern.parse(text) catch unreachable).matches(m);
    }
};

/// Both operands, validated and normalized once per call. Every entry point
/// starts here, so every one reads dimensions off the same `Set` — a polygon
/// with no rings is dropped before anything counts it.
fn prepare(sa: std.mem.Allocator, first: Collection, second: Collection, options: Options) ![2]Set {
    return .{ try Set.build(sa, first, options.limits), try Set.build(sa, second, options.limits) };
}

/// The matrix for `first` against `second`, complete.
pub fn relate(a: std.mem.Allocator, first: Collection, second: Collection, options: Options) !Matrix {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var sets = try prepare(sa, first, second, options);
    if (try pointMatrix(sa, &sets)) |m| return m;
    var arrangement = try Arrangement.build(sa, sets, options.limits);
    return arrangement.matrix(null);
}

/// Whether the matrix matches `pattern`, stopping as soon as it is decided.
pub fn matches(a: std.mem.Allocator, first: Collection, second: Collection, pattern: []const u8, options: Options) !bool {
    return match(a, first, second, try Pattern.parse(pattern), options);
}

pub fn match(a: std.mem.Allocator, first: Collection, second: Collection, pattern: Pattern, options: Options) !bool {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var sets = try prepare(sa, first, second, options);
    return matchSets(sa, &sets, pattern, options.limits);
}

/// A named predicate, with the early exits a pattern gets.
pub fn evaluate(a: std.mem.Allocator, first: Collection, second: Collection, predicate: Predicate, options: Options) !bool {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var sets = try prepare(sa, first, second, options);
    const text = predicate.pattern(sets[0].dimension(), sets[1].dimension()) orelse return false;
    return matchSets(sa, &sets, Pattern.parse(text) catch unreachable, options.limits);
}

/// Whether the two collections share any point. The one predicate with an
/// exit inside the sweep — see the module doc for why it gets one.
pub fn intersects(a: std.mem.Allocator, first: Collection, second: Collection, options: Options) !bool {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const sets = try prepare(sa, first, second, options);
    return intersectsSets(sa, &sets, options.limits);
}

fn matchSets(sa: std.mem.Allocator, sets: *[2]Set, pattern: Pattern, limits: g.Limits) !bool {
    if (pattern.isIntersects()) return intersectsSets(sa, sets, limits);
    if (apart(sets, pattern)) |answer| return answer;
    if (try pointMatrix(sa, sets)) |m| return pattern.matches(m);
    var arrangement = try Arrangement.build(sa, sets.*, limits);
    return pattern.matches(try arrangement.matrix(pattern));
}

fn intersectsSets(sa: std.mem.Allocator, sets: *const [2]Set, limits: g.Limits) !bool {
    const one = sets[0].extent orelse return false;
    const two = sets[1].extent orelse return false;
    if (!one.overlaps(two)) return false;

    const segments = try collect(sa, sets, limits, .{ two, one });
    if (try contacts(sa, segments, true, null, limits)) return true;

    // Nothing touches, so every ring, line and point of one operand lies
    // wholly inside or wholly outside the other, and one vertex of each says
    // which. A vertex cannot be on the other's boundary: that would have been
    // a contact. A vertex outside the other's extent is outside the other, so
    // only those inside it are probed.
    const inside = struct {
        fn f(o: *const Set, p: g.Coordinate) bool {
            return o.extent.?.has(p) and probe(o, p, null, null).left > 0;
        }
    }.f;
    for (sets, 0..) |*set, k| {
        const other = &sets[1 - k];
        if (other.polygons.len == 0) continue;
        for (set.polygons) |polygon| if (inside(other, polygon.rings[0][0])) return true;
        for (set.lines) |line| if (inside(other, line[0])) return true;
        for (set.points) |point| if (inside(other, point)) return true;
    }
    return false;
}

// --- Points against one kind ----------------------------------------------

/// The map key for a coordinate: the overlay's, after its signed-zero fold,
/// so one point is one key in both engines.
fn keyOf(p: g.Coordinate) u128 {
    return sweep.keyOf(sweep.canonical(p));
}

/// The matrix with no arrangement, when one operand is only points and the
/// other is only polygons, only lines, or only points. A point operand has no
/// boundary and its interior is the points themselves, so its row is where
/// each point falls in the other operand, and the exterior row follows from
/// what the other operand is made of.
///
/// Point-in-polygon is the workload a map asks most, and building a full
/// arrangement to locate one point cost 3.4x what Rust Geo's point-specific
/// test does. Null when the operands are not of this shape, or when a point
/// lies exactly on a polygon edge: under union semantics a point on an edge
/// two polygons share is interior, which takes the arrangement's radial view
/// to see, and those inputs keep the arrangement.
fn pointMatrix(sa: std.mem.Allocator, sets: *[2]Set) !?Matrix {
    const only = struct {
        fn points(s: *const Set) bool {
            return s.points.len != 0 and s.lines.len == 0 and s.polygons.len == 0;
        }
    }.points;
    const k: usize = if (only(&sets[0])) 0 else if (only(&sets[1])) 1 else return null;
    const mine = &sets[k];
    const other = &sets[1 - k];
    const kinds = @as(u2, @intFromBool(other.polygons.len != 0)) + @intFromBool(other.lines.len != 0) + @intFromBool(other.points.len != 0);
    if (kinds > 1) return null;
    // Against lines or points the location is a linear scan, which is the
    // win for the query a map asks — a point, or a handful — and a loss past
    // that: 4,040 points against 4,040 lines took 167 ms this way and 3.9 ms
    // through the arrangement's sweep. Polygons are indexed, so they have no
    // such limit.
    if (other.polygons.len == 0 and mine.points.len > 8) return null;

    // Membership in the few points is a scan. The line ends are counted
    // once, in a map reserved up front and read and written only through
    // `getOrPutAssumeCapacity` — the one call the vertex map already brings
    // into the artifact, so this adds no hash-map code: `get`, `contains` and
    // an iterator cost 0.8 KB gzipped. A scan per endpoint instead made one
    // point against 4,040 lines take 97 ms.
    const has = struct {
        fn f(points: []const g.Coordinate, p: g.Coordinate) bool {
            for (points) |q| if (g.equal(p, q)) return true;
            return false;
        }
    }.f;
    var ends: sweep.Vertices.Map = .empty;
    try ends.ensureTotalCapacity(sa, @intCast(2 * other.lines.len + mine.points.len));
    for (other.lines) |line| for (g.ends(line)) |end| {
        const slot = ends.getOrPutAssumeCapacity(keyOf(end));
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
    };
    // A lookup that may insert a zero, which reads as "no line ends here";
    // the capacity above leaves room for one per point.
    const count = struct {
        fn f(map: *sweep.Vertices.Map, p: g.Coordinate) u32 {
            const slot = map.getOrPutAssumeCapacity(keyOf(p));
            if (!slot.found_existing) slot.value_ptr.* = 0;
            return slot.value_ptr.*;
        }
    }.f;
    // Many points against many polygons is worth the probe indexes.
    if (other.polygons.len != 0 and mine.points.len > 8) try other.index(sa);

    var m: Matrix = .{ .dims = .{ 0, other.dimension() } };
    m.cells[2][2] = .area;
    for (mine.points) |p| {
        const at: Location = if (other.polygons.len != 0) blk: {
            if (onPolygonEdge(other, p)) return null;
            break :blk if (probe(other, p, null, null).left > 0) .interior else .exterior;
        } else if (other.lines.len != 0) blk: {
            const n = count(&ends, p);
            if (n != 0) break :blk if (n % 2 == 1) .boundary else .interior;
            break :blk if (onLine(other, p)) .interior else .exterior;
        } else if (has(other.points, p)) .interior else .exterior;
        m.raise(.interior, at, .point);
    }
    // The other operand against the points' exterior: everything of it but
    // finitely many points, so its full dimension wherever it is a curve or a
    // region, and point by point where it is points.
    if (other.polygons.len != 0) {
        m.raise(.exterior, .interior, .area);
        m.raise(.exterior, .boundary, .line);
    } else if (other.lines.len != 0) {
        m.raise(.exterior, .interior, .line);
        for (other.lines) |line| for (g.ends(line)) |end| {
            if (count(&ends, end) % 2 == 1 and !has(mine.points, end)) m.raise(.exterior, .boundary, .point);
        };
    } else {
        for (other.points) |p| if (!has(mine.points, p)) m.raise(.exterior, .interior, .point);
    }
    if (k == 1) {
        for (0..3) |r| for (r + 1..3) |c| std.mem.swap(Cell, &m.cells[r][c], &m.cells[c][r]);
        std.mem.swap(i8, &m.dims[0], &m.dims[1]);
    }
    return m;
}

/// Whether `p` lies on an edge of one of the operand's polygons: exactly on
/// the edge's line, by `orient`, and inside its box.
fn onPolygonEdge(s: *const Set, p: g.Coordinate) bool {
    const On = struct {
        s: *const Set,
        p: g.Coordinate,
        fn edge(v: @This(), e: u32) bool {
            return pred.onSegment(v.s.edges[e][0], v.s.edges[e][1], v.p);
        }
    };
    return s.eachNear(p, On{ .s = s, .p = p });
}

/// Whether `p` lies on a segment of one of the operand's lines.
fn onLine(s: *const Set, p: g.Coordinate) bool {
    for (s.lines) |line| for (line[0 .. line.len - 1], line[1..]) |t, h| {
        if (pred.onSegment(t, h, p)) return true;
    };
    return false;
}

/// The answer when the operands' extents do not overlap, or one is empty,
/// which the dimensions alone settle: nothing meets, each operand's interior
/// and boundary lie in the other's exterior. The one cell they cannot settle
/// is the boundary of an operand made of lines — it is empty when every
/// endpoint is shared, mod 2 — so a pattern that asks about it falls through
/// to the arrangement. Null when the extents overlap.
fn apart(sets: *const [2]Set, pattern: Pattern) ?bool {
    if (sets[0].extent) |one| if (sets[1].extent) |two| if (one.overlaps(two)) return null;
    var m: Matrix = .{ .dims = .{ sets[0].dimension(), sets[1].dimension() } };
    m.cells[2][2] = .area;
    for (0..2) |k| {
        const set = sets[k];
        // The first operand's interior and boundary against the second's
        // exterior are cells 2 and 5; the second's against the first's are 6
        // and 7.
        const interior: usize = if (k == 0) 2 else 6;
        const boundary: usize = if (k == 0) 5 else 7;
        if (set.dimension() >= 0) m.cells[interior / 3][interior % 3] = @enumFromInt(set.dimension() + 1);
        if (set.polygons.len != 0) {
            m.cells[boundary / 3][boundary % 3] = .line;
        } else if (set.lines.len != 0 and pattern.codes[boundary] != .any) {
            return null;
        }
    }
    return pattern.matches(m);
}

// --- Operands ----------------------------------------------------------------

/// One operand, validated and normalized: rings oriented shell-CCW and
/// hole-CW with repeated points dropped, lines with repeated points dropped,
/// and an extent per polygon and line for the probes to reject on.
const Set = struct {
    polygons: []const g.Polygon,
    lines: []const g.LineString,
    points: []const g.Coordinate,
    polygon_extents: []const g.Extent,
    /// Where each polygon's edges start among the operand's segments, with
    /// the total at the end.
    polygon_first: []const u32,
    /// Every polygon edge, in segment order, so a band can name one by index.
    edges: []const [2]g.Coordinate,
    /// Per polygon, its edges by horizontal band; see `Bands`. Empty until
    /// `index` runs.
    bands: []const Bands = &.{},
    /// Null until `index` runs, and a probe reads every polygon until then.
    grid: ?Grid = null,
    /// Null when the operand is empty.
    extent: ?g.Extent,

    fn build(sa: std.mem.Allocator, c: Collection, limits: g.Limits) !Set {
        // `normalized` is what the overlay runs on its input, so a polygon the
        // overlay would reject is rejected here for the same reason.
        // `normalized` is also where `POLYGON EMPTY` is dropped.
        const polygons = (try operations.normalized(sa, c.polygons, limits)).polygons;
        const lines = try sa.alloc(g.LineString, c.line_strings.len);
        for (c.line_strings, lines) |raw, *line| {
            line.* = try operations.normalizedLine(sa, raw);
            // One repeated coordinate is not a line, and is not repaired
            // into a point.
            if (line.*.len < 2) return error.InvalidGeometry;
        }
        for (c.points) |p| if (!g.within(p, g.coordinate_limit)) return error.CoordinateRange;

        var extent: ?g.Extent = null;
        const polygon_extents = try sa.alloc(g.Extent, polygons.len);
        // One more than there are polygons: polygon `i`'s edges are
        // `polygon_first[i]..polygon_first[i + 1]`, the last one included.
        const polygon_first = try sa.alloc(u32, polygons.len + 1);
        var edges: u32 = 0;
        for (polygons, polygon_extents, polygon_first[0..polygons.len]) |polygon, *box, *first| {
            box.* = g.Extent.around(polygon.rings[0]);
            extent = g.Extent.grow(extent, box.*);
            first.* = edges;
            for (polygon.rings) |ring| edges += @intCast(ring.len - 1);
        }
        polygon_first[polygons.len] = edges;
        for (lines) |line| extent = g.Extent.grow(extent, g.Extent.around(line));
        for (c.points) |p| extent = g.Extent.grow(extent, g.Extent.of(p, p));
        const flat = try sa.alloc([2]g.Coordinate, edges);
        var at: usize = 0;
        for (polygons) |polygon| for (polygon.rings) |ring| for (ring[0 .. ring.len - 1], ring[1..]) |t, h| {
            flat[at] = .{ t, h };
            at += 1;
        };
        return .{
            .polygons = polygons,
            .lines = lines,
            .points = c.points,
            .polygon_extents = polygon_extents,
            .polygon_first = polygon_first,
            .edges = flat,
            .extent = extent,
        };
    }

    /// The probe indexes: the grid over polygon boxes and each large
    /// polygon's edge bands. Only the arrangement probes enough to pay for
    /// them; `intersects` probes one vertex per ring at most, and building
    /// them on every call was a quarter of a small call's time.
    fn index(s: *Set, sa: std.mem.Allocator) !void {
        const bands = try sa.alloc(Bands, s.polygons.len);
        for (s.polygon_extents, s.polygon_first[0..s.polygons.len], s.polygon_first[1..], bands) |box, first, end, *b| {
            b.* = try Bands.build(sa, s.edges[first..end], box, first);
        }
        s.bands = bands;
        s.grid = try Grid.build(sa, s.polygon_extents);
    }

    /// The edges of polygon `pi` that a probe at height `y` has to read: the
    /// band holding `y` for a banded polygon, every edge otherwise. Either way
    /// a run `[from, to)`, through `list` when there is one — one loop, so the
    /// edge test is emitted once.
    fn edgesAt(s: *const Set, pi: usize, y: f64) struct { from: u32, to: u32, list: ?[]const u32 } {
        const b: Bands = if (s.bands.len != 0) s.bands[pi] else .{};
        if (b.count == 0) return .{ .from = s.polygon_first[pi], .to = s.polygon_first[pi + 1], .list = null };
        const k = b.index(y);
        return .{ .from = b.lists.starts[k], .to = b.lists.starts[k + 1], .list = b.lists.items };
    }

    /// The highest dimension present, -1 when nothing is.
    fn dimension(s: Set) i8 {
        if (s.polygons.len != 0) return 2;
        if (s.lines.len != 0) return 1;
        if (s.points.len != 0) return 0;
        return -1;
    }

    fn segmentCount(s: Set) usize {
        var n: usize = s.edges.len + s.points.len;
        for (s.lines) |line| n += line.len - 1;
        return n;
    }

    /// Hand `visitor.edge(e)` every polygon edge a probe at `m` has to read,
    /// until it returns true: the polygons in the grid's cell for `m`, or
    /// every polygon before there is a grid; of those, the ones whose box
    /// holds `m`; of their edges, `edgesAt`'s run. The winding probe and the
    /// on-an-edge test both walk this way, so it is written once.
    ///
    /// `inline`, with the visitor a comptime-known type, so each caller gets
    /// the two plain nested loops written out. An iterator struct carrying the
    /// same state across `next` calls measured 1.9x slower on a whole-dataset
    /// `relate`, where this loop is nearly all the time.
    inline fn eachNear(s: *const Set, m: g.Coordinate, visitor: anytype) bool {
        const cell: ?[]const u32 = if (s.grid) |grid| grid.at(m) else null;
        const candidates = if (cell) |list| list.len else s.polygons.len;
        for (0..candidates) |j| {
            const pi = if (cell) |list| list[j] else j;
            // A polygon whose box misses `m` winds zero around it and has no
            // edge through it, so nothing in it can change the answer.
            if (!s.polygon_extents[pi].has(m)) continue;
            const run = s.edgesAt(pi, m.y);
            for (run.from..run.to) |i| {
                if (visitor.edge(if (run.list) |list| list[i] else @intCast(i))) return true;
            }
        }
        return false;
    }
};

/// Which of `count` buckets, each `width` wide from `floor`, holds `value`,
/// clamped to the first and the last. The grid, the edge bands and the
/// segment order all bucket this way.
///
/// The clamp happens on the float, before the conversion. The grid used to
/// convert first: a probe far outside it — a polygon far along a line that
/// stretches the other operand's extent — overflowed `u32`, and `ReleaseSafe`
/// trapped on valid input. The overlay's `bucketOf` was already written this
/// way.
fn bucket(value: f64, floor: f64, width: f64, count: usize) u32 {
    if (!(width > 0)) return 0;
    const q = (value - floor) / width;
    if (!(q > 0)) return 0;
    if (!(q < @as(f64, @floatFromInt(count - 1)))) return @intCast(count - 1);
    return @intFromFloat(q);
}

/// Items in lists by bucket, all in one array: bucket `b` holds
/// `items[starts[b]..starts[b + 1]]`. `source.each(i, sink)` calls
/// `sink.add(b, i)` once for each bucket item `i` belongs to.
const Lists = struct {
    starts: []const u32 = &.{ 0, 0 },
    items: []const u32 = &.{},

    fn at(l: Lists, b: usize) []const u32 {
        return l.items[l.starts[b]..l.starts[b + 1]];
    }

    /// A counting sort — count, prefix-sum, fill — which is what the grid,
    /// the edge bands and the segment order each wrote out for themselves.
    fn build(sa: std.mem.Allocator, buckets: usize, n: usize, source: anytype) !Lists {
        const starts = try sa.alloc(u32, buckets + 1);
        @memset(starts, 0);
        const Count = struct {
            starts: []u32,
            fn add(c: @This(), b: usize, _: u32) void {
                c.starts[b + 1] += 1;
            }
        };
        for (0..n) |i| source.each(@intCast(i), Count{ .starts = starts });
        for (starts[1..], 0..) |*start, i| start.* += starts[i];
        const items = try sa.alloc(u32, starts[buckets]);
        const Fill = struct {
            next: []u32,
            items: []u32,
            fn add(f: @This(), b: usize, i: u32) void {
                f.items[f.next[b]] = i;
                f.next[b] += 1;
            }
        };
        const next = try sa.dupe(u32, starts[0..buckets]);
        for (0..n) |i| source.each(@intCast(i), Fill{ .next = next, .items = items });
        return .{ .starts = starts, .items = items };
    }
};

/// One large polygon's edges by horizontal band. A rightward ray at height `y`
/// only crosses edges whose y-range holds `y`, and an edge running along a
/// piece holds the piece's midpoint, so the band holding `y` is every edge a
/// probe can count — the others contribute nothing, exactly. Each edge is
/// listed in every band its y-range touches; division is monotone, so an edge
/// whose range holds `y` is listed in `y`'s band.
///
/// Without this, a probe read every edge of every polygon whose box held it:
/// the parcels' 19,208-vertex polygon cost ~19,000 side tests per probe and
/// was probed ~19,000 times walking its own boundary. `relate` over all 4,040
/// parcels took 10.6 s.
const Bands = struct {
    /// Zero for a polygon small enough to scan.
    count: u32 = 0,
    floor: f64 = 0,
    height: f64 = 1,
    /// Edge indices into the operand's `edges`, by band.
    lists: Lists = .{},

    /// Below this a scan is as cheap as a lookup.
    const threshold = 64;

    fn build(sa: std.mem.Allocator, edges: []const [2]g.Coordinate, box: g.Extent, first: u32) !Bands {
        if (edges.len < threshold) return .{};
        const count: u32 = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(edges.len)))));
        var b: Bands = .{ .count = count, .floor = box.min.y, .height = (box.max.y - box.min.y) / @as(f64, @floatFromInt(count)) };
        if (!(b.height > 0)) return .{};
        const Source = struct {
            b: *const Bands,
            edges: []const [2]g.Coordinate,
            first: u32,
            fn span(src: @This(), i: u32) [2]u32 {
                const e = src.edges[i];
                const low = if (e[0].y < e[1].y) e[0].y else e[1].y;
                const high = if (e[0].y > e[1].y) e[0].y else e[1].y;
                return .{ src.b.index(low), src.b.index(high) };
            }
            fn each(src: @This(), i: u32, sink: anytype) void {
                const r = src.span(i);
                for (r[0]..r[1] + 1) |k| sink.add(k, src.first + i);
            }
        };
        const source: Source = .{ .b = &b, .edges = edges, .first = first };
        // Edges spanning most of the bands make the lists no shorter than a
        // scan; give up on banding this polygon.
        var total: usize = 0;
        for (0..edges.len) |i| {
            const r = source.span(@intCast(i));
            total += r[1] - r[0] + 1;
        }
        if (total > 8 * edges.len) return .{};
        b.lists = try Lists.build(sa, count, edges.len, source);
        return b;
    }

    fn index(b: Bands, y: f64) u32 {
        return bucket(y, b.floor, b.height, b.count);
    }
};

/// Polygons by the cells of a square grid over the operand's polygons, so a
/// probe reads the few whose boxes reach its cell rather than every one. A
/// probe used to scan every polygon's box, and on 4,096 parcels against 4,096
/// a `relate` spent a second doing it, ten times what their union costs.
///
/// Each polygon is listed in every cell its box touches. A polygon the size
/// of the operand lists in all of them, so when that makes the lists bigger
/// than sixteen per polygon the grid collapses to one cell, which is the
/// scan it replaces.
const Grid = struct {
    origin: g.Coordinate = .{ .x = 0, .y = 0 },
    cell: g.Coordinate = .{ .x = 1, .y = 1 },
    /// Cells per side.
    side: u32 = 1,
    /// Polygon indices, by cell, rows from the bottom.
    lists: Lists = .{},

    fn build(sa: std.mem.Allocator, boxes: []const g.Extent) !Grid {
        if (boxes.len == 0) return .{};
        var all = boxes[0];
        for (boxes[1..]) |box| all = all.merge(box);
        const span = all.span();
        var grid: Grid = .{ .origin = all.min };
        const root: u32 = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(boxes.len)))));
        grid.side = @max(root, 1);
        grid.cell = .{ .x = span.x / @as(f64, @floatFromInt(grid.side)), .y = span.y / @as(f64, @floatFromInt(grid.side)) };

        var total: usize = 0;
        for (boxes) |box| {
            const r = grid.range(box);
            total += @as(usize, r[1] - r[0] + 1) * (r[3] - r[2] + 1);
        }
        if (total > 16 * boxes.len) {
            grid.side = 1;
            grid.cell = span;
        }
        const Source = struct {
            grid: *const Grid,
            boxes: []const g.Extent,
            fn each(src: @This(), i: u32, sink: anytype) void {
                const r = src.grid.range(src.boxes[i]);
                for (r[2]..r[3] + 1) |y| for (r[0]..r[1] + 1) |x| {
                    sink.add(y * src.grid.side + x, i);
                };
            }
        };
        grid.lists = try Lists.build(sa, @as(usize, grid.side) * grid.side, boxes.len, Source{ .grid = &grid, .boxes = boxes });
        return grid;
    }

    /// The cells a box touches: x from, x to, y from, y to, inclusive.
    fn range(grid: Grid, box: g.Extent) [4]u32 {
        return .{
            bucket(box.min.x, grid.origin.x, grid.cell.x, grid.side),
            bucket(box.max.x, grid.origin.x, grid.cell.x, grid.side),
            bucket(box.min.y, grid.origin.y, grid.cell.y, grid.side),
            bucket(box.max.y, grid.origin.y, grid.cell.y, grid.side),
        };
    }

    /// The polygons whose boxes reach the cell holding `m`.
    fn at(grid: Grid, m: g.Coordinate) []const u32 {
        if (grid.lists.items.len == 0) return &.{};
        const r = grid.range(.{ .min = m, .max = m });
        return grid.lists.at(@as(usize, r[2]) * grid.side + r[0]);
    }
};

/// What a probe learns about one point of an operand: the winding number on
/// either side of it, and whether it lies on one of the operand's lines.
///
/// For a point off every edge, `left` and `right` agree and are the winding
/// number. For the midpoint of a piece they are the windings just left and
/// just right of it, so a piece on a shared edge sees both sides covered and a
/// piece on an ordinary edge sees one. `on_line` is only resolved when the
/// polygons say exterior, since polygon locations take precedence anyway.
const Probe = struct {
    left: i32 = 0,
    right: i32 = 0,
    on_line: bool = false,

    /// Where a piece with this probe lies in the operand, and the dimension
    /// of the thing it lies in.
    fn located(p: Probe) struct { Location, Cell } {
        if (p.left > 0 and p.right > 0) return .{ .interior, .area };
        if (p.left > 0 or p.right > 0) return .{ .boundary, .line };
        if (p.on_line) return .{ .interior, .line };
        return .{ .exterior, .area };
    }
};

/// Whether the edge `t`→`h` runs the same way as `d`. Both are collinear, so
/// one axis decides, and a vertical edge means a vertical `d`.
fn sameWay(t: g.Coordinate, h: g.Coordinate, d: g.Coordinate) bool {
    return if (h.x != t.x) (h.x > t.x) == (d.x > 0) else (h.y > t.y) == (d.y > 0);
}

/// Which edges of an operand a piece runs along, by identity. A crossing is
/// rounded, so the midpoint of a piece between two crossings is not exactly
/// on the line of the segment it came from, let alone on a segment of the
/// other operand that coincides with it; `orient` cannot tell. The exact test
/// on the original coordinates can, and `meet` records what it found, so the
/// probe takes the piece's own segment and the marks of those it overlaps.
/// An overlap is between whole segments, and a piece is cut at every end of
/// every overlapping segment, so the piece lies either inside a marked
/// segment's box or wholly outside it.
const Coincident = struct {
    segments: []const Segment,
    /// Per segment, the segment whose overlaps were marked last.
    marks: []const u32,
    /// The segments running along `own`.
    along: []const u32,
    /// The segment the piece belongs to.
    own: u32,
    /// Where the probed operand's segments start.
    base: u32,
    fn has(c: Coincident, segment: u32) bool {
        return segment == c.own or c.marks[segment] == c.own;
    }
};

/// One edge's contribution to a probe at `m`.
inline fn windingStep(s: *const Set, e: u32, m: g.Coordinate, d: ?g.Coordinate, coincident: ?Coincident, winding: *i32, balance: *i32) void {
    const t = s.edges[e][0];
    const h = s.edges[e][1];
    if (coincident) |c| if (c.has(c.base + e) and g.Extent.of(t, h).has(m)) {
        // Along the piece, with its interior on its left. The step above `m`
        // crosses a leaning edge through `m` as the ray would: an edge moving
        // right as it rises lies right of the stepped point, and counts with
        // its sense.
        balance.* += if (sameWay(t, h, d.?)) 1 else -1;
        if ((h.x > t.x) == (h.y > t.y) and h.x != t.x and h.y != t.y) {
            winding.* += if (h.y > t.y) 1 else -1;
        }
        return;
    };
    // An edge spans `[min y, max y)`, so a vertex sitting exactly on the ray
    // is counted by the edge above it and by no other.
    const up = t.y <= m.y and m.y < h.y;
    const down = h.y <= m.y and m.y < t.y;
    if (!up and !down) return;
    // And the crossing has to be to the right of `m`, which is the side test
    // on the directed edge.
    const side = pred.orient(t, h, m);
    if (if (up) side <= 0 else side >= 0) return;
    winding.* += if (up) 1 else -1;
}

/// Winding and collinearity at `m`, by Sunday's half-open ray cast with the
/// exact side test — the same construction the overlay seeds its labelling
/// from. `d` is the direction of the piece `m` is the midpoint of, or null
/// for a bare point, which is never on an edge when it gets here.
///
/// The half-open rule answers for a point an infinitesimal step above `m`,
/// which for a piece is a point just off one of its sides: the left when the
/// piece runs rightward, the right when it runs leftward, and — since a step
/// above a vertical piece is still on it — the right of an upward vertical
/// piece and the left of a downward one. The edges collinear with the piece
/// are then what separates the two sides: each adds one to the side its
/// polygon's interior is on, so the other side is this one less the balance.
fn probe(s: *const Set, m: g.Coordinate, d: ?g.Coordinate, coincident: ?Coincident) Probe {
    var out: Probe = .{};
    var winding: i32 = 0;
    var balance: i32 = 0;
    const Count = struct {
        s: *const Set,
        m: g.Coordinate,
        d: ?g.Coordinate,
        coincident: ?Coincident,
        winding: *i32,
        balance: *i32,
        fn edge(v: @This(), e: u32) bool {
            windingStep(v.s, e, v.m, v.d, v.coincident, v.winding, v.balance);
            return false;
        }
    };
    _ = s.eachNear(m, Count{ .s = s, .m = m, .d = d, .coincident = coincident, .winding = &winding, .balance = &balance });
    const stepped_left = if (d) |dir| (if (dir.x != 0) dir.x > 0 else dir.y < 0) else true;
    out.left = if (stepped_left) winding else winding + balance;
    out.right = if (stepped_left) winding - balance else winding;
    if (out.left == 0 and out.right == 0) if (coincident) |c| {
        // On a line of this operand: the piece's own, or one running along
        // it that reaches this far.
        const own = c.segments[c.own];
        const set: u1 = @intFromBool(c.base != 0);
        if (own.kind == .line and own.set == set) out.on_line = true;
        for (c.along) |other| {
            const along = c.segments[other];
            if (along.kind == .line and along.set == set and g.Extent.of(along.a, along.b).has(m)) out.on_line = true;
        }
    };
    return out;
}

// --- The arrangement ---------------------------------------------------------

const Kind = enum(u2) { polygon, line, point };

/// Every edge of both operands, in chain order, with a bare point as a
/// zero-length segment so that a point on an edge is found by the same sweep
/// as everything else.
const Segment = struct {
    a: g.Coordinate,
    b: g.Coordinate,
    set: u1,
    kind: Kind,
    /// The node at each end, once nodes exist.
    nodes: [2]u32 = .{ 0, 0 },
};

///
/// With `near`, a segment is kept only when its box reaches `near[k]`, the
/// other operand's extent. That is exact for contacts between the operands —
/// a segment outside the other's extent meets nothing of it — and it is what
/// lets `intersects` of a small query against a whole dataset sweep only the
/// neighbourhood of the query. The arrangement needs every segment, and
/// passes null.
fn collect(sa: std.mem.Allocator, sets: *const [2]Set, limits: g.Limits, near: ?[2]g.Extent) ![]Segment {
    const total = sets[0].segmentCount() + sets[1].segmentCount();
    if (total > limits.max_segments) return error.LimitExceeded;
    const segments = try sa.alloc(Segment, total);
    var n: usize = 0;
    for (sets, 0..) |set, k| {
        const layer: u1 = @intCast(k);
        const keep = struct {
            fn f(box: ?g.Extent, a: g.Coordinate, b: g.Coordinate) bool {
                return if (box) |e| g.Extent.of(a, b).overlaps(e) else true;
            }
        }.f;
        const other: ?g.Extent = if (near) |e| e[k] else null;
        for (set.edges) |e| {
            if (!keep(other, e[0], e[1])) continue;
            segments[n] = .{ .a = e[0], .b = e[1], .set = layer, .kind = .polygon };
            n += 1;
        }
        for (set.lines) |line| for (line[0 .. line.len - 1], line[1..]) |t, h| {
            if (!keep(other, t, h)) continue;
            segments[n] = .{ .a = t, .b = h, .set = layer, .kind = .line };
            n += 1;
        };
        for (set.points) |p| {
            if (!keep(other, p, p)) continue;
            segments[n] = .{ .a = p, .b = p, .set = layer, .kind = .point };
            n += 1;
        }
    }
    return segments[0..n];
}

/// A point where one segment meets another, on the segment named.
const Contact = struct { segment: u32, p: g.Coordinate };
/// One entry in a per-segment linked list: a node on the segment, or
/// another segment running along it.
const Link = struct { value: u32, next: u32 };
/// Everything the sweep records when it is asked to record: the contacts,
/// and per segment the list of segments running along it.
const Found = struct {
    contacts: std.ArrayList(Contact) = .empty,
    along: []u32,
    alongs: std.ArrayList(Link) = .empty,

    fn overlap(f: *Found, sa: std.mem.Allocator, segment: u32, other: u32) !void {
        try f.alongs.append(sa, .{ .value = other, .next = f.along[segment] });
        f.along[segment] = @intCast(f.alongs.items.len - 1);
    }
};

/// Segments in order of their left end, by a counting sort over `n` equal
/// buckets of x. The sweep then only needs the order to be right between
/// buckets: a segment is retired once its right end is left of the current
/// bucket's floor, which is where every later segment starts at the earliest.
/// The overlay sorts its events the same way, and it costs no comparator
/// instantiation — a `pdq` here measured 5.2 KB raw and 2.2 KB gzipped.
const Buckets = struct {
    floor: f64,
    width: f64,
    count: usize,

    fn of(extents: []const g.Extent) Buckets {
        var low = std.math.inf(f64);
        var high = -std.math.inf(f64);
        for (extents) |box| {
            if (box.min.x < low) low = box.min.x;
            if (box.min.x > high) high = box.min.x;
        }
        const count = @max(extents.len, 1);
        return .{ .floor = low, .width = (high - low) / @as(f64, @floatFromInt(count)), .count = count };
    }
    fn index(b: Buckets, x: f64) u32 {
        return bucket(x, b.floor, b.width, b.count);
    }
    /// The smallest left end any segment in bucket `i` can have.
    fn start(b: Buckets, i: usize) f64 {
        return b.floor + @as(f64, @floatFromInt(i)) * b.width;
    }
    /// Segment indices in order of bucket.
    fn order(b: Buckets, sa: std.mem.Allocator, extents: []const g.Extent) ![]const u32 {
        const Source = struct {
            b: Buckets,
            extents: []const g.Extent,
            fn each(src: @This(), i: u32, sink: anytype) void {
                sink.add(src.b.index(src.extents[i].min.x), i);
            }
        };
        return (try Lists.build(sa, b.count, extents.len, Source{ .b = b, .extents = extents })).items;
    }
};

/// Every contact between segments, by a sweep on x: a segment is tested
/// against the ones still open at its left end whose y-ranges reach it, then
/// opened itself. `cross_only` limits the pairs to one segment from each
/// operand, which is all `intersects` needs; with `found` null the first
/// contact ends the sweep, otherwise every contact is recorded. Returns
/// whether any was found.
fn contacts(sa: std.mem.Allocator, segments: []Segment, cross_only: bool, found: ?*Found, limits: g.Limits) !bool {
    const extents = try sa.alloc(g.Extent, segments.len);
    for (segments, extents) |s, *box| box.* = g.Extent.of(s.a, s.b);
    const buckets = Buckets.of(extents);
    const order = try buckets.order(sa, extents);

    var active: std.ArrayList(u32) = .empty;
    var any = false;
    var work: usize = 0;
    for (order) |i| {
        const box = extents[i];
        const retire = buckets.start(buckets.index(box.min.x));
        var k: usize = 0;
        while (k < active.items.len) {
            const j = active.items[k];
            if (extents[j].max.x < retire) {
                _ = active.swapRemove(k);
                continue;
            }
            k += 1;
            if (cross_only and segments[j].set == segments[i].set) continue;
            if (extents[j].min.y > box.max.y or extents[j].max.y < box.min.y) continue;
            if (extents[j].max.x < box.min.x or extents[j].min.x > box.max.x) continue;
            work += 1;
            if (work > limits.max_work) return error.LimitExceeded;
            if (try meet(sa, segments, i, j, found)) {
                if (found == null) return true;
                any = true;
            }
        }
        try active.append(sa, i);
    }
    return any;
}

/// Whether segments `pi` and `qi` share a point, recording where on each
/// when `found` is given. A proper crossing is the rounded exact intersection;
/// everything else — an endpoint on the other segment, two endpoints meeting,
/// a collinear overlap — is an endpoint of one lying on the other, and those
/// are exact.
fn meet(sa: std.mem.Allocator, segments: []const Segment, pi: u32, qi: u32, found: ?*Found) !bool {
    const p = segments[pi];
    const q = segments[qi];
    const o = pred.orient2(p.a, p.b, q.a, q.b);
    if (@as(i3, o[0]) * o[1] > 0) return false;
    const r = pred.orient2(q.a, q.b, p.a, p.b);
    if (@as(i3, r[0]) * r[1] > 0) return false;
    if (o[0] != 0 and o[1] != 0 and r[0] != 0 and r[1] != 0) {
        if (found) |f| {
            // The rounding depends on the argument order, so two segments
            // that coincide — one from each operand, say — have to see their
            // crossing with a third computed from the same arguments, or they
            // split at two nodes an ulp apart. Lowest endpoint first, lowest
            // segment first, makes the order a property of the coordinates.
            const pe = canonical(p);
            const qe = canonical(q);
            const x = if (lexLess(pe[0], qe[0]) or (g.equal(pe[0], qe[0]) and lexLess(pe[1], qe[1])))
                pred.intersection(pe[0], pe[1], qe[0], qe[1])
            else
                pred.intersection(qe[0], qe[1], pe[0], pe[1]);
            try f.contacts.append(sa, .{ .segment = pi, .p = x });
            try f.contacts.append(sa, .{ .segment = qi, .p = x });
        }
        return true;
    }
    // Not a proper crossing, so any shared point is an endpoint of one on the
    // line of the other — and on the line, inside the box means on the segment.
    const pe = g.Extent.of(p.a, p.b);
    const qe = g.Extent.of(q.a, q.b);
    var any = false;
    const ends = [4]struct { on: bool, segment: u32, p: g.Coordinate }{
        .{ .on = o[0] == 0 and pe.has(q.a), .segment = pi, .p = q.a },
        .{ .on = o[1] == 0 and pe.has(q.b), .segment = pi, .p = q.b },
        .{ .on = r[0] == 0 and qe.has(p.a), .segment = qi, .p = p.a },
        .{ .on = r[1] == 0 and qe.has(p.b), .segment = qi, .p = p.b },
    };
    for (ends) |end| {
        if (!end.on) continue;
        any = true;
        if (found) |f| try f.contacts.append(sa, .{ .segment = end.segment, .p = end.p });
    }
    // All four on one line and touching: they run along each other, and the
    // pieces inside the overlap need to know it by identity.
    if (any and o[0] == 0 and o[1] == 0 and p.kind != .point and q.kind != .point) {
        if (found) |f| {
            try f.overlap(sa, pi, qi);
            try f.overlap(sa, qi, pi);
        }
    }
    return any;
}

fn canonical(s: Segment) [2]g.Coordinate {
    return if (lexLess(s.a, s.b)) .{ s.a, s.b } else .{ s.b, s.a };
}

/// What is known about a node from one operand's point of view.
const Flags = packed struct(u8) {
    /// An edge of one of the operand's polygons passes through or ends here.
    polygon: bool = false,
    /// Some such edge has an uncovered side here, so the node is boundary
    /// rather than interior of the union.
    boundary: bool = false,
    line: bool = false,
    /// An odd number of the operand's lines end here: a boundary point.
    odd_ends: bool = false,
    point: bool = false,
    /// Off every polygon edge, is the node inside the operand's polygons?
    /// Written by the first piece that leaves it, since a piece that crosses
    /// no edge of the operand lies in the same region as its ends.
    region: bool = false,
    _: u2 = 0,
};

const Node = struct {
    p: g.Coordinate,
    /// Incident segment ends per operand, a split counting twice. A piece's
    /// probe stays valid across a node that no other segment of that operand
    /// reaches, which is what this is compared against.
    degree: [2]u32 = .{ 0, 0 },
    flags: [2]Flags = .{ .{}, .{} },

    fn locate(n: Node, k: usize) struct { Location, Cell } {
        const f = n.flags[k];
        if (f.polygon) return if (f.boundary) .{ .boundary, .line } else .{ .interior, .area };
        if (f.region) return .{ .interior, .area };
        if (f.line) return if (f.odd_ends) .{ .boundary, .point } else .{ .interior, .line };
        if (f.point) return .{ .interior, .point };
        return .{ .exterior, .area };
    }
};

const none = std.math.maxInt(u32);

const Arrangement = struct {
    sets: [2]Set,
    segments: []Segment,
    nodes: []Node,
    count: usize = 0,
    map: sweep.Vertices.Map,
    /// Per segment, the head of its list of interior nodes.
    heads: []u32,
    splits: std.ArrayList(Link) = .empty,
    /// Per segment, the head of its list of segments running along it.
    along: []u32,
    alongs: std.ArrayList(Link) = .empty,
    /// `Coincident.marks`.
    marks: []u32,
    /// Where each operand's segments start.
    base: [2]u32,
    sa: std.mem.Allocator,

    fn build(sa: std.mem.Allocator, unindexed: [2]Set, limits: g.Limits) !Arrangement {
        var sets = unindexed;
        for (&sets) |*set| try set.index(sa);
        const segments = try collect(sa, &sets, limits, null);
        var found: Found = .{ .along = try sa.alloc(u32, segments.len) };
        @memset(found.along, none);
        _ = try contacts(sa, segments, false, &found, limits);

        // Two ends per segment and one node per contact bound the nodes, so
        // the map is sized once and never grows.
        const upper = 2 * segments.len + found.contacts.items.len;
        if (upper > limits.max_nodes) return error.LimitExceeded;
        var map: sweep.Vertices.Map = .empty;
        try map.ensureTotalCapacity(sa, @intCast(upper));
        var self: Arrangement = .{
            .sets = sets,
            .segments = segments,
            .nodes = try sa.alloc(Node, upper),
            .map = map,
            .heads = try sa.alloc(u32, segments.len),
            .along = found.along,
            .alongs = found.alongs,
            .marks = try sa.alloc(u32, segments.len),
            .base = .{ 0, @intCast(sets[0].segmentCount()) },
            .sa = sa,
        };
        @memset(self.heads, none);
        @memset(self.marks, none);

        for (segments) |*s| {
            s.nodes = .{ self.id(s.a), self.id(s.b) };
            for (s.nodes) |n| {
                const f = &self.nodes[n].flags[s.set];
                switch (s.kind) {
                    .polygon => f.polygon = true,
                    .line => f.line = true,
                    .point => f.point = true,
                }
                if (s.kind != .point) self.nodes[n].degree[s.set] += 1;
            }
        }
        for (sets, 0..) |set, k| for (set.lines) |line| {
            // Each end of each line toggles its node: a closed line, or two
            // lines meeting end to end, leave no boundary there.
            for (g.ends(line)) |end| {
                const f = &self.nodes[self.id(end)].flags[k];
                f.odd_ends = !f.odd_ends;
            }
        };
        for (found.contacts.items) |contact| {
            const n = self.id(contact.p);
            const s = &segments[contact.segment];
            // A contact at a segment's own end is that end, already a node.
            if (n == s.nodes[0] or n == s.nodes[1]) continue;
            try self.splits.append(sa, .{ .value = n, .next = self.heads[contact.segment] });
            self.heads[contact.segment] = @intCast(self.splits.items.len - 1);
            self.nodes[n].degree[s.set] += 2;
            switch (s.kind) {
                .polygon => self.nodes[n].flags[s.set].polygon = true,
                .line => self.nodes[n].flags[s.set].line = true,
                .point => {},
            }
        }
        return self;
    }

    fn id(self: *Arrangement, p: g.Coordinate) u32 {
        // Signed zero would split one point into two nodes; `keyOf` folds it.
        const found = self.map.getOrPutAssumeCapacity(keyOf(p));
        if (!found.found_existing) {
            found.value_ptr.* = @intCast(self.count);
            self.nodes[self.count] = .{ .p = p };
            self.count += 1;
        }
        return found.value_ptr.*;
    }

    /// The matrix, complete — or, given a pattern, only as far as deciding
    /// it, since every cell only grows from here.
    fn matrix(self: *Arrangement, pattern: ?Pattern) !Matrix {
        var m: Matrix = .{ .dims = .{ self.sets[0].dimension(), self.sets[1].dimension() } };
        // The exteriors always meet: both operands are bounded.
        m.raise(.exterior, .exterior, .area);
        // A pattern that can only fail on the second operand's cells —
        // `contains`, with its `F`s in the exterior row — is decided by the
        // second operand's pieces, so those are walked first.
        const second_first = if (pattern) |p| p.codes[6] == .empty or p.codes[7] == .empty else false;
        for ([2]usize{ 0, 1 }) |step| {
            const k = if (second_first) 1 - step else step;
            const set = self.sets[k];
            var cursor: usize = self.base[k];
            for (set.polygons) |polygon| for (polygon.rings) |ring| {
                if (try self.walk(&m, pattern, cursor, ring.len - 1, k, .polygon)) return m;
                cursor += ring.len - 1;
            };
            for (set.lines) |line| {
                if (try self.walk(&m, pattern, cursor, line.len - 1, k, .line)) return m;
                cursor += line.len - 1;
            }
        }

        for (self.nodes[0..self.count]) |*node| {
            // A node no segment reaches is a bare point clear of everything,
            // and the only node whose region nothing has written.
            if (node.degree[0] == 0 and node.degree[1] == 0) {
                for (0..2) |k| node.flags[k].region = probe(&self.sets[k], node.p, null, null).left > 0;
            }
            const one = node.locate(0);
            const two = node.locate(1);
            // A point in two open regions is in their open overlap; in one
            // open region it meets the other's thing on that thing's own
            // terms; and two lower-dimensional things meet in a point here —
            // where they run together, the piece along them says so.
            const cell: Cell = if (one[1] == .area and two[1] == .area)
                .area
            else if (one[1] == .area or two[1] == .area)
                one[1].lower(two[1])
            else
                .point;
            m.raise(one[0], two[0], cell);
            if (decided(&m, pattern)) return m;
        }
        return m;
    }

    fn decided(m: *const Matrix, pattern: ?Pattern) bool {
        return if (pattern) |p| p.verdict(m.*, false) != .undecided else false;
    }

    /// One chain — a ring or a line — of operand `k`, starting at segment
    /// `first`: cut each segment into pieces at its nodes, probe each piece in
    /// both operands, and add what each piece and its two sides contribute.
    ///
    /// A probe is reused along the chain until a node that another segment of
    /// that operand reaches, because a piece that crosses no edge of an
    /// operand is in the same region as the piece before it.
    ///
    /// Returns true when the pattern is decided, which ends the walk.
    fn walk(self: *Arrangement, m: *Matrix, pattern: ?Pattern, first: usize, length: usize, k: usize, kind: Kind) !bool {
        var cache: [2]Probe = undefined;
        var valid: [2]bool = .{ false, false };
        var order: std.ArrayList(u32) = .empty;
        var nearby: std.ArrayList(u32) = .empty;
        for (self.segments[first..][0..length], 0..) |s, i| {
            const own: u32 = @intCast(first + i);
            nearby.clearRetainingCapacity();
            var at_along = self.along[own];
            while (at_along != none) : (at_along = self.alongs.items[at_along].next) {
                const other = self.alongs.items[at_along].value;
                self.marks[other] = own;
                try nearby.append(self.sa, other);
            }
            order.clearRetainingCapacity();
            try order.append(self.sa, s.nodes[0]);
            var at = self.heads[first + i];
            while (at != none) : (at = self.splits.items[at].next) {
                try order.append(self.sa, self.splits.items[at].value);
            }
            try order.append(self.sa, s.nodes[1]);
            self.sortAlong(order.items, lexLess(s.a, s.b));

            for (order.items[0 .. order.items.len - 1], order.items[1..], 1..) |u, v, next| {
                // A crossing rounded onto another node makes an empty piece.
                if (u != v) {
                    const p = self.nodes[u].p;
                    const q = self.nodes[v].p;
                    const mid: g.Coordinate = .{ .x = (p.x + q.x) / 2, .y = (p.y + q.y) / 2 };
                    const d: g.Coordinate = .{ .x = q.x - p.x, .y = q.y - p.y };
                    for (0..2) |j| if (!valid[j]) {
                        cache[j] = probe(&self.sets[j], mid, d, .{
                            .segments = self.segments,
                            .marks = self.marks,
                            .along = nearby.items,
                            .own = own,
                            .base = self.base[j],
                        });
                        valid[j] = true;
                    };
                    self.piece(m, cache, u, v, k, kind);
                    if (decided(m, pattern)) return true;
                }
                // The chain's own two ends at `v`: one at the end of a line.
                const ends: u32 = if (kind == .line and i + 1 == length and next == order.items.len - 1) 1 else 2;
                for (0..2) |j| {
                    if (self.nodes[v].degree[j] > (if (j == k) ends else 0)) valid[j] = false;
                }
            }
        }
        return false;
    }

    fn piece(self: *Arrangement, m: *Matrix, cache: [2]Probe, u: u32, v: u32, k: usize, kind: Kind) void {
        const one = cache[0].located();
        const two = cache[1].located();
        m.raise(one[0], two[0], one[1].lower(two[1]));
        // The regions either side of the piece are open, so they fill a
        // two-dimensional cell between them.
        m.raise(side(cache[0].left), side(cache[1].left), .area);
        m.raise(side(cache[0].right), side(cache[1].right), .area);
        for ([_]u32{ u, v }) |n| {
            for (0..2) |j| self.nodes[n].flags[j].region = cache[j].left > 0 or cache[j].right > 0;
            if (kind == .polygon and (cache[k].left == 0 or cache[k].right == 0)) self.nodes[n].flags[k].boundary = true;
        }
    }

    fn side(winding: i32) Location {
        return if (winding > 0) .interior else .exterior;
    }

    /// The nodes of one segment in order along it. The list is short — its
    /// ends plus whatever crosses it — so an insertion sort is the whole of
    /// what it needs.
    fn sortAlong(self: *Arrangement, ids: []u32, ascending: bool) void {
        for (1..ids.len) |i| {
            var j = i;
            while (j > 0) : (j -= 1) {
                const p = self.nodes[ids[j - 1]].p;
                const q = self.nodes[ids[j]].p;
                if (lexLess(p, q) == ascending or g.equal(p, q)) break;
                std.mem.swap(u32, &ids[j - 1], &ids[j]);
            }
        }
    }
};

fn lexLess(p: g.Coordinate, q: g.Coordinate) bool {
    return p.x < q.x or (p.x == q.x and p.y < q.y);
}

test "the point fast path agrees with the arrangement, cell for cell" {
    const a = std.testing.allocator;
    const C = g.Coordinate;
    const square = [_]C{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 10 }, .{ .x = 0, .y = 10 }, .{ .x = 0, .y = 0 } };
    const hole = [_]C{ .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 7 }, .{ .x = 7, .y = 7 }, .{ .x = 7, .y = 3 }, .{ .x = 3, .y = 3 } };
    const beside = [_]C{ .{ .x = 10, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 20, .y = 10 }, .{ .x = 10, .y = 10 }, .{ .x = 10, .y = 0 } };
    const tilted = [_]C{ .{ .x = 25, .y = 0 }, .{ .x = 35, .y = 5 }, .{ .x = 25, .y = 10 }, .{ .x = 25, .y = 0 } };
    const donut = [_]g.LinearRing{ &square, &hole };
    const one = [_]g.LinearRing{&beside};
    const three = [_]g.LinearRing{&tilted};
    const polygons = [_]g.Polygon{ .{ .rings = &donut }, .{ .rings = &one }, .{ .rings = &three } };

    const open = [_]C{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, .{ .x = 8, .y = 0 } };
    const joined = [_]C{ .{ .x = 8, .y = 0 }, .{ .x = 12, .y = 0 } };
    const closed = [_]C{ .{ .x = 20, .y = 20 }, .{ .x = 24, .y = 20 }, .{ .x = 24, .y = 24 }, .{ .x = 20, .y = 20 } };
    const crossing = [_]C{ .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 8 } };
    const lines = [_]g.LineString{ &open, &joined, &closed, &crossing };

    // Interior, in a hole, outside, on a slanted interior point, at a line's
    // free end, at the joint of two lines, on a closed line, where two lines
    // cross, on a line's interior, and on polygon edges and vertices — which
    // the fast path must hand back to the arrangement.
    const probes = [_]C{
        .{ .x = 1, .y = 1 },  .{ .x = 5, .y = 5 },  .{ .x = 50, .y = 50 },  .{ .x = 28, .y = 5 },
        .{ .x = 0, .y = 0 },  .{ .x = 8, .y = 0 },  .{ .x = 22, .y = 20 },  .{ .x = 4, .y = 4 },
        .{ .x = 2, .y = 2 },  .{ .x = 12, .y = 0 }, .{ .x = 10, .y = 5 },   .{ .x = 10, .y = 10 },
        .{ .x = 3, .y = 5 },  .{ .x = 35, .y = 5 }, .{ .x = 30, .y = 2.5 }, .{ .x = 15, .y = 5 },
        .{ .x = -1, .y = 5 }, .{ .x = 6, .y = 2 },
    };
    const others = [_]Collection{
        .{ .polygons = &polygons },
        .{ .line_strings = &lines },
        .{ .points = probes[0..5] },
        .{},
    };
    var compared: usize = 0;
    var fast: usize = 0;
    // One point at a time, and all of them at once (past the index threshold).
    var subsets: [probes.len + 1][]const C = undefined;
    for (probes, 0..) |_, i| subsets[i] = probes[i .. i + 1];
    subsets[probes.len] = &probes;
    for (others) |other| for (subsets) |pts| for ([_]bool{ false, true }) |swapped| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const sa = arena.allocator();
        const points: Collection = .{ .points = pts };
        const pair: [2]Collection = if (swapped) .{ other, points } else .{ points, other };
        var sets = try prepare(sa, pair[0], pair[1], .{});
        const quick = try pointMatrix(sa, &sets);
        var arrangement = try Arrangement.build(sa, try prepare(sa, pair[0], pair[1], .{}), .{});
        const full = try arrangement.matrix(null);
        if (quick) |m| {
            fast += 1;
            std.testing.expectEqualStrings(&full.string(), &m.string()) catch |err| {
                std.debug.print("swapped={} points={any}\n", .{ swapped, pts });
                return err;
            };
            try std.testing.expectEqual(full.dims, m.dims);
        }
        compared += 1;
    };
    // Most cases take the fast path; the edge and vertex points do not.
    try std.testing.expect(fast > compared / 2);
}
