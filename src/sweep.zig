// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Degenerate-tolerant Martinez-Rueda boolean overlay.
//!
//! Four departures from the textbook algorithm, each aimed at real cadastral
//! input rather than at the well-formed two-operand case the paper assumes:
//!
//!   * **Winding counts, not in/out parity.** Every layer carries an `i32` depth
//!     instead of a boolean. Any number of polygons may be handed to a layer and
//!     they may overlap, stack, or share edges. This deletes the whole
//!     SAME_TRANSITION / DIFFERENT_TRANSITION / NON_CONTRIBUTING edge
//!     classification — the buggiest part of every Martinez implementation —
//!     because coincident edges simply keep both contributions and let their
//!     deltas cancel. Adjacent parcels sharing a boundary are the common case
//!     here, not an error to be detected.
//!   * **No vertical special case.** Ordering events lexicographically by (x, y)
//!     is exactly the symbolic shear (x, y) -> (x + ey, y). A shear has unit
//!     determinant, so it leaves every orientation predicate unchanged while
//!     giving vertical segments a well-defined place in the status line. No
//!     coordinate is ever actually perturbed.
//!   * **Exact predicates at every sign decision.** Ordering, collinearity and
//!     crossing tests all go through the adaptive predicates. There is no
//!     tolerance anywhere in the sweep.
//!   * **Structure of arrays.** Sweep-hot endpoints live in their own dense
//!     array, and each event carries an order-preserving u128 key so queue and
//!     status comparisons start from one integer compare.
const std = @import("std");
const g = @import("geometry.zig");
const pred = @import("predicates.zig");
const A = std.mem.Allocator;
const none = std.math.maxInt(u32);

pub const Path = g.Path;
pub const Mode = g.Mode;
pub const Limits = g.Limits;

/// -0.0 and 0.0 must be one vertex, or the sort key stops being injective.
fn canonical(p: g.Coordinate) g.Coordinate {
    return .{ .x = if (p.x == 0) 0 else p.x, .y = if (p.y == 0) 0 else p.y };
}

/// Order-preserving f64 pair -> u128, so lexicographic (x, y) comparison is a
/// single integer compare. Both lanes are mapped with one vector operation.
fn keyOf(p: g.Coordinate) u128 {
    const V = @Vector(2, u64);
    const bits: V = @bitCast(@Vector(2, f64){ p.x, p.y });
    const top: V = @splat(@as(u64, 1) << 63);
    const flipped = @select(u64, (bits & top) != @as(V, @splat(0)), ~bits, bits | top);
    return (@as(u128, flipped[0]) << 64) | flipped[1];
}

const Event = struct {
    key: u128,
    other: u32,
    left: bool,
    layer: u1,
    /// Winding added to `layer` by crossing this edge upwards: +1 when the
    /// source edge runs from the lexicographically smaller endpoint to the
    /// larger one, -1 otherwise. Coincident edges accumulate here rather than
    /// being classified away, which is what lets shared parcel boundaries
    /// cancel instead of producing a spurious pair of result edges.
    delta: [2]i32 = .{ 0, 0 },
    /// Events holding the endpoints of the *input* edge this segment was cut
    /// from. Subdivision replaces a segment's own endpoints with constructed
    /// points, which shifts its supporting line by a rounding step; crossings
    /// are computed from these instead so that one geometric crossing yields
    /// exactly one vertex however the pieces were cut. This is what the graph
    /// backend gets for free by never subdividing its segment objects.
    sa: u32 = 0,
    sb: u32 = 0,
    below: [2]i32 = .{ 0, 0 },
    /// Status-line predecessor at insertion time. Nesting walks this chain.
    prev: u32 = none,
    /// 0 outside the result, +1 with the filled side above, -1 with it below.
    /// Settled at the closing event, once every subdivision that can touch this
    /// segment has happened and any coincident partners are exactly equal.
    transition: i8 = 0,
    resolved: bool = false,
    contour: u32 = none,
};

const Engine = struct {
    a: A,
    limits: Limits,
    mode: Mode,
    work: usize = 0,
    p: std.ArrayList(g.Coordinate) = .empty,
    e: std.ArrayList(Event) = .empty,
    /// Events known before the sweep starts, sorted once. Subdivision events go
    /// to `heap`; `next` merges the two streams.
    initial: []u32 = &.{},
    cursor: usize = 0,
    heap: std.ArrayList(u32) = .empty,
    status: std.ArrayList(u32) = .empty,
    /// Reused snapshot buffer for run-versus-run subdivision.
    snapshot: std.ArrayList([2]g.Coordinate) = .empty,

    fn tick(en: *Engine) !void {
        if (en.work == en.limits.max_work) return error.LimitExceeded;
        en.work += 1;
    }

    fn addEvent(en: *Engine, p: g.Coordinate, ev: Event) !u32 {
        if (!g.finite(p)) return error.CoordinateRange;
        if (en.e.items.len >= @min(en.limits.max_nodes, none - 1)) return error.LimitExceeded;
        const id: u32 = @intCast(en.e.items.len);
        try en.p.append(en.a, p);
        try en.e.append(en.a, ev);
        return id;
    }

    fn addSegment(en: *Engine, from: g.Coordinate, to: g.Coordinate, layer: u1) !void {
        const a = canonical(from);
        const b = canonical(to);
        if (g.equal(a, b)) return;
        const ka = keyOf(a);
        const kb = keyOf(b);
        const up = ka < kb;
        var delta: [2]i32 = .{ 0, 0 };
        delta[layer] = if (up) 1 else -1;
        const l = try en.addEvent(if (up) a else b, .{
            .key = if (up) ka else kb,
            .other = 0,
            .left = true,
            .layer = layer,
            .delta = delta,
        });
        const r = try en.addEvent(if (up) b else a, .{
            .key = if (up) kb else ka,
            .other = l,
            .left = false,
            .layer = layer,
            .delta = delta,
        });
        en.e.items[l].other = r;
        en.e.items[l].sa = l;
        en.e.items[l].sb = r;
        en.e.items[r].sa = l;
        en.e.items[r].sb = r;
    }

    /// Sweep order: lexicographic position, then closing before opening, then
    /// bottom-to-top so the status line is built upwards at a shared point.
    fn eventLess(en: *const Engine, i: u32, j: u32) bool {
        if (i == j) return false;
        const ei = en.e.items[i];
        const ej = en.e.items[j];
        if (ei.key != ej.key) return ei.key < ej.key;
        if (ei.left != ej.left) return !ei.left;
        const turn = pred.orient(en.p.items[i], en.p.items[ei.other], en.p.items[ej.other]);
        if (turn != 0) return if (ei.left) turn > 0 else turn < 0;
        // Collinear at a shared point. This must agree with `segmentLess`, or a
        // segment gets inserted above one that belongs below it and inherits the
        // wrong winding from a predecessor it should never have had.
        const ri = en.e.items[ei.other].key;
        const rj = en.e.items[ej.other].key;
        if (ri != rj) return if (ei.left) ri < rj else ri > rj;
        if (ei.layer != ej.layer) return ei.layer < ej.layer;
        return i < j;
    }

    fn push(en: *Engine, id: u32) !void {
        try en.heap.append(en.a, id);
        var child = en.heap.items.len - 1;
        while (child > 0) {
            const parent = (child - 1) / 2;
            if (!en.eventLess(en.heap.items[child], en.heap.items[parent])) break;
            std.mem.swap(u32, &en.heap.items[child], &en.heap.items[parent]);
            child = parent;
        }
    }

    fn popHeap(en: *Engine) u32 {
        const top = en.heap.items[0];
        const last = en.heap.items[en.heap.items.len - 1];
        en.heap.items.len -= 1;
        if (en.heap.items.len != 0) {
            en.heap.items[0] = last;
            var parent: usize = 0;
            while (true) {
                const left = 2 * parent + 1;
                var best = parent;
                if (left < en.heap.items.len and en.eventLess(en.heap.items[left], en.heap.items[best])) best = left;
                if (left + 1 < en.heap.items.len and en.eventLess(en.heap.items[left + 1], en.heap.items[best])) best = left + 1;
                if (best == parent) break;
                std.mem.swap(u32, &en.heap.items[parent], &en.heap.items[best]);
                parent = best;
            }
        }
        return top;
    }

    fn peek(en: *const Engine) ?u32 {
        const more = en.cursor < en.initial.len;
        if (en.heap.items.len == 0) return if (more) en.initial[en.cursor] else null;
        if (more and en.eventLess(en.initial[en.cursor], en.heap.items[0])) return en.initial[en.cursor];
        return en.heap.items[0];
    }

    fn next(en: *Engine) ?u32 {
        const chosen = en.peek() orelse return null;
        if (en.cursor < en.initial.len and en.initial[en.cursor] == chosen) {
            en.cursor += 1;
            return chosen;
        }
        return en.popHeap();
    }

    /// Status order at the sheared sweep line. Both directions take the branch
    /// keyed on the earlier left endpoint, so the comparison is antisymmetric by
    /// construction rather than by hoping two formulas agree.
    fn segmentLess(en: *const Engine, i: u32, j: u32) bool {
        if (i == j) return false;
        const ei = en.e.items[i];
        const ej = en.e.items[j];
        if (ei.key <= ej.key) {
            const o = pred.orient2(en.p.items[i], en.p.items[ei.other], en.p.items[j], en.p.items[ej.other]);
            if (o[0] != 0) return o[0] > 0;
            if (o[1] != 0) return o[1] > 0;
        } else {
            const o = pred.orient2(en.p.items[j], en.p.items[ej.other], en.p.items[i], en.p.items[ei.other]);
            if (o[0] != 0) return o[0] < 0;
            if (o[1] != 0) return o[1] < 0;
        }
        // Collinear supporting lines. Order by position along the line, which
        // for a shared vertical line is the only thing that keeps two disjoint
        // segments the right way up, and which makes coincident segments
        // contiguous so a bundle can be recognised at its closing event.
        if (ei.key != ej.key) return ei.key < ej.key;
        const ri = en.e.items[ei.other].key;
        const rj = en.e.items[ej.other].key;
        if (ri != rj) return ri < rj;
        if (ei.layer != ej.layer) return ei.layer < ej.layer;
        return i < j;
    }

    fn runStart(en: *const Engine, at: usize) usize {
        var low = at;
        while (low > 0 and en.shares(en.status.items[low - 1], en.status.items[low])) low -= 1;
        return low;
    }

    fn runEnd(en: *const Engine, at: usize) usize {
        var high = at;
        while (high + 1 < en.status.items.len and en.shares(en.status.items[high], en.status.items[high + 1])) high += 1;
        return high;
    }

    fn statusSeek(en: *const Engine, id: u32) usize {
        var low: usize = 0;
        var high: usize = en.status.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (en.segmentLess(en.status.items[mid], id)) low = mid + 1 else high = mid;
        }
        return low;
    }

    fn statusFind(en: *const Engine, id: u32) !usize {
        const at = en.statusSeek(id);
        if (at < en.status.items.len and en.status.items[at] == id) return at;
        // Only reachable if the ordering is not a strict weak order, which is a
        // bug rather than a data condition. Fail loudly instead of corrupting.
        for (en.status.items, 0..) |v, k| if (v == id) return k;
        return error.NodingFailure;
    }

    fn filled(en: *const Engine, w: [2]i32) bool {
        return en.mode.covers(w);
    }

    /// Two active segments lie on one line and share more than a point, so
    /// they bound the same region and must not be read as one being above the
    /// other. Subdivision has usually not caught up at the moment a segment is
    /// inserted, which is exactly when this matters.
    fn shares(en: *const Engine, i: u32, j: u32) bool {
        const ei = en.e.items[i];
        const ej = en.e.items[j];
        const o = pred.orient2(en.p.items[i], en.p.items[ei.other], en.p.items[j], en.p.items[ej.other]);
        if (o[0] != 0 or o[1] != 0) return false;
        return @max(ei.key, ej.key) < @min(en.e.items[ei.other].key, en.e.items[ej.other].key);
    }

    /// Winding immediately below the newly inserted segment. Anything it
    /// overlaps is skipped, then the run underneath contributes every one of
    /// its deltas, because a run's members all share one lower region.
    fn enter(en: *Engine, id: u32, at: usize) void {
        var k = at;
        while (k > 0 and en.shares(en.status.items[k - 1], id)) k -= 1;
        const ev = &en.e.items[id];
        if (k == 0) {
            ev.below = .{ 0, 0 };
            ev.prev = none;
            return;
        }
        var low = k - 1;
        while (low > 0 and en.shares(en.status.items[low - 1], en.status.items[low])) low -= 1;
        var below = en.e.items[en.status.items[low]].below;
        for (en.status.items[low..k]) |member| {
            below[0] += en.e.items[member].delta[0];
            below[1] += en.e.items[member].delta[1];
        }
        ev.below = below;
        ev.prev = en.status.items[k - 1];
    }

    fn sameSegment(en: *const Engine, i: u32, j: u32) bool {
        return en.e.items[i].key == en.e.items[j].key and
            en.e.items[en.e.items[i].other].key == en.e.items[en.e.items[j].other].key;
    }

    /// Settle the fill transition for the run of exactly coincident segments
    /// around `at`. Their windings are summed and only the topmost member can
    /// carry a result edge, so two parcels sharing a boundary contribute one
    /// bundle whose deltas cancel rather than two opposed result edges.
    fn resolve(en: *Engine, at: usize) void {
        var low = at;
        while (low > 0 and en.sameSegment(en.status.items[low - 1], en.status.items[at])) low -= 1;
        var high = at;
        while (high + 1 < en.status.items.len and en.sameSegment(en.status.items[high + 1], en.status.items[at])) high += 1;
        // Sum the bundle's own deltas rather than reading the topmost member's
        // cached `below`: a member inserted later can sit underneath one already
        // present, which leaves the upper member's cached value behind.
        var above = en.e.items[en.status.items[low]].below;
        for (en.status.items[low .. high + 1]) |member| {
            const m = &en.e.items[member];
            above[0] += m.delta[0];
            above[1] += m.delta[1];
            m.transition = 0;
            m.resolved = true;
        }
        const inside_above = en.filled(above);
        const inside_below = en.filled(en.e.items[en.status.items[low]].below);
        const carrier = &en.e.items[en.status.items[high]];
        carrier.transition = if (inside_above == inside_below) 0 else if (inside_above) @as(i8, 1) else -1;
    }

    fn divideOne(en: *Engine, id: u32, x: g.Coordinate, key: u128) !void {
        const right = en.e.items[id].other;
        // Rejects both "the split point is an endpoint" and "rounding put it
        // outside the segment's span", so no left/right flag repair is needed.
        if (key <= en.e.items[id].key or key >= en.e.items[right].key) return;
        const ev = en.e.items[id];
        const closing = try en.addEvent(x, .{ .key = key, .other = id, .left = false, .layer = ev.layer, .delta = ev.delta, .sa = ev.sa, .sb = ev.sb });
        const opening = try en.addEvent(x, .{ .key = key, .other = right, .left = true, .layer = ev.layer, .delta = ev.delta, .sa = ev.sa, .sb = ev.sb });
        en.e.items[right].other = opening;
        en.e.items[id].other = closing;
        try en.push(closing);
        try en.push(opening);
    }

    /// Divide a segment and every exact duplicate of it currently on the status
    /// line, at one point.
    ///
    /// Two parcels sharing a boundary put the identical segment into the sweep
    /// twice, and a crossing lands on it at a point that rounding places on
    /// neither copy's line. Whichever copy is divided first, no later exact test
    /// can rediscover the crossing on its twin, and the pair stops being
    /// coincident — so their windings never cancel and a boundary that should
    /// have vanished emerges as a lone unpaired result edge. Duplicates are one
    /// geometric object; they are divided as one here rather than left to be
    /// re-derived from coordinates that no longer agree.
    fn divide(en: *Engine, id: u32, raw: g.Coordinate) !void {
        const x = canonical(raw);
        const key = keyOf(x);
        if (key <= en.e.items[id].key or key >= en.e.items[en.e.items[id].other].key) return;
        const at = en.statusSeek(id);
        if (at >= en.status.items.len or en.status.items[at] != id) return en.divideOne(id, x, key);
        // Duplicates are contiguous, and the run must be measured before any of
        // it is divided.
        var low = at;
        while (low > 0 and en.sameSegment(en.status.items[low - 1], id)) low -= 1;
        var high = at;
        while (high + 1 < en.status.items.len and en.sameSegment(en.status.items[high + 1], id)) high += 1;
        var k = low;
        while (k <= high) : (k += 1) try en.divideOne(en.status.items[k], x, key);
    }

    fn possibleIntersection(en: *Engine, i: u32, j: u32, a1: g.Coordinate, b1: g.Coordinate, a2: g.Coordinate, b2: g.Coordinate) !void {
        try en.tick();
        if (!g.Extent.of(a1, b1).overlaps(g.Extent.of(a2, b2))) return;
        const o1 = pred.orient2(a1, b1, a2, b2);
        if (o1[0] == 0 and o1[1] == 0) {
            // Collinear. Split each segment wherever the other's endpoint falls
            // strictly inside it. The shared span then becomes exactly
            // coincident segments whose winding contributions add.
            try en.divide(i, a2);
            try en.divide(i, b2);
            try en.divide(j, a1);
            try en.divide(j, b1);
            return;
        }
        const o2 = pred.orient2(a2, b2, a1, b1);
        if (o1[0] != 0 and o1[1] != 0 and o2[0] != 0 and o2[1] != 0) {
            if (o1[0] == o1[1] or o2[0] == o2[1]) return;
            // Constructed from the input edges, not from these pieces of them.
            const ei = en.e.items[i];
            const ej = en.e.items[j];
            const x = pred.intersection(
                en.p.items[ei.sa],
                en.p.items[ei.sb],
                en.p.items[ej.sa],
                en.p.items[ej.sb],
            );
            try en.divide(i, x);
            try en.divide(j, x);
            return;
        }
        // A vertex of one segment lies on the supporting line of the other.
        // `divide` filters the cases where it lies outside the span.
        if (o1[0] == 0) try en.divide(i, a2);
        if (o1[1] == 0) try en.divide(i, b2);
        if (o2[0] == 0) try en.divide(j, a1);
        if (o2[1] == 0) try en.divide(j, b1);
    }

    /// Test one segment against a whole run of neighbours, with both sides'
    /// geometry snapshotted first.
    fn against(en: *Engine, id: u32, low: usize, high: usize) !void {
        const from = en.p.items[id];
        const to = en.p.items[en.e.items[id].other];
        var k = low;
        while (k <= high) : (k += 1) {
            const other = en.status.items[k];
            if (other == id) continue;
            try en.possibleIntersection(id, other, from, to, en.p.items[other], en.p.items[en.e.items[other].other]);
        }
    }

    fn neighbours(en: *Engine, id: u32) !void {
        const at = en.statusFind(id) catch return;
        if (at + 1 < en.status.items.len) try en.against(id, at + 1, en.runEnd(at + 1));
        if (at > 0) try en.against(id, en.runStart(at - 1), at - 1);
    }

    /// One sweep position at a time: every event sharing a point is closed, then
    /// every one of them opened, and only then are crossings looked for. Mixing
    /// the three lets a segment be divided while an exact duplicate of it is
    /// still sitting in the queue, and once the two disagree by a rounding step
    /// nothing downstream can pair them again.
    fn sweep(en: *Engine) !void {
        var opened: std.ArrayList(u32) = .empty;
        while (en.peek()) |first| {
            const key = en.e.items[first].key;
            opened.clearRetainingCapacity();
            var gap: usize = none;
            while (en.peek()) |id| {
                if (en.e.items[id].key != key) break;
                _ = en.next();
                try en.tick();
                if (en.e.items[id].left) {
                    try opened.append(en.a, id);
                    continue;
                }
                const opening = en.e.items[id].other;
                const at = try en.statusFind(opening);
                if (!en.e.items[opening].resolved) en.resolve(at);
                _ = en.status.orderedRemove(at);
                gap = @min(gap, at);
            }
            // Opened bottom to top, matching the event order, so each new entry
            // sees the predecessor it will keep.
            for (opened.items) |id| {
                const at = en.statusSeek(id);
                try en.status.insert(en.a, at, id);
                en.enter(id, at);
            }
            for (opened.items) |id| try en.neighbours(id);
            if (gap != none and gap > 0 and gap < en.status.items.len) {
                try en.against(en.status.items[gap - 1], gap, en.runEnd(gap));
            }
        }
    }
};

const Edge = struct { from: u32, to: u32, event: u32, next: u32 = none };
const Ray = struct { edge: u32, outgoing: bool };
/// A traced boundary loop. Named for what it is rather than `LinearRing`, which in
/// `geometry.zig` is the coordinate slice this holds.
const Contour = struct {
    points: g.LinearRing,
    seed: u32,
    hole: bool = false,
    parent: u32 = none,
};

/// Order the events without comparing most pairs.
///
/// The sweep key is lexicographic in (x, y), and on real input x separates
/// almost every pair, so a monotone linear map from x to a bucket index puts
/// the array in order up to ties. Only inside a bucket does the exact
/// comparator run, and there it runs over a short, cache-resident slice.
///
/// Sorting a permutation of indices with `eventLess` costs ~18 branchy
/// comparisons per element, each chasing two random 64-byte `Event` loads.
/// Carrying the key inline in the sorted record removes the indirection but
/// makes every swap 24 bytes wide, which measured *worse*; bucketing removes
/// the comparisons instead and keeps the 4-byte swaps.
fn sortEvents(en: *const Engine, a: A, ids: []u32) !void {
    const target_per_bucket = 2;
    // Below this the histogram costs more than it saves.
    if (ids.len < 64) {
        std.sort.pdq(u32, ids, en, Engine.eventLess);
        return;
    }
    var lo = en.p.items[ids[0]].x;
    var hi = lo;
    for (ids) |id| {
        const x = en.p.items[id].x;
        lo = @min(lo, x);
        hi = @max(hi, x);
    }
    const buckets: u32 = @intCast(@min(ids.len / target_per_bucket, 1 << 21));
    const span = hi - lo;
    // Degenerate spread (one x, or a range that overflows to infinity) has no
    // useful bucketing left in it.
    if (!(span > 0) or !std.math.isFinite(span)) {
        std.sort.pdq(u32, ids, en, Engine.eventLess);
        return;
    }
    const scale = @as(f64, @floatFromInt(buckets)) / span;
    const last: f64 = @floatFromInt(buckets - 1);
    // Monotone in x by construction, so equal x always lands in one bucket and
    // bucket order is key order. NaN cannot reach here (`addEvent` rejects
    // non-finite points) but the comparisons are written to send it to 0 anyway.
    const bucketOf = struct {
        fn f(x: f64, base: f64, s: f64, top: f64) u32 {
            const t = (x - base) * s;
            if (!(t > 0)) return 0;
            if (!(t < top)) return @intFromFloat(top);
            return @intFromFloat(t);
        }
    }.f;

    const counts = try a.alloc(u32, buckets + 1);
    @memset(counts, 0);
    for (ids) |id| counts[bucketOf(en.p.items[id].x, lo, scale, last)] += 1;
    var running: u32 = 0;
    for (counts) |*c| {
        const n = c.*;
        c.* = running;
        running += n;
    }
    const scattered = try a.alloc(u32, ids.len);
    for (ids) |id| {
        const b = bucketOf(en.p.items[id].x, lo, scale, last);
        scattered[counts[b]] = id;
        counts[b] += 1;
    }
    @memcpy(ids, scattered);
    // `counts[b]` now holds the end of bucket b, so the starts walk behind it.
    var start: u32 = 0;
    for (counts[0..buckets]) |end| {
        if (end - start > 1) std.sort.pdq(u32, ids[start..end], en, Engine.eventLess);
        start = end;
    }
}

pub fn execute(a: A, paths: []const Path, mode: Mode, limits: Limits) !g.Geometry {
    var result: g.Geometry = .{ .arena = std.heap.ArenaAllocator.init(a), .polygons = &.{} };
    errdefer result.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const oa = result.arena.allocator();

    var en: Engine = .{ .a = sa, .limits = limits, .mode = mode };
    // Two events per input edge, and the count is known before any are made.
    // Letting these grow by reallocation instead copies both arrays through
    // every doubling, which measured as three quarters of the build phase.
    var incoming: usize = 0;
    for (paths) |path| incoming += if (path.points.len < 2) 0 else path.points.len - 1;
    if (incoming <= limits.max_segments) {
        try en.p.ensureTotalCapacity(sa, 2 * incoming);
        try en.e.ensureTotalCapacity(sa, 2 * incoming);
    }
    var segments: usize = 0;
    for (paths) |path| {
        if (path.points.len < 2) continue;
        for (path.points[0 .. path.points.len - 1], path.points[1..]) |from, to| {
            if (segments >= limits.max_segments) return error.LimitExceeded;
            segments += 1;
            try en.addSegment(from, to, path.layer);
        }
    }
    if (en.e.items.len == 0) return result;

    const order = try sa.alloc(u32, en.e.items.len);
    for (order, 0..) |*v, i| v.* = @intCast(i);
    try sortEvents(&en, sa, order);
    en.initial = order;
    try en.sweep();

    // Result segments, in sweep order, so every contour is created before any
    // contour it encloses and `prev_in_result` always resolves backwards.
    var chosen: std.ArrayList(u32) = .empty;
    for (order) |id| {
        const ev = en.e.items[id];
        if (ev.left and ev.transition != 0) try chosen.append(sa, id);
    }
    // Events created by subdivision, which were never in `order`. Their keys
    // are read now rather than at creation because `divide` rewrites them.
    for (order.len..en.e.items.len) |id| {
        const ev = en.e.items[id];
        if (ev.left and ev.transition != 0) try chosen.append(sa, @intCast(id));
    }
    if (chosen.items.len == 0) return result;
    try sortEvents(&en, sa, chosen.items);

    // Directed result edges, oriented so the filled side is always on the left.
    var vertices: std.AutoHashMapUnmanaged(u128, u32) = .empty;
    var coordinates: std.ArrayList(g.Coordinate) = .empty;
    const edges = try sa.alloc(Edge, chosen.items.len);
    for (chosen.items, edges) |id, *edge| {
        const ev = en.e.items[id];
        const head = try vertex(sa, &vertices, &coordinates, en.p.items[id], en.e.items[id].key);
        const tail = try vertex(sa, &vertices, &coordinates, en.p.items[ev.other], en.e.items[ev.other].key);
        edge.* = if (ev.transition > 0)
            .{ .from = head, .to = tail, .event = id }
        else
            .{ .from = tail, .to = head, .event = id };
    }

    // Radially ordered rays per vertex, in CSR form. Each edge contributes an
    // outgoing ray at its tail and the reverse of its own direction at its head,
    // which is what lets the walk take the tightest turn at a pinch point.
    const offsets = try sa.alloc(u32, coordinates.items.len + 1);
    @memset(offsets, 0);
    for (edges) |edge| {
        offsets[edge.from + 1] += 1;
        offsets[edge.to + 1] += 1;
    }
    for (offsets[1..], 1..) |*v, i| v.* += offsets[i - 1];
    const rays = try sa.alloc(Ray, 2 * edges.len);
    const fill = try sa.alloc(u32, coordinates.items.len);
    @memcpy(fill, offsets[0..coordinates.items.len]);
    for (edges, 0..) |edge, index| {
        rays[fill[edge.from]] = .{ .edge = @intCast(index), .outgoing = true };
        fill[edge.from] += 1;
        rays[fill[edge.to]] = .{ .edge = @intCast(index), .outgoing = false };
        fill[edge.to] += 1;
    }
    for (0..coordinates.items.len) |v| {
        const slice = rays[offsets[v]..offsets[v + 1]];
        std.sort.pdq(Ray, slice, Radial{ .origin = coordinates.items[v], .points = coordinates.items, .edges = edges }, Radial.less);
    }
    for (0..coordinates.items.len) |v| {
        const slice = rays[offsets[v]..offsets[v + 1]];
        for (slice, 0..) |ray, k| {
            if (ray.outgoing) continue;
            var step: usize = 1;
            while (step <= slice.len) : (step += 1) {
                const candidate = slice[(k + slice.len - step) % slice.len];
                if (candidate.outgoing) {
                    edges[ray.edge].next = candidate.edge;
                    break;
                }
            } else return error.NodingFailure;
        }
    }

    var rings: std.ArrayList(Contour) = .empty;
    const positions = try sa.alloc(u32, coordinates.items.len);
    @memset(positions, none);
    const used = try sa.alloc(bool, edges.len);
    @memset(used, false);
    var chain: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList(u32) = .empty;
    var output_points: usize = 0;
    for (0..edges.len) |start| {
        if (used[start]) continue;
        chain.clearRetainingCapacity();
        var walk: u32 = @intCast(start);
        while (!used[walk]) {
            used[walk] = true;
            try chain.append(sa, walk);
            walk = edges[walk].next;
            if (walk == none) return error.NodingFailure;
        }
        if (walk != start) return error.NodingFailure;
        // A closed walk may still touch itself. Pop the minimal loop at every
        // revisited vertex so each emitted ring is simple.
        stack.clearRetainingCapacity();
        for (chain.items) |edge| {
            const v = edges[edge].from;
            if (positions[v] != none) {
                const cut = positions[v];
                try emit(oa, sa, &rings, stack.items[cut..], edges, coordinates.items, &en, limits, &output_points);
                for (stack.items[cut..]) |k| positions[edges[k].from] = none;
                stack.items.len = cut;
            }
            positions[v] = @intCast(stack.items.len);
            try stack.append(sa, edge);
        }
        try emit(oa, sa, &rings, stack.items, edges, coordinates.items, &en, limits, &output_points);
        for (stack.items) |k| positions[edges[k].from] = none;
    }
    if (rings.items.len == 0) return result;

    // Nesting straight off the sweep: the segment recorded below a contour's
    // leftmost vertex already names the contour that encloses it. Contours must
    // be settled in order of that vertex, which is not the order they were
    // traced in — a pinch point pops its inner loop first.
    const nesting = try sa.alloc(u32, rings.items.len);
    for (nesting, 0..) |*v, i| v.* = @intCast(i);
    std.sort.pdq(u32, nesting, Seeds{ .rings = rings.items, .engine = &en }, Seeds.less);
    const settled = try sa.alloc(bool, rings.items.len);
    @memset(settled, false);
    for (nesting) |index| {
        const ring = &rings.items[index];
        // Nearest result segment below this contour's leftmost vertex, walking
        // the status predecessors captured during the sweep.
        var below = en.e.items[ring.seed].prev;
        while (below != none and (en.e.items[below].transition == 0 or en.e.items[below].contour == none)) below = en.e.items[below].prev;
        const material_below = below != none and en.e.items[below].transition > 0;
        if (ring.hole != material_below) return error.NodingFailure;
        settled[index] = true;
        if (!ring.hole) continue;
        const owner = en.e.items[below].contour;
        if (owner == none or !settled[owner]) return error.NodingFailure;
        ring.parent = if (rings.items[owner].hole) rings.items[owner].parent else owner;
        if (ring.parent == none) return error.NodingFailure;
    }

    var shells: usize = 0;
    for (rings.items) |ring| shells += @intFromBool(!ring.hole);
    const output = try oa.alloc(g.Polygon, shells);
    var written: usize = 0;
    for (rings.items, 0..) |ring, index| {
        if (ring.hole) continue;
        var parts: std.ArrayList(g.LinearRing) = .empty;
        try parts.append(oa, ring.points);
        for (rings.items) |hole| {
            if (hole.hole and hole.parent == index) try parts.append(oa, hole.points);
        }
        output[written] = .{ .rings = try parts.toOwnedSlice(oa) };
        written += 1;
    }
    result.polygons = output;
    return result;
}

fn vertex(a: A, map: *std.AutoHashMapUnmanaged(u128, u32), points: *std.ArrayList(g.Coordinate), p: g.Coordinate, key: u128) !u32 {
    if (map.get(key)) |found| return found;
    const id: u32 = @intCast(points.items.len);
    try points.append(a, p);
    try map.put(a, key, id);
    return id;
}

const Seeds = struct {
    rings: []const Contour,
    engine: *const Engine,
    fn less(self: Seeds, x: u32, y: u32) bool {
        return self.engine.eventLess(self.rings[x].seed, self.rings[y].seed);
    }
};

const Radial = struct {
    origin: g.Coordinate,
    points: []const g.Coordinate,
    edges: []const Edge,
    fn target(self: Radial, ray: Ray) g.Coordinate {
        const edge = self.edges[ray.edge];
        return self.points[if (ray.outgoing) edge.to else edge.from];
    }
    fn upper(o: g.Coordinate, p: g.Coordinate) bool {
        return p.y > o.y or (p.y == o.y and p.x >= o.x);
    }
    fn less(self: Radial, x: Ray, y: Ray) bool {
        const p = self.target(x);
        const q = self.target(y);
        const above = upper(self.origin, p);
        if (above != upper(self.origin, q)) return above;
        const turn = pred.orient(self.origin, p, q);
        if (turn != 0) return turn > 0;
        // Same direction: leaving edges first, so a spike walked inwards finds
        // the matching outgoing ray immediately behind it.
        if (x.outgoing != y.outgoing) return x.outgoing;
        return x.edge < y.edge;
    }
};

fn emit(
    oa: A,
    sa: A,
    rings: *std.ArrayList(Contour),
    loop: []const u32,
    edges: []const Edge,
    coordinates: []const g.Coordinate,
    en: *Engine,
    limits: Limits,
    output_points: *usize,
) !void {
    if (loop.len < 3) return;
    var points: std.ArrayList(g.Coordinate) = .empty;
    for (loop, 0..) |edge, i| {
        const p = coordinates[edges[edge].from];
        const before = coordinates[edges[loop[(i + loop.len - 1) % loop.len]].from];
        const after = coordinates[edges[loop[(i + 1) % loop.len]].from];
        if (pred.orient(before, p, after) != 0) try points.append(oa, p);
    }
    if (points.items.len < 3) return;
    const winding = pred.areaSign(points.items);
    if (winding == 0) return;
    if (points.items.len + 1 > limits.max_output_points - output_points.*) return error.LimitExceeded;
    output_points.* += points.items.len + 1;
    try points.append(oa, points.items[0]);
    const index: u32 = @intCast(rings.items.len);
    var seed = edges[loop[0]].event;
    for (loop) |edge| {
        const id = edges[edge].event;
        en.e.items[id].contour = index;
        if (en.eventLess(id, seed)) seed = id;
    }
    try rings.append(sa, .{ .points = try points.toOwnedSlice(oa), .seed = seed, .hole = winding < 0 });
}
