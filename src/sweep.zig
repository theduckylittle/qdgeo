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

/// Which pass assigns the fill transitions.
pub const Labelling = enum {
    /// From the sweep's own status line, the way Martinez-Rueda does it. It
    /// survives an arrangement that is not perfectly noded, because the status
    /// order stays self-consistent even where two segments cross without a
    /// node between them — and on real parcel data, near-coincident vertices
    /// leave a handful of those in every large union.
    sweep,
    /// From the finished arrangement, the way JTS does it: one winding per
    /// wedge of each vertex, propagated across the graph from a ray-cast seed.
    /// Exact wherever the arrangement is exact, and wrong wherever it is not,
    /// because a wedge model assumes every crossing carries a node.
    graph,
};

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
    /// Topmost member of its coincident run in the status line. The nesting
    /// walk follows `prev`, which skips over a run to its top, so whichever
    /// member carries the run's transition has to be this one or the walk steps
    /// straight past it.
    carries: bool = false,
    resolved: bool = false,
    contour: u32 = none,
};

const Engine = struct {
    a: A,
    limits: Limits,
    mode: Mode,
    work: usize = 0,
    /// Crossings this sweep found and could not put a vertex on, because the
    /// rounded intersection landed on or past an endpoint of one of the two
    /// segments. Every one of them is a hole in the arrangement that no further
    /// noding pass can close.
    lost: usize = 0,
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
            m.carries = false;
            m.resolved = true;
        }
        const inside_above = en.filled(above);
        const inside_below = en.filled(en.e.items[en.status.items[low]].below);
        const carrier = &en.e.items[en.status.items[high]];
        carrier.carries = true;
        carrier.transition = if (inside_above == inside_below) 0 else if (inside_above) @as(i8, 1) else -1;
    }

    /// Does this segment already have, or can it be given, a vertex at `key`?
    fn covers(en: *const Engine, id: u32, key: u128) bool {
        const lo = en.e.items[id].key;
        const hi = en.e.items[en.e.items[id].other].key;
        return key >= lo and key <= hi;
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
            // A crossing that one of the segments cannot carry a vertex for is
            // lost for good: the rounded point lands on or past an endpoint, so
            // `divide` refuses it, and a later noding pass will find it, refuse
            // it again, and sit at a fixpoint that still has a crossing in it.
            // Counting them is what lets `execute` tell "try again" from
            // "f64 cannot hold this arrangement" — see `Unnodable`.
            const key = keyOf(canonical(x));
            if (!en.covers(i, key) or !en.covers(j, key)) en.lost += 1;
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

/// A directed edge between two deduplicated vertices. Ring assembly orients it
/// so the filled side is on the left and chains it through `next`; the graph
/// labelling uses the same type undirected, and parks the event that carries
/// the run's transition in `event`.
const Edge = struct { ends: [2]u32, event: u32 = none, next: u32 = none };
const Ray = struct { edge: u32, outgoing: bool };

/// The rays leaving every vertex, counter-clockwise, in CSR form. Each edge
/// contributes an outgoing ray at its tail and the reverse of its own direction
/// at its head, which is what lets ring assembly take the tightest turn at a
/// pinch point and what lets the graph labelling carry a winding per wedge.
///
/// Both callers used to build this inline, identically, twenty-one lines each.
const Fan = struct {
    offsets: []const u32,
    rays: []Ray,

    fn build(sa: A, edges: []const Edge, points: []const g.Coordinate) !Fan {
        const offsets = try sa.alloc(u32, points.len + 1);
        @memset(offsets, 0);
        for (edges) |edge| {
            offsets[edge.ends[0] + 1] += 1;
            offsets[edge.ends[1] + 1] += 1;
        }
        for (offsets[1..], 1..) |*v, i| v.* += offsets[i - 1];
        const rays = try sa.alloc(Ray, 2 * edges.len);
        const fill = try sa.alloc(u32, points.len);
        @memcpy(fill, offsets[0..points.len]);
        for (edges, 0..) |edge, e| {
            rays[fill[edge.ends[0]]] = .{ .edge = @intCast(e), .outgoing = true };
            fill[edge.ends[0]] += 1;
            rays[fill[edge.ends[1]]] = .{ .edge = @intCast(e), .outgoing = false };
            fill[edge.ends[1]] += 1;
        }
        const self: Fan = .{ .offsets = offsets, .rays = rays };
        for (0..points.len) |v| {
            const spokes = self.at(@intCast(v));
            if (spokes.len < 2) continue;
            const order: Radial = .{ .origin = points[v], .points = points, .edges = edges };
            // Almost every vertex has degree two — 95% of a parcel union's, and
            // every one of a buffer's, whose boundary is one long chain — and
            // there `pdq`'s setup costs more than the single comparison the
            // answer needs. Measured, that setup was a quarter of a buffer.
            if (spokes.len == 2) {
                if (order.less(spokes[1], spokes[0])) std.mem.swap(Ray, &spokes[0], &spokes[1]);
                continue;
            }
            std.sort.pdq(Ray, spokes, order, Radial.less);
        }
        return self;
    }

    fn at(self: Fan, v: u32) []Ray {
        return self.rays[self.offsets[v]..self.offsets[v + 1]];
    }

    /// Where `edge` sits in the order around `v`. Degrees are tiny, so a linear
    /// scan beats anything with a structure behind it.
    fn index(self: Fan, v: u32, edge: u32) usize {
        const rays = self.at(v);
        var i: usize = 0;
        while (i < rays.len and rays[i].edge != edge) i += 1;
        return i;
    }
};
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

/// Overlay `paths` under `mode`.
///
/// Which labelling pass runs is not the caller's business: the sweep's own is
/// tried first because it is the cheaper one and it survives an imperfectly
/// noded arrangement, and the graph pass is tried only when that one hands back
/// an edge set that will not assemble. Each answers a case the other cannot —
/// see `Labelling` — and a `NodingFailure` is the exact signal that the first
/// answer was unusable, so retrying on it costs nothing on the paths that work
/// and rescues the ones that do not.
pub fn execute(a: A, paths: []const Path, mode: Mode, limits: Limits) !g.Geometry {
    var lost: usize = 0;
    if (try attempt(a, paths, mode, limits, &lost)) |done| return done;

    // Every crossing that sweep found is an endpoint now, so sweeping the
    // arrangement again is left with only the ones rounding moved off a segment
    // it had already split. That is the whole of iterated noding, and one pass
    // is enough on everything measured — a second has never changed an outcome.
    //
    // It is not gated on `lost`. A lost crossing does say the noding will stop
    // at a fixpoint that still has a hole in it, and on the parcel unions that
    // predicts the retry's failure exactly — but a figure-eight line buffer
    // carries a lost crossing *and* is rescued by the pass anyway, so using it
    // to skip the retry would cost real answers to save time on calls that
    // return an error either way.
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const renoded = try renodeOnce(a, scratch.allocator(), paths, mode, limits);
    if (try attempt(a, renoded, mode, limits, &lost)) |done| return done;
    // `lost` does earn its keep here: it separates "f64 cannot hold this
    // arrangement" from "the algorithm is wrong", which is the difference
    // between a known limit and a bug worth chasing.
    return if (lost != 0) error.UnnodableCrossing else error.NodingFailure;
}

/// Both labellings on one arrangement. Null means neither could assemble it.
/// `lost` comes back with the crossings the noding could not place a vertex on.
fn attempt(a: A, paths: []const Path, mode: Mode, limits: Limits, lost: *usize) !?g.Geometry {
    for ([_]Labelling{ .sweep, .graph }) |how| {
        return overlay(a, paths, mode, limits, how, lost) catch |err| switch (err) {
            error.NodingFailure => continue,
            else => err,
        };
    }
    return null;
}

/// One noding pass: sweep `paths` and return the arrangement it produced, as
/// one two-point path per noded segment.
///
/// The engine lives in an arena of its own, released before this returns, and
/// only the paths are allocated from `sa`. Two overlay attempts run after this
/// one and they do not need its events: leaving them in the caller's arena
/// measured 2.56 KiB of peak heap per input coordinate against 0.68 on the path
/// that never gets here.
fn renodeOnce(a: A, sa: A, paths: []const Path, mode: Mode, limits: Limits) ![]const Path {
    var inner = std.heap.ArenaAllocator.init(a);
    defer inner.deinit();
    const ia = inner.allocator();

    var en: Engine = .{ .a = ia, .limits = limits, .mode = mode };
    _ = try load(&en, ia, paths, limits) orelse return paths;
    try en.sweep();

    var kept: usize = 0;
    for (en.e.items) |ev| kept += @intFromBool(ev.left);
    // One block for every endpoint rather than a two-coordinate allocation per
    // segment, which on a large arrangement is tens of thousands of them.
    const ends = try sa.alloc(g.Coordinate, 2 * kept);
    const out = try sa.alloc(Path, kept);
    var at: usize = 0;
    for (en.e.items, 0..) |ev, i| {
        if (!ev.left) continue;
        const pts = ends[2 * at ..][0..2];
        // `delta[layer]` is +1 exactly when the segment ran lexicographically
        // forward, so restoring that sign restores the winding it contributes.
        if (ev.delta[ev.layer] > 0) {
            pts[0] = en.p.items[i];
            pts[1] = en.p.items[ev.other];
        } else {
            pts[0] = en.p.items[ev.other];
            pts[1] = en.p.items[i];
        }
        out[at] = .{ .points = pts, .layer = ev.layer };
        at += 1;
    }
    return out;
}

/// Turn `paths` into events and put them in sweep order. Null means there was
/// nothing to sweep. Both `overlay` and `renodeOnce` start here.
fn load(en: *Engine, sa: A, paths: []const Path, limits: Limits) !?[]u32 {
    // Two events per input edge, and the count is known before any are made.
    // Letting these grow by reallocation instead copies both arrays through
    // every doubling, which measured as three quarters of the build phase.
    var incoming: usize = 0;
    for (paths) |path| incoming += if (path.points.len < 2) 0 else path.points.len - 1;
    if (incoming <= limits.max_segments) {
        // Precise, and with room for subdivision. Both halves are load-bearing
        // and were measured on `parcels-union-4040`:
        //
        //   * `ensureTotalCapacity` asks `growCapacity` for the next geometric
        //     step, which overshot 261,686 events to 392,537 — 1.5x, and 20 MiB
        //     of peak heap once the arena rounded the node up.
        //   * sizing it exactly instead is worse: subdivision appends past the
        //     capacity, and a doubling *inside an arena* keeps the old buffer as
        //     well as the new one. That measured 130 MiB against 45.
        //
        // Subdivision added 2% of the initial event count here, so an eighth is
        // ample. Exceeding it is a memory spike, not an error.
        const room = 2 * incoming + incoming / 8;
        try en.p.ensureTotalCapacityPrecise(sa, room);
        try en.e.ensureTotalCapacityPrecise(sa, room);
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
    if (en.e.items.len == 0) return null;
    const order = try sa.alloc(u32, en.e.items.len);
    for (order, 0..) |*v, i| v.* = @intCast(i);
    try sortEvents(en, sa, order);
    en.initial = order;
    return order;
}

fn overlay(a: A, paths: []const Path, mode: Mode, limits: Limits, labelling: Labelling, lost: *usize) !g.Geometry {
    lost.* = 0;
    var result: g.Geometry = .{ .arena = std.heap.ArenaAllocator.init(a), .polygons = &.{} };
    errdefer result.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const oa = result.arena.allocator();

    var en: Engine = .{ .a = sa, .limits = limits, .mode = mode };
    const order = try load(&en, sa, paths, limits) orelse return result;
    try en.sweep();
    lost.* = en.lost;
    if (labelling == .graph) try relabel(&en, sa);

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
    var vertices = try Vertices.init(sa, 2 * chosen.items.len);
    const edges = try sa.alloc(Edge, chosen.items.len);
    for (chosen.items, edges) |id, *edge| {
        const ev = en.e.items[id];
        const head = vertices.id(en.p.items[id], en.e.items[id].key);
        const tail = vertices.id(en.p.items[ev.other], en.e.items[ev.other].key);
        edge.* = if (ev.transition > 0)
            .{ .ends = .{ head, tail }, .event = id }
        else
            .{ .ends = .{ tail, head }, .event = id };
    }
    const fan = try Fan.build(sa, edges, vertices.coordinates());
    for (0..vertices.coordinates().len) |v| {
        const slice = fan.at(@intCast(v));
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
    const positions = try sa.alloc(u32, vertices.coordinates().len);
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
            const v = edges[edge].ends[0];
            if (positions[v] != none) {
                const cut = positions[v];
                try emit(oa, sa, &rings, stack.items[cut..], edges, vertices.coordinates(), &en, limits, &output_points);
                for (stack.items[cut..]) |k| positions[edges[k].ends[0]] = none;
                stack.items.len = cut;
            }
            positions[v] = @intCast(stack.items.len);
            try stack.append(sa, edge);
        }
        try emit(oa, sa, &rings, stack.items, edges, vertices.coordinates(), &en, limits, &output_points);
        for (stack.items) |k| positions[edges[k].ends[0]] = none;
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

/// Deduplicated vertices: two endpoints are the same vertex exactly when their
/// sweep keys match, so the key is the whole identity and the coordinate rides
/// along. Ring assembly and the graph labelling each build one.
///
/// On a buffer, whose result keeps nearly every noded segment, this is the
/// largest phase after the sweep itself, so it is worth the custom context.
const Vertices = struct {
    /// `keyOf` already packs two order-preserving f64 patterns, so one fold and
    /// a 64-bit finalizer avalanche it well enough — and cost far less than
    /// `AutoHashMap`'s Wyhash over all sixteen bytes.
    const Context = struct {
        pub fn hash(_: Context, key: u128) u64 {
            var h: u64 = @as(u64, @truncate(key)) ^ (@as(u64, @truncate(key >> 64)) *% 0x9E3779B97F4A7C15);
            h ^= h >> 33;
            h *%= 0xFF51AFD7ED558CCD;
            h ^= h >> 33;
            return h;
        }
        pub fn eql(_: Context, x: u128, y: u128) bool {
            return x == y;
        }
    };
    /// Also the merge map in `relabel`. One instantiation in the artifact,
    /// not two — a second cost 8.8 KB raw and 2.5 KB gzipped, measured.
    pub const Map = std.HashMapUnmanaged(u128, u32, Context, std.hash_map.default_max_load_percentage);

    map: Map,
    points: []g.Coordinate,
    count: usize = 0,

    /// `upper` is the most vertices that can appear — two per edge. Sizing for
    /// it exactly means `id` never grows anything, which takes the rehash path
    /// out of the loop and the allocation-failure path out of the binary;
    /// growing unreserved measured 1.7x slower on this phase.
    fn init(a: A, upper: usize) !Vertices {
        var map: Map = .empty;
        try map.ensureTotalCapacity(a, @intCast(upper));
        return .{ .map = map, .points = try a.alloc(g.Coordinate, upper) };
    }

    fn id(self: *Vertices, p: g.Coordinate, key: u128) u32 {
        // One probe, not the two that a `get` then a `put` would cost.
        const found = self.map.getOrPutAssumeCapacity(key);
        if (!found.found_existing) {
            found.value_ptr.* = @intCast(self.count);
            self.points[self.count] = p;
            self.count += 1;
        }
        return found.value_ptr.*;
    }

    fn coordinates(self: Vertices) []const g.Coordinate {
        return self.points[0..self.count];
    }
};

const Seeds = struct {
    rings: []const Contour,
    engine: *const Engine,
    fn less(self: Seeds, x: u32, y: u32) bool {
        return self.engine.eventLess(self.rings[x].seed, self.rings[y].seed);
    }
};

/// Counter-clockwise order of the rays leaving one vertex. Both the labelling
/// pass and ring assembly order by it, so keeping one comparator keeps one
/// `pdq` in the binary.
const Radial = struct {
    origin: g.Coordinate,
    points: []const g.Coordinate,
    edges: []const Edge,
    fn target(self: Radial, ray: Ray) g.Coordinate {
        const pair = self.edges[ray.edge].ends;
        return self.points[if (ray.outgoing) pair[1] else pair[0]];
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

/// The arrangement, re-labelled from the finished graph rather than from the
/// sweep's running state — JTS's ordering: node first, then label.
///
/// Winding belongs to the faces of the arrangement, so it is carried per wedge:
/// the segments at a vertex cut its neighbourhood into wedges, and stepping
/// counter-clockwise across one changes the winding by its delta, signed by the
/// half-plane the segment leaves in. One wedge per connected component is seeded
/// by ray casting; everything else follows from adjacency.
const Relabel = struct {
    en: *Engine,
    deltas: []const [2]i32,
    edges: []const Edge,
    points: []const g.Coordinate,
    fan: Fan,
    wedge: [][2]i32,

    /// Does this segment leave the vertex to the right?
    ///
    /// Stepping counter-clockwise across a segment crosses it *upward* exactly
    /// when the segment's counter-clockwise normal points up, and that normal is
    /// the direction rotated a quarter turn — so the test is on the x component,
    /// not the y. A vertical segment is decided by the shear, which tilts it
    /// right, so leaving upward counts as rightward.
    fn leaves(self: Relabel, v: u32, spoke: Ray) bool {
        const pair = self.edges[spoke.edge].ends;
        const other = if (pair[0] == v) pair[1] else pair[0];
        const o = self.points[v];
        const p = self.points[other];
        return p.x > o.x or (p.x == o.x and p.y > o.y);
    }

    /// Fill every wedge at `v`, given that wedge `start` holds `seed`.
    fn settle(self: Relabel, v: u32, start: usize, seed: [2]i32) void {
        const base = self.fan.offsets[v];
        const at = self.fan.at(v);
        self.wedge[base + start] = seed;
        var carried = seed;
        var step: usize = 1;
        while (step < at.len) : (step += 1) {
            const i = (start + step) % at.len;
            const d = self.deltas[at[i].edge];
            // Crossing counter-clockwise is upward when the segment leaves into
            // the upper half-plane and downward when it leaves into the lower.
            const sign: i32 = if (self.leaves(v, at[i])) 1 else -1;
            carried = .{ carried[0] + sign * d[0], carried[1] + sign * d[1] };
            self.wedge[base + i] = carried;
        }
    }

    /// The wedge above a segment at one of its ends, and the one below it.
    fn sides(self: Relabel, v: u32, i: usize) struct { above: usize, below: usize } {
        const at = self.fan.at(v);
        const ccw = i;
        const cw = (i + at.len - 1) % at.len;
        // Counter-clockwise of a ray leaving rightward is above the segment.
        return if (self.leaves(v, at[i]))
            .{ .above = ccw, .below = cw }
        else
            .{ .above = cw, .below = ccw };
    }
};

/// Discard the transitions the sweep assigned and derive them again from the
/// finished arrangement: merge coincident edges, cut every vertex into wedges,
/// carry one winding per wedge, and mark a segment as a result edge where the
/// wedges either side of it disagree about being filled.
fn relabel(en: *Engine, sa: A) !void {
    var list: std.ArrayList(u32) = .empty;
    for (en.e.items, 0..) |ev, i| {
        if (!ev.left) continue;
        if (ev.delta[0] == 0 and ev.delta[1] == 0) continue;
        try list.append(sa, @intCast(i));
    }
    for (en.e.items) |*ev| {
        ev.transition = 0;
        ev.resolved = true;
    }
    if (list.items.len == 0) return;
    const segments = list.items;

    var vertices = try Vertices.init(sa, 2 * segments.len);
    const ends = try sa.alloc([2]u32, segments.len);
    for (segments, ends) |id, *pair| {
        const other = en.e.items[id].other;
        pair[0] = vertices.id(en.p.items[id], en.e.items[id].key);
        pair[1] = vertices.id(en.p.items[other], en.e.items[other].key);
    }

    // Merge coincident edges before labelling, the way JTS's `insertUniqueEdge`
    // does: one edge per geometric location carrying the summed delta. Noding
    // has already split every overlap into pieces that are either identical or
    // disjoint, so the endpoint pair is a complete key. Carrying duplicates into
    // the labelling instead leaves a zero-width wedge between them, and the
    // winding either side of that wedge comes out wrong.
    // Sized for the worst case — no two segments coincident — so nothing here
    // grows either.
    var groups: Vertices.Map = .empty;
    try groups.ensureTotalCapacity(sa, @intCast(segments.len));
    const merged = try sa.alloc(Edge, segments.len);
    const summed = try sa.alloc([2]i32, segments.len);
    var count: usize = 0;
    for (segments, ends) |id, pair| {
        const key = (@as(u128, pair[0]) << 32) | pair[1];
        const d = en.e.items[id].delta;
        const found = groups.getOrPutAssumeCapacity(key);
        if (!found.found_existing) {
            found.value_ptr.* = @intCast(count);
            merged[count] = .{ .ends = pair };
            summed[count] = .{ 0, 0 };
            count += 1;
        }
        const at = found.value_ptr.*;
        summed[at][0] += d[0];
        summed[at][1] += d[1];
        // One event per merged edge carries the transition and the rest stay at
        // zero, the same shape `resolve` gives a coincident bundle — two events
        // labelled for one edge would hand assembly a doubled ring side. It has
        // to be the member `resolve` would have chosen, because `enter` records
        // `prev` as the entry *below* a coincident run, so the nesting walk only
        // ever lands on the run's topmost member.
        const carrier = &merged[at].event;
        if (carrier.* == none or en.e.items[id].carries) carrier.* = id;
    }
    const unique = merged[0..count];
    const deltas = summed[0..count];
    const fan = try Fan.build(sa, unique, vertices.coordinates());

    const self: Relabel = .{
        .en = en,
        .deltas = deltas,
        .edges = unique,
        .points = vertices.coordinates(),
        .fan = fan,
        .wedge = try sa.alloc([2]i32, fan.rays.len),
    };

    const known = try sa.alloc(bool, vertices.coordinates().len);
    @memset(known, false);
    var queue: std.ArrayList(u32) = .empty;

    // Components first, so each can be seeded at its rightmost vertex — the one
    // place the +x direction is provably outside that component, which is what
    // makes the ray cast below exact rather than an epsilon away from a vertex.
    const parent = try sa.alloc(u32, vertices.coordinates().len);
    for (parent, 0..) |*v, i| v.* = @intCast(i);
    const find = struct {
        fn f(p: []u32, x: u32) u32 {
            var r = x;
            while (p[r] != r) r = p[r];
            var w = x;
            while (p[w] != r) {
                const next = p[w];
                p[w] = r;
                w = next;
            }
            return r;
        }
    }.f;
    for (unique) |edge| {
        const x = find(parent, edge.ends[0]);
        const y = find(parent, edge.ends[1]);
        if (x != y) parent[x] = y;
    }
    const rightmost = try sa.alloc(u32, vertices.coordinates().len);
    @memset(rightmost, none);
    for (0..vertices.coordinates().len) |v| {
        const c = find(parent, @intCast(v));
        const held = rightmost[c];
        if (held == none) {
            rightmost[c] = @intCast(v);
            continue;
        }
        const p = vertices.coordinates()[v];
        const q = vertices.coordinates()[held];
        if (p.x > q.x or (p.x == q.x and p.y > q.y)) rightmost[c] = @intCast(v);
    }

    for (0..vertices.coordinates().len) |start| {
        if (known[start]) continue;
        const root: u32 = rightmost[find(parent, @intCast(start))];
        // Seed the wedge holding direction +x. Winding at infinity is zero, so
        // the winding just right of `root` is what a ray from there to +x
        // crosses, counted with sign.
        //
        // The component's own edges are skipped: `root` is its rightmost
        // vertex, so a point just to the right of `root` is outside the
        // component's bounding box and it winds zero there. That is also what
        // makes the count exact — every remaining edge belongs to another
        // component, and components share no vertex, so none of them touches
        // `root`.
        const origin = vertices.coordinates()[root];
        const component = find(parent, root);
        var seed: [2]i32 = .{ 0, 0 };
        for (unique, deltas) |edge, d| {
            if (find(parent, edge.ends[0]) == component) continue;
            const tail = vertices.coordinates()[edge.ends[0]];
            const head = vertices.coordinates()[edge.ends[1]];
            // Sunday's half-open rule: an edge spans `[min y, max y)`, so a
            // vertex sitting exactly on the ray is counted by the edge above it
            // and by no other. That removes the degenerate cases outright
            // rather than nudging the ray off them.
            const up = tail.y <= origin.y and origin.y < head.y;
            const down = head.y <= origin.y and origin.y < tail.y;
            if (!up and !down) continue;
            // And the crossing has to be to the right of the origin, which is
            // the side test on the directed edge.
            const side = pred.orient(tail, head, origin);
            if (if (up) side <= 0 else side >= 0) continue;
            // Crossing rightward moves off the left of an upward edge, so the
            // winding out at infinity is lower by its delta; walking back in
            // from infinity puts it back.
            const sign: i32 = if (up) 1 else -1;
            seed[0] += sign * d[0];
            seed[1] += sign * d[1];
        }
        const at = self.fan.at(root);
        const first = Radial{ .origin = origin, .points = vertices.coordinates(), .edges = unique };
        const on_axis = blk: {
            const t = first.target(at[0]);
            break :blk t.y == origin.y and t.x > origin.x;
        };
        self.settle(root, if (on_axis) 0 else at.len - 1, seed);
        known[root] = true;
        queue.clearRetainingCapacity();
        try queue.append(sa, root);

        while (queue.pop()) |v| {
            for (self.fan.at(v), 0..) |spoke, i| {
                const pair = unique[spoke.edge].ends;
                const other = if (pair[0] == v) pair[1] else pair[0];
                if (known[other]) continue;
                // The face above a segment is the same face at both its ends.
                const here = self.sides(v, i);
                const carried = self.wedge[self.fan.offsets[v] + here.above];
                const j = self.fan.index(other, spoke.edge);
                const there = self.sides(other, j);
                self.settle(other, there.above, carried);
                known[other] = true;
                try queue.append(sa, other);
            }
        }
    }

    for (unique, 0..) |edge, at| {
        const tail = edge.ends[0];
        const i = self.fan.index(tail, @intCast(at));
        const side = self.sides(tail, i);
        const base = self.fan.offsets[tail];
        const inside_above = en.filled(self.wedge[base + side.above]);
        const inside_below = en.filled(self.wedge[base + side.below]);
        en.e.items[edge.event].transition = if (inside_above == inside_below) 0 else if (inside_above) @as(i8, 1) else -1;
    }
}

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
        const p = coordinates[edges[edge].ends[0]];
        const before = coordinates[edges[loop[(i + loop.len - 1) % loop.len]].ends[0]];
        const after = coordinates[edges[loop[(i + 1) % loop.len]].ends[0]];
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
