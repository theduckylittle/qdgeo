# CLAUDE.md

Guidance for working in this repository.

## What this is

**qdgeo** — "Quick & Dirty Geographic Library". A narrow, allocator-explicit 2D
geometry library in **Zig 0.16.0**: the four boolean operations and rounded
signed buffer, over one degenerate-tolerant planar overlay. The deployment target
is **WASM**; the native shared library exists so the differential harness can
call it, and so a Python module has something to link.

Four goals, in the order they break ties:

1. **Speed** — WASM and vector operations, meaningfully faster than Turf.
2. **Small size** — Zig for its minimal, pay-for-what-you-use standard library
   and its C-compatible output. The shipped WASM is **`ReleaseSafe`**, not
   `ReleaseFast`, and that is measured rather than assumed: `ReleaseFast` is
   1.11x faster, **15 KB larger**, and produces bit-identical geometry on all 26
   workloads. It loses on goal 2 as well as goal 4. Build it with
   `-Dwasm-optimize=ReleaseFast` to re-measure; do not ship it.
3. **Tight scope** — buffer and booleans are nearly all of web GIS geometry.
   New functionality is scrutinised hard; see the one-representation and
   browser-surface rules below.
4. **Correctness** — tested against GEOS *and* the JTS test suite. An
   optimisation that costs an answer is not an optimisation.

Not production-ready. Read `TODO.md` first — it holds the current verified
status and the ordered blocker list.

## Toolchain

Built and tested on **Zig 0.16.0**, which is the current stable release and what
`build.zig.zon` requires. There is no stable 0.17 yet; master is `0.17.0-dev`.

The tree also compiles and passes on master, verified against
`0.17.0-dev.2131+d08989840` (2026-09-13): 29 unit tests in both modes, every
build target, `zig fmt --check`, 155/161 JTS, and the cluster corpora at their
recorded 0 and 4. The WASM artifact comes out 1,066 bytes larger.

One change was needed, and it is written so both versions accept it:

- **`**` for array repetition is gone.** `[_]bool{false} ** 100` now tokenizes as
  two `*`, and 0.17 rejects it with "binary operator `'*'` has whitespace on one
  side, but not the other", naming `*` rather than `**` — which is the clue.
  `@splat` replaces it and compiles on 0.16 as well:

  ```zig
  var cells: [100]bool = @splat(false);
  ```

CI builds against the pinned stable release only. Tracking a moving target
there buys noise rather than signal — master breaks things on purpose, and a red
cross that means "upstream changed" trains everyone to ignore the column. Check
master by hand when a release approaches:

```sh
zig build test && zig build wasm && zig fmt --check build.zig src
```

Keeping new code compiling on both is still worth doing while it is this cheap;
`@splat` above was the whole cost so far.

## Commands

```sh
zig build                                  # static library + module
zig build test                             # 22 native tests
zig build test -Doptimize=ReleaseSafe
zig build run                              # rounded rectangle demo
zig build native -Doptimize=ReleaseSafe    # zig-out/lib/libqdgeo_native.so
zig build wasm                             # freestanding, import-free, stripped
npm run fetch-data                         # parcels.geoparquet for the compare suite
npm run compare                            # differential suite (see the `compare` skill)
npm run sizes                              # bundle sizes for every engine
node tests/wasm.mjs                        # WASM runtime checks, no WASI
npm run format:check                       # Prettier, JS and HTML
.venv/bin/python tests/compare/run.py      # differential suite (needs harness fixes)
.venv/bin/python tests/compare/probes.py   # precision probes
.venv/bin/python tests/jts/run.py           # the JTS Topology Suite's own cases
```

Harness setup (venv, `npm ci`, `cargo build --release`) is in
`tests/compare/README.md`. The comparison dataset is
`~/Projects/geomoose/gm3/examples/desktop/parcels.geoparquet` (4,040 parcels,
135,080 points, sha256 `764c0d0a…`); override with `--source`.

## Layout

| Path | Role |
| --- | --- |
| `src/root.zig` | Public API surface |
| `src/geometry.zig` | `Coordinate` / `LinearRing` / `LineString` / `Polygon` / `Extent` / `Geometry`; the `Path`/`Mode`/`Limits` contract the overlay implements |
| `src/offset.zig` | Offset curves for rings, lines and points, the JTS construction |
| `src/flat.zig` | Flat coordinate blocks, the layout OpenLayers holds |
| `src/wkb.zig` | 2D OGC Polygon/MultiPolygon parse and write |
| `src/predicates.zig` | Adaptive `orient` / `areaSign`, f128 `area`, segment `intersection` |
| `src/sweep.zig` | The overlay engine: degenerate-tolerant Martinez-Rueda |
| `src/operations.zig` | `unionAll`, `buffer*`; input normalization, band generation |
| `src/abi.zig` | The host ABI — the whole browser surface, and the wasm root |
| `src/abi_wkb.zig` | The WKB ABI, linked into the native library only |
| `src/native.zig` | Root of the native library: both halves |
| `src/tests.zig` | All native tests |
| `tests/compare/` | Python/Node/Rust differential suite vs GEOS, polyclip-ts, Turf, Rust Geo |
| `docs/BUFFER_APPROACH.md` | Why the buffer is built the way it is, and the JTS/GEOS comparison |

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
cannot hold this arrangement" and "the algorithm is wrong". Both map to ABI
status 5; nothing host-visible changed.

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
was measured too — `parcels-buffer-100-+2` fails outright. There is no separate offsetting algorithm and no band: the overlay keeps
what the curves wind at least once, which is JTS's `depth(RIGHT) >= 1`. Inward
collapse, neck splitting and the spurious loops an offset curve makes at a
concavity all fall out of that count. `docs/BUFFER_APPROACH.md` has the
comparison and the measurements.

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

## Conventions and invariants

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
  is `0 m`. It costs 6 JTS assertions, all degenerate rings. Repair belongs
  upstream in the caller's own pipeline; do not add a fixer here.
- **Failures are errors, not repairs.** Note that JTS and GEOS do *not* hold this
  line for buffer — they fall back to snap-rounded integer grids. See
  `docs/BUFFER_APPROACH.md`; changing the policy here is a decision, not a fix. Do not clamp, snap, or discard geometry
  to make a case pass. `DepthMismatch` and `NodingFailure` mean the algorithm is
  wrong; treat them as bugs. The old ~0.6% buffer defect is **gone**: the
  graph-labelling fallback fixed its labelling half and the re-noding pass fixed
  its noding half, and 57,990 cluster buffers now fail 0 times. The one thing
  left is `error.UnnodableCrossing` — a crossing f64 cannot place a vertex on,
  4 of 3,946 cluster unions — which is a precision limit, not a bug, and only
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
- **The browser is 90% of the target and size-sensitive.** `abi.zig` is the whole
  browser surface: seven exports, no WKB. Anything added there is paid for by
  every page. `abi_wkb.zig` links only into the native library, which is what a
  Python module would use.
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
- **Names follow GeoJSON and OpenLayers.** A `Coordinate` is the x/y pair —
  *Point* means a geometry in both specs, so it is never the pair here. Rings are
  `LinearRing`, open chains are `LineString`, bounds are `Extent`, and a
  `Geometry` holds `polygons` / `line_strings` / `points`. Reach for the spec's
  word before inventing one.
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
- **Every source file carries an SPDX header.** Two lines, `SPDX-License-Identifier: MIT`
  and the copyright, above everything else — above a Zig `//!` module doc, below
  a `<!doctype>` or a shebang. New files get one. There is no third-party code
  in the tree; if any is ever vendored, it keeps its own licence and gets no
  header from us.
- **JavaScript and HTML are Prettier-formatted.** `npm run format`, checked with
  `npm run format:check`; config in `.prettierrc.json`. Committed JSON under
  `tests/compare/fixtures/` and `docs/` is data, not source, and is ignored.
- **Reserve before appending.** Both engines know their edge count before they
  build anything. Letting `ArrayList` grow by doubling copied 267,046 events
  through every step and was three quarters of the sweep's build phase; the
  removed graph backend had the same shape.

## Host ABI

Single-threaded and non-reentrant. **Seven exports in the WASM build**:
`geom_input`, `geom_apply`, the four `geom_result_*` accessors, and
`geom_clear`. That is the entire browser surface; `tests/wasm.mjs` asserts the
import list is empty.

The native library adds four for WKB: `geom_wkb_union`, `geom_wkb_buffer`,
`geom_wkb_result_ptr` and `geom_wkb_result_len`. Eleven total.

**Nothing in the primary surface says "flat".** There is one input shape, so the
word distinguished nothing; the names that carry a qualifier are the WKB ones,
because those are the conversion path rather than the way the library is meant
to be called. Renaming them back would re-introduce a collision — `abi.zig` and
`abi_wkb.zig` both link into the native library, and both wanted
`geom_result_ptr`.

**`js/qdgeo.js` is the binding, and it is part of the library, not the
examples.** It is copied into `examples/lib/` for the example doc root and
gitignored there. Its named methods — `union`, `intersection`, `difference`,
`symmetricDifference`, `buffer` — are what a caller should reach for; `apply` is
the generic escape hatch. The binary methods take two operand lists and compute
`subject` themselves, so the split never reaches a caller. `OP` and `STATUS` are
exported from it, not redefined per example.

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
5 malformed or overlay failure, 6 invalid options.

Each call clears the previous result. Copy output before the next call, never
free a borrowed result, never feed a borrowed result back as input.

## Traps

- The WASM build must stay import-free. Anything reaching for stderr — including
  `std.debug.print` — drags `std.posix` into `wasm32-freestanding` and fails on
  `IOV_MAX`. Guard any diagnostic behind a comptime target check, the way
  `operations.zig` does; `tests/wasm.mjs` asserts the import list is empty.
- **`zig build test` passing does not mean the parcel suite passes**, and
  neither implies the JTS suite. See `tests/CLAUDE.md` — the three suites answer
  three different questions. All currently green: 22 native tests, 26 of 26
  differential workloads native and WASM, and 155 of 161 applicable JTS
  assertions.
- **The boundary metric adjudicates against exact arithmetic** (details in
  `tests/CLAUDE.md`), because GEOS is not a positional oracle on this data — it misplaces nearly parallel
  intersections by up to `1e-4 m` and emits filament rings. Never "fix" a
  Hausdorff failure by widening a tolerance; reconstruct the vertex with
  `fractions.Fraction` and find out which side is wrong. `tests/compare/README.md`
  has the method.
- Every reduced failure is committed under `tests/compare/fixtures/` and probed
  by `tests/compare/probes.py`. All five now pass.
