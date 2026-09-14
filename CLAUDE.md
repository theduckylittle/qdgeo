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

## Commands

```sh
zig build                                  # static library + module
zig build test                             # 22 native tests
zig build test -Doptimize=ReleaseSafe
zig build run                              # rounded rectangle demo
zig build native -Doptimize=ReleaseSafe    # zig-out/lib/libqdgeo_native.so
zig build wasm                             # freestanding, import-free, stripped
npm run fetch-data                         # parcels.geoparquet for the compare suite
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
| `src/abi.zig` | The flat ABI — the whole browser surface, and the wasm root |
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

## Buffer

`src/offset.zig` emits **one raw, self-intersecting offset curve** per ring, per
line and per point — the JTS/GEOS construction, ported. `bufferInput` emits a
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
  wrong; treat them as bugs.
- **Parsing validates structure, not OGC topology.** Valid input topology is a
  precondition of `unionAll`.
- **One representation, hosts convert.** The library speaks flat coordinate
  blocks. It does not own a GeoJSON serialiser and should not grow one: a
  MapLibre-shaped GeoJSON writer was built, measured *slower* than letting the
  host build the object, and deleted. Overlay results are small — 135,080 parcel
  coordinates union to 3,080 — so conversion at the edge costs under a
  millisecond and belongs to whoever knows the target's types.
- **The browser is 90% of the target and size-sensitive.** `abi.zig` is the whole
  browser surface: eight exports, no WKB. Anything added there is paid for by
  every page. `abi_wkb.zig` links only into the native library, which is what a
  Python module would use.
- **New operations cost a `Mode` value, not an export.** `geom_flat_execute`
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

Single-threaded and non-reentrant. `geom_alloc` / `geom_free` for input,
`geom_union{,_with_options}`, `geom_buffer{,_with_options}`,
`geom_result_ptr` / `geom_result_len` to borrow output, `geom_clear` to release.

There is a second, equivalent path in flat coordinates —
`geom_flat_input` / `geom_flat_union` / `geom_flat_buffer` / `geom_flat_result_*` —
carrying the layout OpenLayers already holds, so a browser host needs no codec.
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
