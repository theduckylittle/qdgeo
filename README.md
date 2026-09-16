# qdgeo

**Quick & Dirty Geographic Library.** Buffer and boolean geometry for web GIS,
written in Zig and compiled to WebAssembly.

qdgeo does five things: union, intersection, difference, symmetric difference,
and rounded buffer. The buffer is also available as an option on the four
boolean operations, so "subtract this, then grow the result by 5 m" is one call.
That is very nearly all the geometry a web mapping application asks for. The WASM artifact is **135 KB raw, 50.8 KB gzipped**,
declares no imports, and has no C or C++ dependency.

> **Status.** The suites are green: 26 of 26 differential workloads, 155 of 161
> applicable JTS assertions, and 0 failures across 57,990 buffers of adjacent
> parcel clusters. The memory envelope is
> [measured and published](#memory-and-what-size-input-this-is-good-for), and
> running out of heap is recoverable rather than fatal.
>
> One known limitation, and it is deliberate:
> [valid input can occasionally fail](#when-valid-input-fails) — 4 of 3,946
> cluster unions — because qdgeo declines to snap coordinates to make an
> arrangement representable. It returns an error there; it never returns
> geometry it could not verify. [TODO.md](TODO.md) tracks what is left.

## At a glance

| | size gzipped | speed | correct | operations bundled |
| --- | ---: | ---: | ---: | --- |
| **qdgeo** | **50.8 KB** | **1.00x** | **26 / 26** | four booleans, buffer |
| polyclip-ts | 15.4 KB | 28x | 10 / 12 | four booleans, **no buffer** |
| JSTS | 73.9 KB | 7.1x | 24 / 26 | four booleans, buffer |
| Turf | 82.3 KB | 17x | 23 / 26 | union, buffer |
| Rust Geo | 102.1 KB | 0.80x | 18 / 26 | union, buffer |
| GEOS | 778 KB † | 1.5x † | 26 / 26 | all of GEOS |

Speed is the geometric mean against qdgeo over each engine's **correct**
workloads; lower is faster. Size is what a browser downloads — JavaScript
bundled with esbuild and minified, WASM as the artifact itself. Regenerate the
sizes with `npm run sizes` and the timings with `npm run compare`.

† GEOS is two artifacts in one row. The speed is **native** GEOS, which is what
the suite measures. The size is the community `geos-wasm` build, the only way to
run GEOS in a browser, which carries the whole library. geos-wasm was not
benchmarked.

polyclip-ts is the smallest entry because it has no buffer. It is the only one
here that does not.

**Choosing between them.** qdgeo is the smallest library that does the whole job
and returns correct geometry on every workload. Rust Geo is faster but returns
wrong geometry on 8 of 26 workloads, including every parcel union. GEOS is
correct and close on speed, but has no supported browser build. Turf and JSTS
are correct almost everywhere and an order of magnitude slower.

## Getting started

```sh
zig build wasm     # zig-out/bin/qdgeo.wasm, freestanding + simd128
```

[`js/qdgeo.js`](js/qdgeo.js) is the binding. A shape is a list of rings, each a
list of `[x, y]`, shell first and holes after:

```js
import { load } from './js/qdgeo.js';
const geo = await load('qdgeo.wasm');

const square = (x, y, w) => [
  [[x, y], [x + w, y], [x + w, y + w], [x, y + w], [x, y]],
];
const a = square(0, 0, 10);
const b = square(5, 5, 10);

geo.union([a, b]); // one shape, area 175
geo.intersection([a], [b]); // the overlap
geo.difference([a], [b]); // a with b cut out
geo.symmetricDifference([a], [b]);
geo.buffer([a], 2); // grown by 2; negative shrinks
geo.buffer([a], 2, { steps: 32 }); // finer arcs
```

Each returns a list of shapes in the same form. The binary operations take two
operand lists, so either side can hold several shapes; `union` and `buffer` are
n-ary over one list.

The module needs no host functions and instantiates with an empty import
object, so calling it directly is reasonable too — `geo.apply(op, a, b, opts)`
is the generic form, and [Host ABI](#host-abi) describes the block layout and
the seven exports.

### Examples

Three standalone pages in [`examples/`](examples/) — plain canvas, OpenLayers,
and MapLibre GL JS — each running all four boolean operations and the buffer
with live controls. They are published from `main` at
**[theduckylittle.github.io/qdgeo](https://theduckylittle.github.io/qdgeo/)**.

To run them locally:

```sh
zig build wasm && cp zig-out/bin/qdgeo.wasm examples/vendor/
cp js/qdgeo.js examples/lib/
python3 -m http.server -d examples 8000   # then open http://localhost:8000/
```

The binding lives in [`js/`](js/) and is copied into the example doc root by the
command above. See [examples/README.md](examples/README.md).

### Building everything else

```sh
zig build                                 # static library/module
zig build test                            # 21 tests
zig build test -Doptimize=ReleaseSafe
zig build run                             # rounded rectangle example
zig build native -Doptimize=ReleaseSafe   # zig-out/lib/libqdgeo_native.so
node tests/wasm.mjs                       # Node runtime checks, no WASI
```

## Design goals

**1. Speed.** WebAssembly and vector operations, to be meaningfully faster than
libraries like Turf rather than incidentally faster. On the full parcel dataset
union that is **24x Turf**, 22x JSTS, and 3.1x native GEOS.

**2. Small size.** Zig's standard library is minimal and pay-for-what-you-use,
and it emits C-compatible library formats. Every byte in the artifact is paid
for by every page that loads it.

**3. Tight scope.** Buffers and boolean operations are very nearly the whole of
what web GIS does with geometry. Anything else has to argue its way in.

**4. Correctness.** Operations are tested against GEOS and against the JTS
Topology Suite's own test cases. Where an optimisation and an answer conflict,
the answer wins.

The shipped WASM keeps its runtime safety checks. They are close to free:

| | raw | gzipped | speed | output |
| --- | ---: | ---: | ---: | --- |
| `ReleaseSafe` (shipped) | 135 KB | 50.8 KB | 1.00x | — |
| `ReleaseFast` | 135 KB | 48.3 KB | 1.11x | bit-identical |

`ReleaseFast` is 11% faster, the same size raw and 2.5 KB smaller gzipped, and
produces byte-for-byte identical geometry across all 26 workloads.
`ReleaseSmall` reaches 73 KB raw and 32.6 KB gzipped if size ever matters more
than either.

## The parcel dataset

qdgeo was written for [GeoMoose](https://www.geomoose.org/), to give it a
lighter and faster geometry library. GeoMoose is used mainly for county parcel
applications, so county parcels are the workload qdgeo is tuned for.

Parcels also make an unusually good test corpus. They are irregular, they
occasionally overlap, and their boundaries follow natural features like rivers
and ridgelines. That produces the cases that break overlay engines: hairline
gaps between neighbours, nearly parallel edges, and long chains of shared
boundary.

The benchmark dataset is **4,040 parcels, 135,080 coordinates**, from the public
GeoMoose demo data. `npm run fetch-data` downloads it and verifies its SHA-256,
so the numbers below reproduce on any machine.

## Benchmarks

Every engine runs the same parcel dataset over 26 workloads covering all four
boolean operations and buffer. Every figure is the **median of three independent
suite runs, each itself a median of 11 repeats**, on one idle machine.

Three runs because one is not reproducible enough to publish: between two clean
runs the JavaScript engines' geometric means moved by up to 31%, and Turf's
smallest cases by 300%, which is JIT warmup rather than anything about the
geometry. qdgeo, GEOS and Rust Geo stayed within 11%. Ratios are quoted to two
significant figures because the third is noise.

**A wrong answer is not a fast answer.** Where an engine returns the wrong
geometry its time is marked †, and it is excluded from every average. Rust Geo
fails all four parcel unions, which are its biggest wins.

Versions: GEOS 3.13.1 (Shapely 2.1.2), JSTS 2.12.1, Turf 7.4.0, polyclip-ts
0.16.8, Rust Geo 0.33.1. Reproduce with `npm run fetch-data && npm run compare`.

### Correctness

| | workloads passed | worst vertex error | rings returned |
| --- | ---: | ---: | ---: |
| **qdgeo** | **26 / 26** | **0 m** | 444 |
| GEOS | 26 / 26 | 7.2e-5 m | 445 |
| JSTS | 24 / 26 | 1.4e-5 m | 447 |
| Turf | 23 / 26 | 2.0e-4 m | 444 |
| polyclip-ts | 10 / 12 | 2.0e-4 m | 444 |
| Rust Geo | 18 / 26 | 1961 m | **382** |

Vertex error is the distance from a disputed output vertex to where exact
rational arithmetic puts it. Ring counts are for the full-dataset union. GEOS is
the reference but not an oracle, so the suite reconstructs disputed vertices
exactly; that is why GEOS has an error column of its own.

Rust Geo drops **63 of 445 rings**. It snaps every coordinate onto an integer
lattice, which closes the hairline gaps between parcels. Symmetric-difference
area barely moves, because a collapsed hairline has almost no area, but the
boundaries are gone.

polyclip-ts runs union only, so it has 12 workloads rather than 26.

### Union

Milliseconds. † marks a wrong answer.

| parcels | qdgeo wasm | qdgeo native | GEOS | Rust Geo | JSTS | Turf | polyclip-ts |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 0.32 | 0.12 | 0.28 | 0.052 † | 14.6 | 3.01 | 5.96 |
| 100 | 1.49 | 1.15 | 4.11 | 0.37 † | 44.2 | 24.4 | 25.9 |
| 1,000 | 20.3 | 16.8 | 65.7 | 2.63 † | 533 † | 495 † | 513 † |
| 4,040 | 160 | 130 | 426 | 14.5 † | 3640 † | 3710 † | 3770 † |

On the two largest unions, only qdgeo and GEOS return the right geometry.

### Buffer

| case | qdgeo wasm | GEOS | Rust Geo | JSTS | Turf |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 parcel, +2 m | 0.046 | 0.057 | 0.034 | 0.35 | 1.17 |
| 100 parcels, +2 m | 1.30 | 4.54 | 0.35 | 32.7 | 29.5 |
| 100 parcels, -10 m | 1.46 | 4.36 | 0.51 † | 32.9 | 30.2 |
| 19,208-coordinate parcel, +2 m | 33.2 | 8.25 | 53.2 | 29.1 | 90.0 |
| 19,208-coordinate parcel, -2 m | 31.9 | 13.0 | 66.8 | 28.7 | 82.7 |

### Overall

Geometric mean against qdgeo in WASM, over each engine's **correct** workloads
only. Above 1.00 is slower than qdgeo.

| | speed | workloads averaged | excluded as wrong |
| --- | ---: | ---: | --- |
| Rust Geo | 0.80x | 18 | all 4 parcel unions, 2 eroding buffers, 2 others |
| **qdgeo wasm** | **1.00x** | 26 | none |
| GEOS native | 1.5x | 26 | none |
| JSTS | 7.1x | 24 | 2 parcel unions |
| Turf | 17x | 23 | 2 parcel unions, 1 buffer |
| polyclip-ts | 28x | 10 | 2 parcel unions |

Across the three runs those means spanned 0.76-0.84, 1.36-1.62, 7.10-8.20,
14.7-19.3 and 24.3-29.1 respectively. Treat them as one significant figure of
real information each.

Timing boundaries are not equal across engines. qdgeo and Rust Geo are the only
matched pair: both WASM, same Node process, same flat ABI. GEOS is native and
receives live geometry objects, so it pays no parse or encode where qdgeo pays a
full WKB round trip. Turf's buffers include reprojection. Medians also move with
machine state, so treat a gap under 20% as unresolved.
[tests/compare/README.md](tests/compare/README.md) documents each boundary.

## Invalid input

**qdgeo rejects invalid geometry. It does not repair it.**

A ring with zero area, fewer than four points, or a coordinate outside the
supported range returns an error code. Nothing is snapped, clamped, or collapsed
to make a call succeed.

JTS and GEOS choose differently. They buffer a degenerate polygon by falling
back to its linework, and when floating-point noding fails they retry on
progressively coarser snap-rounded grids before giving up.

| | qdgeo | JTS / GEOS |
| --- | --- | --- |
| Degenerate ring | error | buffers its linework |
| Noding failure | error | retries on coarser grids |
| Precision option | none | fixed precision models |
| When it answers | the answer is exact | the answer may be snapped |

The "noding failure" row is not only about bad geometry — it is also the one
case where **valid** input can fail. See the next section.

That is why they answer where qdgeo errors. It is also why a snapped result
answers a slightly different question than the one you asked.

This choice costs qdgeo 6 of 161 JTS assertions, all degenerate rings, and it is
why the vertex error above reads `0 m`. The two are the same decision.

**What to do about it.** Clean your geometry first. Repair belongs upstream,
where the caller knows what the data is meant to represent. Shapely's
`make_valid`, PostGIS's `ST_MakeValid`, and JTS's `GeometryFixer` all do this
well, and qdgeo does not try to compete with them.

## When valid input fails

Rarely, qdgeo returns an error for geometry that is perfectly valid. Measured on
the parcel dataset: **4 of 3,946 unions of adjacent-parcel clusters, and 0 of
57,990 cluster buffers**. The full 4,040-parcel union is not affected.

The cause is a crossing that `f64` cannot hold. Two segments cross, the exact
intersection is computed, and rounding it to the nearest `f64` puts it on or
past an endpoint of one of them. Placing a vertex there would move the crossing
off the other segment's line, so qdgeo declines to place one, and the
arrangement has a crossing with no node on it. Adding more noding passes does
not help: the geometry is already at a fixed point. Only snapping the two
near-coincident vertices together would close it, and that is the trade this
library has already declined.

**What this means for a caller.**

- It is an error, never a wrong answer. qdgeo does not return geometry it could
  not verify.
- It is reported as ABI status `5`, the same code as malformed input. A host
  that wants to tell the two apart has to check its input separately for now.
  The native Zig API is more specific: `error.UnnodableCrossing` rather than
  `error.NodingFailure`.
- Retrying the identical call will fail identically. It is deterministic.
- Nudging the input helps, because the failure depends on one pair of nearly
  coincident vertices: simplifying with a tolerance a few orders of magnitude
  above the coordinates' precision, or rounding coordinates to a grid you are
  willing to accept, usually moves past it. Both change the answer slightly,
  which is why qdgeo will not do either on your behalf.
- Splitting work into smaller batches makes this **more** likely, not less. Each
  overlay call carries the exposure independently, and a subset's geometry is
  not easier than the whole. Unioning the 4,040 parcels in batches of 250 hit
  four failures; in batches of 500 or 1,000, none, with a bit-identical result.

If you need an answer for every input more than you need an exact one, GEOS and
JTS snap-round and will return something here.

## Memory, and what size input this is good for

The browser is the target, so the ceiling is the WASM heap: **512 MiB**, set in
`build.zig`. Peak use, measured through the flat ABI by reading
`memory.buffer.byteLength` after each call:

| workload | input coordinates | peak heap | KiB per coordinate |
| --- | ---: | ---: | ---: |
| union, 10 parcels | 80 | 1.5 MiB | 19.2 |
| union, 100 parcels | 936 | 2.8 MiB | 3.08 |
| union, 1,000 parcels | 17,231 | 11.6 MiB | 0.69 |
| union, 4,040 parcels | 135,080 | 81.8 MiB | 0.62 |
| buffer, 19,208-coordinate parcel | 19,208 | 23.7 MiB | 1.26 |

Fixed overhead dominates below about a thousand coordinates. Past that the
marginal cost settles near **0.62 KiB per coordinate for a union and 1.3 for a
buffer**, which puts the 512 MiB cap somewhere above 700,000 coordinates for a
union and 350,000 for a buffer. Those two figures are extrapolated from the
measured range, not measured themselves — treat them as the order of magnitude,
not a contract.

Two things that are measured rather than extrapolated:

- **Memory is reused between calls.** Eight repeats of the same workload hold
  flat at the same peak, so the high-water mark is one call's working set and
  not a running total. A long-lived page does not creep.
- **Running out is recoverable.** An allocation the heap cannot satisfy returns
  status `1`, not a trap, and the next call works normally.
  `tests/wasm.mjs` asserts both.

The one case that costs noticeably more is an input that fails and gets retried:
the fallback described in [When valid input fails](#when-valid-input-fails) runs
the overlay again over a larger, fully-noded path set, at roughly **1.8x** the
peak of a call that succeeds first time.

If your input is larger than this, fold it in batches — `unionAll` is n-ary and
associative, so unioning in groups and then unioning the groups gives the same
answer. Folding the 4,040 parcels in batches of 500 or 1,000 returns geometry
identical to the one-shot union. Keep the batches large: at 250 the extra
overlay calls hit the failure mode above four times, where the one-shot union
and the larger batches hit it zero times.

## The JTS test suite

JTS is the reference implementation for this kind of geometry, and GEOS is a
port of it. `tests/jts/cases/` holds JTS's own test XML, copied **verbatim**
under EDL-1.0, so "passes the JTS suite" means the actual suite.

```sh
zig build native -Doptimize=ReleaseSafe
npm run test:jts
```

| File | pass | fail | skip |
| --- | ---: | ---: | ---: |
| `TestOverlayAA.xml` | 40 | 0 | 4 |
| `TestNGOverlayA.xml` | 80 | 0 | 8 |
| `TestBuffer.xml` | 35 | 6 | 0 |
| **Total** | **155** | **6** | **12** |

**Every boolean operation assertion passes: 120 of 120**, across both JTS's
original overlay engine and OverlayNG.

The 12 skips expect a Point, LineString, or GeometryCollection. qdgeo returns
polygons only, so they are out of scope and are counted separately rather than
scored as passes. The 6 failures are all degenerate rings — see
[Invalid input](#invalid-input).

Buffers run at `quadrantSegments = 8`, which is JTS's default and what the
expected geometry was generated with. Buffer results use the tolerance
comparison `TestBuffer.xml` asks for by name; overlay results must be exactly
equal. [tests/CLAUDE.md](tests/CLAUDE.md) covers both.

## Host ABI

**One representation: flat coordinate blocks.** Conversion to and from a host's
own types belongs to the host, which knows them. Both integration targets
already speak this layout — OpenLayers stores `flatCoordinates` plus ring and
polygon ends, and Shapely's `to_ragged_array` returns coordinates plus the same
offsets — so for both it is a bulk copy rather than a serialiser.

    [ 2 * coordinates f64 ][ rings u32 ][ polygons u32 ][ line strings u32 ]

Every index is an exclusive end offset. Offsets count *coordinates*, not
numbers, so they do not depend on OpenLayers' stride. Coordinates run in a fixed
order: Points, then LineString vertices, then LinearRing vertices. Polygon ends
index into the ring ends.

Every geometry type falls out of that layout. A Point is one coordinate. A
MultiLineString is the line strings. A MultiPolygon is the rings, cut into
polygons by the polygon ends. A GeometryCollection is all three at once.

There is only one input shape, so no export says "flat". The names that carry a
qualifier are the WKB ones below, because those are the conversion path.

Single-threaded and non-reentrant:

- `geom_input(coordinates, rings, polygons, line_strings, points) -> ptr` —
  reserve the block and get its address. Reused across calls when big enough.
- `geom_apply(op, subject, distance, steps) -> status` — `op` is
  0 union, 1 intersection, 2 difference, 3 symmetric difference, 4 buffer.
  `subject` is how many leading polygons form the first operand; the rest are
  the second. A new operation costs a value here, not another export.

  The binding hides `subject`: its binary methods take two operand lists and
  work the split out, which is the same thing said in a way a caller can read.

  `distance` applies to **every** operation, not only op 4. On a boolean
  operation a nonzero distance buffers the result, so "intersect these two, then
  grow the overlap by 5 m" is a single call and the intermediate geometry never
  crosses the boundary. Pass `0` to leave a boolean result alone. `steps` is
  segments per quarter circle on a rounded corner.
- `geom_result_ptr()`, `geom_result_coordinates()`, `geom_result_rings()`,
  `geom_result_polygons()` — results are always areal, so the result block
  carries coordinates, ring ends, and polygon ends.
- `geom_clear()` releases the result.

Status: 0 success, 1 allocation error where recoverable, 2 unsupported geometry,
3 count/point limit, 4 precision/range error, 5 malformed geometry or overlay
failure, 6 invalid options.

Status `5` covers both "this geometry is malformed" and "this arrangement is not
representable in `f64`" — see [When valid input fails](#when-valid-input-fails),
which is rare but happens to input that is entirely valid.

### WKB, native only

The browser is 90% of the target and is size-sensitive, so WKB is kept out of
the WASM build entirely. The coordinate block is the whole browser surface:
seven exports, no parser, no writer.

The native library keeps WKB, because that is how qdgeo reaches GeoParquet,
PostGIS, and the comparison suite. A Python module would link the same path.
These are conversion conveniences for a host that already holds WKB, which is
why they are the ones carrying a qualifier:

- `geom_wkb_union(ptr, len) -> status`
- `geom_wkb_buffer(ptr, len, distance, steps) -> status`
- `geom_wkb_result_ptr()`, `geom_wkb_result_len()`

Input bytes are borrowed for the duration of the call. Results go through
`geom_clear()` like any other. The four boolean operations are not all here:
WKB exists to convert, and a host that wants intersection or difference is
better served by the coordinate block, which has them for free.

## Zig API

```zig
const geo = @import("qdgeo");
var input = try geo.wkb.parse(allocator, bytes, .{});
defer input.deinit();
var united = try geo.unionAll(allocator, input.polygons, .{});
defer united.deinit();
var buffered = try geo.bufferAll(allocator, input.polygons, 2.0, .{
    .quadrant_segments = 16,
});
defer buffered.deinit();
const output = try geo.wkb.write(allocator, buffered.polygons, .little);
defer allocator.free(output);
```

All coordinates and distances are **planar, in input coordinate units**.
Reproject longitude/latitude to an appropriate metric CRS before requesting
metre buffers. The library does not infer or transform CRS from WKB.

### Types

Types carry GeoJSON and OpenLayers names. `Coordinate { x, y }` is the pair —
both specs call a *Point* a geometry, not a coordinate. `LinearRing` and
`LineString` are `[]const Coordinate`, `Polygon { rings }` holds the shell first
and holes after, and rings must close. `Extent` is the bounding box OpenLayers
calls an extent. All are borrowed views.

`Geometry` carries `polygons`, `line_strings`, and `points`, matching
MultiPolygon / MultiLineString / MultiPoint. It owns an arena and its output
slices. Call `deinit` exactly once, and do not copy it as an independently owned
value. Results never borrow input storage.

### Operations

- `boolean(allocator, subject, clip, Mode, BooleanOptions) !Geometry` is all
  four boolean operations; `Mode` is the only thing that separates them.
  `unionAll(allocator, polygons, BooleanOptions) !Geometry` is the n-ary union
  over one list. Valid input topology is a precondition and is not fully
  validated. Input winding and repeated points are normalised before overlay.
- `buffer(allocator, BufferInput, distance, BufferOptions) !Geometry` takes
  polygons, lines, and points together: a point buffers to a disc, a line to a
  stadium, and neither survives a negative distance. `bufferAll(allocator,
  polygons, distance, BufferOptions)` is the same call with only polygons, which
  is the common case. Areal input is unioned first. Holes, splitting, and
  collapse are all supported. Zero distance runs union and normalisation, not a
  byte-identical copy.

Buffer uses the JTS/GEOS construction: one raw, self-intersecting offset curve
per ring, line, and point, resolved by the overlay's winding depth. See
[docs/BUFFER_APPROACH.md](docs/BUFFER_APPROACH.md). Unlike JTS, input
simplification is off by default — it costs `0.01 * distance` of accuracy and
buys nothing here — and there is no reduced-precision retry ladder.

**Floating precision only.** There is no precision option, no integer lattice,
and no snapping; see [Invalid input](#invalid-input) for why. `BooleanOptions`
carries segment, point, and work limits. `BufferOptions` adds
`quadrant_segments` (1..1024, default 16). Output limits are checked **after**
solution construction, not as an allocation budget.

### WKB

`wkb.parse(allocator, bytes, Limits) !Geometry` accepts 2D OGC Point,
LineString, Polygon, their Multi- forms, and GeometryCollection, including
nested collections. It handles either byte order including mixed children, empty
geometries, and adjacent repeated coordinates. It rejects truncated or trailing
bytes, bad counts, nonfinite coordinates, unclosed rings, EWKB/SRID, and Z/M.

Parsing validates **structure, not OGC topology**. Defaults are 1M points, 100K
rings, and 100K polygons. `wkb.write(allocator, polygons, endian) ![]u8` returns
owned MultiPolygon WKB.

## Internals

The overlay is a degenerate-tolerant Martinez-Rueda sweep line
(`src/sweep.zig`), using winding counts rather than in/out parity, exact
adaptive predicates at every sign decision, and structure-of-arrays storage with
order-preserving `u128` sort keys. [CLAUDE.md](CLAUDE.md) documents the design
and the invariants that are easy to break.

## Continuous integration

Two workflows in [`.github/workflows/`](.github/workflows/).

**`ci.yml`** runs on every push and pull request: unit tests in Debug and
ReleaseSafe, all four build targets, the WASM runtime checks, Prettier, `zig fmt`,
and the JTS Topology Suite. It prints the artifact size to the run summary, so a
change that inflates the download is visible in the pull request.

The JTS step is gated with `--expect 155` rather than `--strict`. The six
failures are the [invalid input](#invalid-input) policy, so `--strict` would
always trip; a drop below the baseline is a regression, and raising the baseline
is a deliberate commit.

**`pages.yml`** rebuilds the WASM module, assembles `examples/` into a site with
the fresh module, checks every page is present, and deploys to GitHub Pages.
Enable it once under **Settings → Pages → Source → GitHub Actions**.

The differential comparison suite is not in CI. It needs a Rust toolchain, GEOS,
the parcel dataset and several npm engines, and it measures timings, which a
shared runner cannot do meaningfully. Run it locally with `npm run compare`.

Neither are the parcel cluster corpora, for the same reason — they need the
dataset. They are the layer that has caught every overlay defect this engine has
had, so run them before publishing a correctness claim. Both are scripted under
[`.claude/skills/`](.claude/skills/): `correctness` for the full sweep,
`compare` for the published tables.

## License

MIT. See [LICENSE.txt](LICENSE.txt). Every source file carries an SPDX header.

The **library** contains no third-party code: pure Zig, no C or C++ dependency,
and the WASM build declares no imports. The one third-party thing in the tree is
**test data** — JTS's own test cases under `tests/jts/cases/`, redistributed
under EDL-1.0 with the notice they require, deliberately unmodified.
