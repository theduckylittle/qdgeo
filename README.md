# qdgeo

**Quick & Dirty Geographic Library.** Buffer and boolean geometry for web GIS,
written in Zig and compiled to WebAssembly.

qdgeo does five things: union, intersection, difference, symmetric difference,
and rounded buffer. That is very nearly all the geometry a web mapping
application asks for. The WASM artifact is **112 KB raw, 43.9 KB gzipped**,
declares no imports, and has no C or C++ dependency.

> **Still experimental.** The test suites are green — 26 of 26 differential
> workloads, and 155 of 161 applicable JTS assertions — but the resource
> envelope is not yet bounded or documented. [TODO.md](TODO.md) lists what is
> left before this warning comes off.

## At a glance

| | size gzipped | speed | correct | operations bundled |
| --- | ---: | ---: | ---: | --- |
| **qdgeo** | **43.9 KB** | **1.00x** | **26 / 26** | four booleans, buffer |
| polyclip-ts | 15.4 KB | 31.3x | 10 / 12 | four booleans, **no buffer** |
| JSTS | 73.9 KB | 6.9x | 24 / 26 | four booleans, buffer |
| Turf | 82.3 KB | 21.8x | 23 / 26 | union, buffer |
| Rust Geo | 102.1 KB | 0.75x | 18 / 26 | union, buffer |
| GEOS | 778 KB † | 1.39x † | 26 / 26 | all of GEOS |

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

The module needs no host functions, so it instantiates with an empty import
object:

```js
const bytes = await (await fetch('qdgeo.wasm')).arrayBuffer();
const { instance } = await WebAssembly.instantiate(bytes, {});
const q = instance.exports;

// Two overlapping squares, one polygon each. Every ring must close.
const coords = [0, 0, 10, 0, 10, 10, 0, 10, 0, 0, 5, 5, 15, 5, 15, 15, 5, 15, 5, 5];
const ringEnds = [5, 10]; // exclusive ends, counted in coordinates
const polygonEnds = [1, 2]; // exclusive ends, counted in rings
const total = coords.length / 2;

const ptr = q.geom_flat_input(total, ringEnds.length, polygonEnds.length, 0, 0);
new Float64Array(q.memory.buffer, ptr, coords.length).set(coords);
new Uint32Array(q.memory.buffer, ptr + 16 * total, ringEnds.length + polygonEnds.length)
  .set([...ringEnds, ...polygonEnds]);

const status = q.geom_flat_execute(0, 1, 0, 0); // op 0 = union
if (status) throw new Error(`qdgeo status ${status}`);

const n = q.geom_flat_result_coordinates(); // 9 coordinates, one ring, area 175
const xy = new Float64Array(q.memory.buffer, q.geom_flat_result_ptr(), 2 * n);
q.geom_clear();
```

That is the whole interface. [Host ABI](#host-abi) describes the block layout
and the seven exports.

### Examples

Three standalone pages in [`examples/`](examples/) — plain canvas, OpenLayers,
and MapLibre GL JS — each running all four boolean operations and the buffer
with live controls.

```sh
zig build wasm && cp zig-out/bin/qdgeo.wasm examples/vendor/
python3 -m http.server -d examples 8000   # then open /canvas.html
```

`examples/lib/geometry.js` wraps the ABI in about a hundred lines if you would
rather not call it directly. See [examples/README.md](examples/README.md).

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
| `ReleaseSafe` (shipped) | 112 KB | 43.9 KB | 1.00x | — |
| `ReleaseFast` | 127 KB | 44.9 KB | 1.11x | bit-identical |

`ReleaseFast` is 11% faster and 15 KB larger, and produces byte-for-byte
identical geometry across all 26 workloads. `ReleaseSmall` reaches 65 KB raw and
28 KB gzipped if size ever matters more than either.

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
boolean operations and buffer. Medians of 11 runs on one machine.

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
| 10 | 0.18 | 0.14 | 0.35 | 0.04 † | 10.2 | 3.10 | 5.39 |
| 100 | 2.12 | 1.36 | 4.08 | 0.19 † | 41.0 | 21.5 | 22.9 |
| 1,000 | 21.5 | 20.2 | 66.9 | 2.53 † | 479 † | 437 † | 452 † |
| 4,040 | 160 | 144 | 452 | 14.3 † | 3566 † | 3843 † | 3823 † |

On the two largest unions, only qdgeo and GEOS return the right geometry.

### Buffer

| case | qdgeo wasm | GEOS | Rust Geo | JSTS | Turf |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 parcel, +2 m | 0.06 | 0.08 | 0.08 | 0.64 | 2.47 |
| 100 parcels, +2 m | 1.40 | 4.74 | 0.36 | 36.0 | 29.8 |
| 100 parcels, -10 m | 1.65 | 4.73 | 0.51 † | 36.0 | 37.1 |
| 19,208-coordinate parcel, +2 m | 40.5 | 8.88 | 54.7 | 29.1 | 89.5 |
| 19,208-coordinate parcel, -2 m | 38.4 | 14.3 | 70.0 | 29.0 | 83.1 |

GEOS is 3-4x faster at buffering a single very complex polygon, because JTS
snap-rounds the offset curve instead of noding it exactly.

### Overall

Geometric mean against qdgeo in WASM, over each engine's **correct** workloads
only. Above 1.00 is slower than qdgeo.

| | speed | workloads averaged | excluded as wrong |
| --- | ---: | ---: | --- |
| Rust Geo | 0.75x | 18 | all 4 parcel unions, 2 eroding buffers, 2 others |
| **qdgeo (wasm)** | **1.00x** | 26 | none |
| GEOS (native) | 1.39x | 26 | none |
| JSTS | 6.9x | 24 | 2 parcel unions |
| Turf | 21.8x | 23 | 2 parcel unions, 1 buffer |
| polyclip-ts | 31.3x | 10 | 2 parcel unions |

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

That is why they answer where qdgeo errors. It is also why a snapped result
answers a slightly different question than the one you asked.

This choice costs qdgeo 6 of 161 JTS assertions, all degenerate rings, and it is
why the vertex error above reads `0 m`. The two are the same decision.

**What to do about it.** Clean your geometry first. Repair belongs upstream,
where the caller knows what the data is meant to represent. Shapely's
`make_valid`, PostGIS's `ST_MakeValid`, and JTS's `GeometryFixer` all do this
well, and qdgeo does not try to compete with them.

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

Single-threaded and non-reentrant:

- `geom_flat_input(coordinates, rings, polygons, line_strings, points) -> ptr` —
  reserve the block and get its address. Reused across calls when big enough.
- `geom_flat_execute(op, subject, distance, steps) -> status` — `op` is
  0 union, 1 intersection, 2 difference, 3 symmetric difference, 4 buffer.
  `subject` is how many leading polygons form the first operand; the rest are
  the second. A new operation costs a value here, not another export.
- `geom_flat_result_ptr()`, `geom_flat_result_coordinates()`,
  `geom_flat_result_rings()`, `geom_flat_result_polygons()` — results are always
  areal, so the result block carries coordinates, ring ends, and polygon ends.
- `geom_clear()` releases the result.

Status: 0 success, 1 allocation error where recoverable, 2 unsupported geometry,
3 count/point limit, 4 precision/range error, 5 malformed geometry or overlay
failure, 6 invalid options.

### WKB, native only

The browser is 90% of the target and is size-sensitive, so WKB is kept out of
the WASM build entirely. The flat block is the whole browser surface: seven
exports, no parser, no writer.

The native library keeps WKB, because that is how qdgeo reaches GeoParquet,
PostGIS, and the comparison suite. A Python module would link the same path.

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

- `unionAll(allocator, polygons, UnionOptions) !Geometry` is an n-ary union.
  Valid input topology is a precondition and is not fully validated. Input
  winding and repeated points are normalised before overlay.
- `buffer(allocator, polygon, distance)` uses default rounded joins, and
  `bufferWithOptions` configures them. `bufferInput(allocator, Input, distance,
  BufferOptions)` takes polygons, lines, and points together: a point buffers to
  a disc, a line to a stadium, and neither survives a negative distance. Areal
  input is unioned first. Holes, splitting, and collapse are all supported. Zero
  distance runs union and normalisation, not a byte-identical copy.

Buffer uses the JTS/GEOS construction: one raw, self-intersecting offset curve
per ring, line, and point, resolved by the overlay's winding depth. See
[docs/BUFFER_APPROACH.md](docs/BUFFER_APPROACH.md). Unlike JTS, input
simplification is off by default — it costs `0.01 * distance` of accuracy and
buys nothing here — and there is no reduced-precision retry ladder.

**Floating precision only.** There is no precision option, no integer lattice,
and no snapping; see [Invalid input](#invalid-input) for why. `UnionOptions`
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

## License

MIT. See [LICENSE.txt](LICENSE.txt). Every source file carries an SPDX header.

The **library** contains no third-party code: pure Zig, no C or C++ dependency,
and the WASM build declares no imports. The one third-party thing in the tree is
**test data** — JTS's own test cases under `tests/jts/cases/`, redistributed
under EDL-1.0 with the notice they require, deliberately unmodified.
