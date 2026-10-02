# src/CLAUDE.md

The engine internals and the invariants that are easy to break. The root
`CLAUDE.md` covers the project, commands and repo-wide conventions; this file
is what to read before changing anything under `src/`.

## The overlay engine

One engine, `sweep.execute(allocator, []Path, Mode, Limits) !Geometry`. There
used to be a second, `graph`, in `src/overlay.zig`: BVH noding, a half-edge
graph, face depths seeded by ray casting. It was **removed** after it lost to
the sweep on all 26 differential workloads — by 1.01x to 2.99x, never winning
once — while both passed 26/26. Deleting it also took the WASM artifact from
175,702 bytes to 110,394 (65,222 gzipped to 43,209). Do not reintroduce a
second backend without a workload where it wins.

`operations.zig` normalizes input (validate rings, drop repeated points, force
shell CCW / hole CW, reject zero-area and sub-`1e-140` edges) into `Path` values
carrying a `layer` bit, then calls the sweep.

### Martinez-Rueda (`src/sweep.zig`)

Martinez-Rueda, with four deliberate departures from the textbook version. Read
the module header before changing anything in it; the reasoning is there and the
list in `TODO.md` records which invariants were learned the hard way.

1. **Winding counts, not in/out parity.** Each layer carries an `i32` depth, so a
   layer may hold any number of overlapping, stacked or edge-sharing polygons.
   This removes the SAME_TRANSITION / DIFFERENT_TRANSITION / NON_CONTRIBUTING
   classification completely: coincident edges keep both contributions and their
   deltas cancel. Do not reintroduce edge types.
2. **No vertical special case.** Lexicographic `(x, y)` event order is the
   symbolic shear `(x, y) -> (x + ey, y)`; unit determinant, so orientations are
   untouched and verticals get a real position in the status line.
3. **Exact predicates everywhere**, including paired `predicates.orient2`.
4. **SoA plus u128 sort keys** so the hot comparisons start from one integer
   compare. `sortEvents` then avoids most of those compares outright: it buckets
   events by x with a monotone linear map and runs `pdq` only inside a bucket.
   Carrying the key inline in a wider sort record instead was measured and is
   *slower* — see "What was tried and did not pay" in `TODO.md` before
   reaching for it again.

The sweep runs one point at a time as a batch: close every right event, open
every left event, and only then look for crossings. Splitting a segment while an
exact duplicate of it is still queued is unrecoverable, because rounding puts the
crossing on neither copy's line afterwards.

### Two labellings, one fallback (`relabel` in `src/sweep.zig`)

Deciding which side of each segment is filled can be done two ways, and neither
one covers every input. `execute` tries the cheap one and retries with the other
when the first hands back an edge set that will not assemble. **Which one ran is
not part of the API** — do not expose it, and do not pin one at a call site.

* **`.sweep`** reads the transition off the status line as the sweep passes, the
  way Martinez-Rueda does. It is the default first attempt because it is free
  and because it survives an arrangement that is *not* perfectly noded: the
  status order stays self-consistent even where two segments cross with no node
  between them.
* **`.graph`** relabels afterwards from the finished arrangement, the way JTS
  does. Coincident edges are merged first (JTS's `insertUniqueEdge`), then each
  vertex's neighbourhood is cut into wedges, one winding per wedge, propagated
  by BFS from a ray-cast seed at each component's rightmost vertex. It is exact
  wherever the arrangement is exact, and **wrong wherever it is not**, because a
  wedge model assumes every crossing carries a node.

That last sentence is the whole reason for the fallback rather than a switch.
Measured on the parcel corpus:

| workload | `.sweep` only | `.graph` only | fallback |
| --- | --- | --- | --- |
| 57,990 cluster buffers | 10 fail | 6 fail | **6 fail**, +2.9% time |
| 3,946 cluster unions | 4 fail | 4 fail | **4 fail**, no cost |
| 4,040-parcel union | passes | **fails** | passes |

The 4,040-parcel union is the case that decides the order: its arrangement holds
three residual unnoded crossings — pairs of vertices about 2e-9 apart, where the
split point rounds off the other segment's line — and the wedge model cannot
label it at all. Running `.graph` first would break the flagship workload and
pay for a second pass on every call. Running it second costs nothing except on
the inputs that already had no answer.

Cost of carrying the second pass: **+10,763 bytes raw, +4,556 gzipped** on the
WASM artifact, against 115,995 / 44,874 without it.

Three things to know before touching `relabel`:

- **The carrier has to be the run's top.** `enter` records `prev` as the status
  entry *below* the inserted segment's coincident run, so the nesting walk only
  ever lands on the topmost member of a run. `resolve` marks that member
  `carries`, and `relabel` must give the transition to the same one — hand it to
  any other member of the group and the walk steps straight past it, `below`
  comes back `none`, and nesting fails.
- **Seed on a rightward ray, not an upward one.** The seed is the winding just
  right of a component's rightmost vertex, counted by Sunday's half-open rule
  (an edge spans `[min y, max y)`) with `orient` for the side test. A vertical
  ray instead lands on grid-aligned vertices constantly and needs a degenerate
  case for each; this needs none. Skip the component's own edges: nothing of it
  reaches past its rightmost vertex, so it winds zero there, and no other
  component touches that vertex.
- **`Fan`, `Radial`, `Ray`, `Edge` and `Vertices` are shared with ring
  assembly** on purpose. Each was once duplicated — `Spoke` / `Spokes` were
  `Ray` / `Radial` renamed, and both callers built the same twenty-one-line
  CSR-plus-radial-sort inline. Duplicating a type here is not free: a second
  `pdq` instantiation cost ~10 KB raw and a second hash-map shape cost 8.8 KB
  raw and 2.5 KB gzipped, both measured. Before adding a struct to this file,
  check whether one of these five already says it.

### Where the time goes, by phase

`rdtsc` around each phase, native `ReleaseFast`, min of 7 runs. The two shapes
of workload are nothing alike, so optimise against both or neither:

| phase | `parcels-union-4040` | `complex-parcel-buffer +2` |
| --- | ---: | ---: |
| build + sort events | 28% | 25% |
| **sweep** | **70%** | **37%** |
| select result segments | 1% | 4% |
| **vertex dedup** | 0.2% | **23% → 13%** |
| radial fan | 0.1% | 4% |
| link, trace, nest, output | 0.4% | 9% |

A union's result is 2,636 edges out of 133,523 noded, so everything after the
sweep is free. A buffer's is 31,329 out of 32,157 — almost all of them — so the
per-result-edge stages are suddenly a third of the run. `Vertices` is where that
landed, and three things fixed it:

- **Size the map for the upper bound and never grow.** Two endpoints per result
  edge bounds the vertex count, so `ensureTotalCapacity` plus
  `getOrPutAssumeCapacity` removes both the rehashing and the growth path. This
  was most of the 23% → 13%.
- **One probe, not two.** `getOrPut` where a `get` then a `put` used to hash the
  key twice.
- **A cheap hash.** `keyOf` already packs two order-preserving f64 patterns, so
  one fold and a 64-bit finalizer beat `AutoHashMap`'s Wyhash over sixteen
  bytes — and measured *smaller* in the artifact, not larger.

Net, measured `ReleaseSafe` native: `complex-parcel-buffer` **1.35x** either
direction, `parcels-buffer-100 +2` **1.24x**, `parcels-union-4040` 1.03x.

**Do not chase the radial sort.** Every vertex of a buffer's boundary and 95% of
a union's has degree two, which looks like an easy win, and replacing `pdq` with
a single comparison there is worth only 8% of that phase. The fan is 4%; the
hash map was 23%. Measure before assuming which one is the cost.

### One re-noding pass, after both labellings

When neither labelling can assemble the arrangement, `execute` sweeps its own
output once more and tries again. `renodeOnce` hands back one two-point `Path`
per noded segment, so every crossing the first sweep found is an endpoint the
second time and only the ones rounding moved off an already-split segment are
left to find. That is the whole of iterated noding here — no snapping, no
tolerance, and no change to any coordinate.

It costs **nothing on a call that succeeds**: the retry sits after the first
attempt returns. What it buys:

| | before | after |
| --- | --- | --- |
| 57,990 cluster buffers | 6 fail | **0 fail** |
| figure-eight line buffer | fails | **matches GEOS** (4.2689251551415985) |
| 3,946 cluster unions | 4 fail | 4 fail |
| rescued call's runtime | — | 1.6x to 2.4x |
| a still-failing union's runtime | — | ~2.5x, wasted |

One pass is what ships because a second has never changed an outcome. The
rescued buffers match GEOS to about `5e-11` relative area.

**Why the unions do not move.** Their arrangement is already a noding fixpoint —
847 segments in, 847 out, pass after pass — and it still has exactly one
crossing in it. That crossing is *unsplittable*: the rounded intersection lands
on or past an endpoint of one of the two segments, so `divide` refuses it,
correctly, because splitting there would put the vertex off the other segment's
line. `Engine.lost` counts them, and `execute` reports `error.UnnodableCrossing`
instead of `NodingFailure` when any were seen — the difference between "f64
cannot hold this arrangement" and "the algorithm is wrong". The ABI keeps the
distinction: status 7 against status 5, pinned by a native test, and part of
the public surface since 1.0.

**Do not gate the retry on `lost`.** It is tempting: on the parcel unions a
nonzero count predicts the retry's failure 4 times out of 4, and skipping would
save that wasted 2.5x. It was tried and reverted. The figure-eight buffer
carries a lost crossing *and* is rescued by the pass anyway, so the gate trades
a real answer for time on calls that return an error either way.

## Buffer

`src/offset.zig` emits **one raw, self-intersecting offset curve** per ring, per
line and per point — the JTS/GEOS construction, ported. `buffer` emits a
curve for each ring, line and point and runs one overlay pass.

A **single** polygon is not unioned first. JTS and GEOS build curves straight
from the rings, and the union pass that used to run here made us disagree with
GEOS on every self-intersecting single polygon — `spike` 55.1 against GEOS's
61.8, `figure8` 33.8 against 34.0 — while costing 37% of the buffer on a
19,208-coordinate parcel. Removing it fixed both. **Several** polygons still are
unioned: the operation is buffer-of-the-union, and adjacent parcels sharing a
boundary emit coincident curves one overlay pass cannot node. Dropping it there
was measured too — `parcels-buffer-100-+2` fails outright. There is no separate
offsetting algorithm and no band: the overlay keeps what the curves wind at
least once, which is JTS's `depth(RIGHT) >= 1`. Inward collapse, neck splitting
and the spurious loops an offset curve makes at a concavity all fall out of that
count. `docs/BUFFER_APPROACH.md` has the comparison and the measurements.

Three things there are load-bearing and easy to break:

- **Curve orientation is the answer, not a detail.** An outward shell curve winds
  the buffer positively and an inward hole curve winds out of it. Nothing may
  normalise a curve's orientation. Line curves are emitted reversed relative to
  JTS precisely because JTS labels instead of winding.
- **`erodedCompletely` must stay.** A ring narrower than twice the erosion
  distance offsets to a curve that has turned inside out — still closed, still
  wound positively, enclosing a region that is not in the buffer. Winding alone
  cannot tell it from a real one.
- **Input simplification is off** (`BufferOptions.simplify_factor = 0`). JTS
  defaults it to `0.01 * distance`; measured here that costs exactly that much
  accuracy and fixes nothing. Turn it up only for a workload that cannot be
  noded, and say so.

## Predicates (`src/relate.zig`)

`relate(a, b) !Matrix` builds the DE-9IM matrix from an arrangement, not from
an overlay: every vertex and crossing is a node, every segment is cut into
pieces at its nodes, and each node and piece is located in both operands.
**Evaluation is lazy.** A predicate is a `Pattern` over the matrix, the ABI
takes the pattern (three bits a cell; nine stars is 0 and asks for the whole
matrix), and because cells only grow as the arrangement is walked, the walk
stops the moment `Pattern.verdict` is decided — an `F` filled, a dimension
passed, or the last `T` filled with nothing left to wait for. The operand whose
pieces can fail the pattern is walked first (`contains` fails on the exterior
row, which the second operand's pieces fill). `apart` answers any pattern from
the dimensions alone when the extents are disjoint, and the `intersects`
pattern is routed to a path with an exit inside the sweep, at the first
contact. The named predicates are patterns — `Predicate.pattern(dims)` here,
`PATTERN` in the binding, the same table — with one extension to JTS's
language: `A` marks a group of cells of which one must be non-empty, so
`covers` and `touches` are one pattern each instead of four.

Measured on 4,096 squares against 4,096 overlapping ones, min of 5: the full
matrix 68 ms; `intersects` 6 ms on contact and 5 ms on disjoint extents;
`contains` on disjoint extents 4 ms; the other named predicates about 58 ms —
the arrangement build is the fixed cost and laziness saves the walk.

Every path reads each operand as a union — a point on an edge shared by two
polygons of one operand is *interior*, a line endpoint is boundary only when an
odd number of that operand's lines end there — which is JTS's rule for a
GeometryCollection, and the reason `intersects([a, b, c], [d, e, f])` means
what it says.

Five things there are load-bearing and were each learned from a failing case:

- **A piece's location is probed at its midpoint with Sunday's half-open ray
  cast**, the same construction `relabel` seeds from. The half-open rule
  answers for a point an infinitesimal step *above* the midpoint, which for a
  piece on a boundary is already one of its sides; the collinear edges then
  separate the two sides, each adding one to the side its interior is on. Add
  them to both sides and every boundary piece reads as interior — the first
  bug.
- **Coincidence is carried by identity, never re-derived from coordinates.**
  A crossing is rounded, so a piece between two crossings is not on the line
  of the segment it came from, and `orient` at its midpoint says "not
  collinear" about a segment it is on. `meet` records collinear overlaps from
  the exact test on the original coordinates, and the probe credits an edge as
  coincident when it is marked *and* its box holds the midpoint — an overlap
  is between whole segments, and the piece is cut at every end of every
  overlapping segment, so it lies wholly inside or wholly outside each. JTS's
  issue 396 case is the one that enforces this.
- **A crossing is computed from canonical arguments** — lower endpoint first,
  lower segment first — because `predicates.intersection` rounds differently
  with its arguments swapped. Two coincident segments, one per operand, must
  see their crossing with a third as one node, not two an ulp apart.
- **Probes go through a grid over polygon extents** (`Grid`), one cell list
  per probe instead of a scan of every polygon's box. Measured on 4,096
  parcels against 4,096: `relate` 1,074 ms → 87 ms, the union of one side
  being 90 ms; `contains` of 4,096 points 128 ms → 24 ms. Cost 4.3 KB raw,
  1.6 KB gzipped. A polygon the size of the operand lists in every cell, so
  past sixteen entries per polygon the grid collapses to one cell.
- **Large polygons' edges are indexed by horizontal band** (`Bands`), because
  a rightward ray at height `y` can only cross an edge whose y-range holds `y`.
  Without it the parcels' 19,208-vertex polygon cost ~19,000 side tests per
  probe and was probed ~19,000 times walking its own boundary: `relate` over
  all 4,040 parcels took 10.6 s, now 0.33 s. Both indexes — this and `Grid` —
  are built lazily by the arrangement; `intersects` never needs them, and
  building them on every call was a quarter of a small call. The probe reads
  either index through one loop, so the edge test is emitted once: two loops
  cost 3 KB raw. `noinline` on the edge test saves 0.3 KB and costs 20%.
- **`intersects` culls to the other operand's extent.** A segment whose box
  misses the other's extent meets nothing of it, so it is never swept; a vertex
  outside it is never probed. Exact, and it halves `intersects` of a query
  against the whole dataset. Validation still covers every part. `relate`
  cannot do the same: under union semantics a culled polygon changes how its
  neighbours' shared edges read.
- **A point operand skips the arrangement** (`pointMatrix`) when the other
  operand is only polygons, only lines, or only points. A point operand has no
  boundary, so its row is where each point falls, and the exterior row follows
  from what the other operand is made of. Points in polygons go through the
  probe, indexed past eight points; a point on a line is an exact `orient` and
  box test, with the mod-2 rule for endpoints. Measured per call: a point in a
  square 4.2 → 1.7 µs, in the 19,208-vertex parcel 8.1 → 0.62 ms, 4,040 points
  in all the parcels 347 → 18 ms. Two exits back to the arrangement are
  load-bearing. **A point exactly on a polygon edge** goes back, because under
  union semantics a point on an edge two polygons share is interior, and only
  the arrangement's radial view sees that. **More than eight points against
  lines or points** goes back, because there membership is a scan: 4,040
  points against 4,040 lines took 167 ms this way and 3.9 ms through the
  sweep. A test in `relate.zig` holds the fast path to the arrangement cell for
  cell on every input it answers.
- **Each thing is written once, and the duplicates were where the bugs
  were.** A deduplication pass found two wrong answers, both from logic that
  existed in more than one copy. `Grid.coordinate` was one of three bucket
  indexes, and the only one that converted to `u32` before clamping: a probe
  far outside the grid trapped in `ReleaseSafe`. The named predicates read
  operand dimensions from the raw input while the matrix used `Set`'s, so
  `POLYGON EMPTY` beside a line made `crosses` pick the area rule and miss a
  crossing. Both have regression tests, and GEOS 3.13 agrees with the fixed
  answers. What is shared now, so it stays shared:
  - `bucket` is the one bucket index, clamped as a float; `Lists` is the one
    counting sort, behind the grid, the edge bands and the segment order.
  - `prepare` builds both operands for every entry point, and dimensions come
    only from `Set.dimension`.
  - `Set.eachNear` is the one polygon-edge walk, for the winding probe and
    the on-an-edge test. It is `inline` and takes a visitor: an iterator
    struct measured 1.9x slower on a whole-dataset `relate`.
  - `Set.edges` is the one list of polygon edges; `collect` reads it rather
    than walking rings again, and `polygon_first` has a sentinel so no caller
    computes a polygon's last edge.
  - From the rest of the tree: `operations.normalized` drops `POLYGON EMPTY`
    for buffer and predicates alike, `operations.normalizedLine` validates a
    line for both, `predicates.onSegment`, `geometry.coordinate_limit`,
    `Extent.grow`, `geometry.ends`, `Collection.split`, and the overlay's
    `keyOf` and `canonical` for coordinate keys.
- **Segments are ordered by a counting sort on x, not `pdq`.** A `pdq`
  instantiation here measured 5.2 KB raw and 2.2 KB gzipped — the comparator
  type is new, so nothing in the overlay's instantiation is shared. The sweep
  only needs the order right between buckets: a segment retires once its right
  end is left of the current bucket's floor.

What did not pay, so it is not tried twice: splitting `predicates.orient` into
an inlinable filter and a `noinline` exact fallback made the artifact **10 KB
larger**, not smaller — the filter then inlined at every call site; and
`noinline` on the five largest functions here changed nothing, so duplicate
inlining is not where the bytes are. The feature's cost is **40.4 KB raw,
16.0 KB gzipped** on top of 133.5 / 50.5 KB, the edge bands and the point fast
path below included: `intersects` alone is about
14 KB raw, the matrix machinery another 17 KB, and carrying the pattern into
the module for lazy evaluation the last 5.4 KB raw / 1.8 KB gzipped — against
the alternative of ten predicate codes in the module, which was 0.3 KB smaller
and could not stop early. Dropping `apart` would save 1.4 KB raw and the
"cannot possibly intersect" exit for every pattern but `intersects`.

## Geometry invariants

- **Allocators are explicit.** `Geometry` owns an arena; call `deinit` once and
  never copy it as an independently owned value. Results never borrow input.
- **Coordinates are planar, in input units.** No CRS is read from or written to
  WKB. Reproject before asking for metre buffers.
- **Floating precision only.** There is no precision option at all. `grid_size`
  existed as a parameter that was accepted and then always rejected; it was
  removed rather than shipped that way, and re-adding it is a feature with a
  design, not a flag to restore.
  There is no integer lattice and no snapping.
- **Exact predicates, no epsilons.** Sign decisions go through
  `predicates.orient`; never introduce a tolerance comparison to "fix" a
  topology bug. Wide intermediates (`f128`) are used for intersection, and for
  `area` — but `areaSign`, which is what both ring-orientation callers actually
  want, filters in `f64` first and only falls back to it. That filter carries a
  proven roundoff bound, not a tolerance; `f128` multiplies are `__multf3`
  libcalls and were 25% of a union before it existed.
  `orient` short-circuits a *degenerate* triple — two of the three points
  bit-identical — before the expansion. That is an equality test, not a
  tolerance, and it is not optional: on parcel data 98% of filter failures are
  exactly that case, and skipping the expansion for them is 1.6x on the sweep.
  See "Where our own time goes" in `TODO.md`.
- **Invalid input is rejected, and that is a product decision, not an
  omission.** It is documented in the README under "Invalid input" as an
  explicit divergence from JTS/GEOS, and it is why the adjudicated vertex error
  is `0 m`. It costs 3 JTS assertions, all degenerate rings. Repair belongs
  upstream in the caller's own pipeline; do not add a fixer here.
- **Failures are errors, not repairs.** Note that JTS and GEOS do *not* hold this
  line for buffer — they fall back to snap-rounded integer grids. See
  `docs/BUFFER_APPROACH.md`; changing the policy here is a decision, not a fix.
  Do not clamp, snap, or discard geometry to make a case pass. `DepthMismatch`
  and `NodingFailure` mean the algorithm is wrong; treat them as bugs. The old
  ~0.6% buffer defect is **gone**: the graph-labelling fallback fixed its
  labelling half and the re-noding pass fixed its noding half, and 57,990
  cluster buffers now fail 0 times. The one thing left is
  `error.UnnodableCrossing` — a crossing f64 cannot place a vertex on, 4 of
  3,946 cluster unions — which is a precision limit, not a bug, and only
  snapping would close it. Read "The buffer produces unclosed boundaries" in
  `TODO.md` before assuming a new report is a different bug.
- **Parsing validates structure, not OGC topology.** Valid input topology is a
  precondition of `unionAll`.
- **One representation, hosts convert.** The library speaks flat coordinate
  blocks. It does not own a GeoJSON serialiser and should not grow one: a
  MapLibre-shaped GeoJSON writer was built, measured *slower* than letting the
  host build the object, and deleted. Overlay results are small — 135,080 parcel
  coordinates union to 3,080 — so conversion at the edge costs under a
  millisecond and belongs to whoever knows the target's types.
- **Buffer composes onto the boolean operations.** `geom_apply` applies a
  nonzero `distance` to the *result* of ops 0-3, not just to op 4. It is done
  inside `abi.zig` rather than by the host calling twice, so the intermediate
  geometry never crosses the boundary. The Zig API composes the same thing by
  hand — `boolean(...)` then `bufferAll(result.polygons, ...)` — and does not
  need an option for it.
- **New operations cost a `Mode` value, not an export.** `geom_apply`
  takes an op code and an operand split; `geometry.Mode.covers` is the entire
  difference between union, intersection, difference and symmetric difference,
  because the overlay already carries a winding counter per operand.
- **`geometry.zig` owns the shared vocabulary.** `Point`, `Box`, `Limits`, and
  the distance helpers live there once. Before adding a bounding box, a budget
  struct or a point-to-segment distance, check it is not already there — all
  three used to exist in three places each.
- `f64x2` vectors are used where they map to `simd128`, and `geometry.vec` /
  `geometry.point` convert. **Measured, that is worth about 1.00x**: a build with
  `simd128` removed runs within noise of one with it (0.97x–1.02x across the
  suite) even though the enabled build emits 1,941 v128 opcodes against 5. The
  hot loops are branch- and pointer-bound, and the exact-predicate fallback is
  scalar by nature. Keep the vector forms — they are no larger and no slower —
  but do not expect performance from widening more of them. Profiling the sweep
  confirms this from the other side: every attempt to cut memory traffic in the
  hot predicates left the sweep phase flat. The wins that landed were a cheaper
  sort and reserving the event arrays, not lane width and not cache layout.
- **Reserve before appending.** Both engines know their edge count before they
  build anything. Letting `ArrayList` grow by doubling copied 267,046 events
  through every step and was three quarters of the sweep's build phase; the
  removed graph backend had the same shape.

## Host ABI (`src/abi.zig`, `src/abi_wkb.zig`)

Single-threaded and non-reentrant. **Eight exports in the WASM build**:
`geom_input`, `geom_apply`, the four `geom_result_*` accessors, `geom_clear`,
and `geom_relate` for the predicates. That is the entire browser surface; `tests/wasm.test.mjs` asserts
the import list is empty. The browser is 90% of the target and size-sensitive:
anything added to `abi.zig` is paid for by every page.

The native library adds three for WKB: `geom_wkb_apply`, `geom_wkb_result_ptr`
and `geom_wkb_result_len`. **Eleven total.** `abi_wkb.zig` links only into the
native library, which is what a Python module would use. The predicates have no
WKB entry point.

Both halves dispatch through one `abi.execute`, so the operation switch, the
operand split and the buffer-composes-onto-a-boolean rule exist once. The two
ABIs differ only in how geometry arrives and how it leaves.

**Nothing in the primary surface says "flat".** There is one input shape, so the
word distinguished nothing; the names that carry a qualifier are the WKB ones,
because those are the conversion path rather than the way the library is meant
to be called. Renaming them back would re-introduce a collision — `abi.zig` and
`abi_wkb.zig` both link into the native library, and both wanted
`geom_result_ptr`.

**There is no allocate/free pair, and adding one back would be a mistake.**
Input bytes are borrowed for the duration of the call, so a native caller passes
whatever memory it already has. Output is library-owned and borrowed through
`geom_result_ptr` / `geom_result_len` until the next call or `geom_clear`. A
host-facing allocator only makes sense for WASM, which cannot reach into linear
memory, and `geom_input` already serves that.
`src/flat.zig` documents the block. It is **1.03x to 1.05x** faster end to end,
not more: serialisation is only 2–6% of a call, and the reason to prefer it is
the codec it deletes from the host, not the milliseconds.
`src/tests.zig` covers both paths and asserts they agree coordinate for
coordinate — keep that true.
Status: 0 ok, 1 allocation, 2 unsupported geometry, 3 limit, 4 precision/range,
5 malformed or overlay failure, 6 invalid options, 7 valid input whose
arrangement f64 cannot represent (`error.UnnodableCrossing`). The 5/7 split is
a compatibility promise; `src/tests.zig` pins it.

Each call clears the previous result. Copy output before the next call, never
free a borrowed result, never feed a borrowed result back as input.
