# qdgeo

**Quick & Dirty Geographic Library.** Buffer and boolean geometry for web GIS,
written in Zig and compiled to WebAssembly.

qdgeo does five things: union, intersection, difference, symmetric difference,
and rounded buffer. The buffer is also available as an option on the four
boolean operations, so "subtract this, then grow the result by 5 m" is one call.
It also answers the spatial predicates — `intersects`, `contains`, `touches`
and the rest, and the DE-9IM `relate` matrix they are read from — over any mix
of points, lines and polygons. That is very nearly all the geometry a web
mapping application asks for. The WASM artifact is **173.9 KB raw, 66.5 KB
gzipped**, declares no imports, and has no C or C++ dependency.

> **Status.** The suites are green: 26 of 26 differential workloads, 155 of 158
> applicable JTS overlay and buffer assertions, 330 of 330 JTS predicate
> assertions, and 0 failures across 57,990 buffers of adjacent parcel
> clusters. The memory envelope is
> [measured and published](#memory-and-what-size-input-this-is-good-for), and
> running out of heap is recoverable rather than fatal.
>
> One known limitation, and it is deliberate:
> [valid input can occasionally fail](#when-valid-input-fails) — 4 of 3,946
> cluster unions — because qdgeo declines to snap coordinates to make an
> arrangement representable. It returns an error there; it never returns
> geometry it could not verify. [TODO.md](TODO.md) tracks what is left.

## At a glance

|             | size gzipped |     speed |     correct | operations bundled                |
| ----------- | -----------: | --------: | ----------: | --------------------------------- |
| **qdgeo**   |  **66.5 KB** | **1.00x** | **26 / 26** | four booleans, buffer, predicates |
| polyclip-ts |      15.4 KB |       26x |     10 / 12 | four booleans, **no buffer**      |
| JSTS        |      73.9 KB |      7.3x |     24 / 26 | four booleans, buffer             |
| Turf        |      82.3 KB |       19x |     23 / 26 | union, buffer                     |
| Rust Geo    |     102.1 KB |     0.86x |     18 / 26 | union, buffer                     |
| GEOS        |     778 KB † |    1.8x † |     26 / 26 | all of GEOS                       |

Speed is the geometric mean against qdgeo over each engine's **correct**
workloads; lower is faster. Size is what a browser downloads — JavaScript
bundled with esbuild and minified, WASM as the artifact itself. Regenerate the
sizes with `npm run sizes` and the timings with `npm run compare`.

† GEOS is two artifacts in one row. The speed is **native** GEOS, which is what
the suite measures. The size is the community `geos-wasm` build, the only way to
run GEOS in a browser, which carries the whole library. geos-wasm was not
benchmarked.

polyclip-ts is the smallest entry because it has no buffer. It is the only one
here that does not. The predicates are 16.0 KB of qdgeo's gzipped size. Adding
them to the others, bundled the same way, takes JSTS to 75.8 KB, Turf to 95.8 KB
and Rust Geo to 162.2 KB — see [Predicates](#predicates), which also has the
speed comparison: on predicates Rust Geo is faster than qdgeo on most
workloads, and qdgeo is faster at point-in-polygon.

**Choosing between them.** qdgeo is the smallest library that does the whole job
and returns correct geometry on every workload. Rust Geo is faster but returns
wrong geometry on 8 of 26 workloads, including every parcel union. GEOS is
correct and close on speed, but has no supported browser build. Turf and JSTS
are correct almost everywhere and an order of magnitude slower.

## Getting started

```sh
zig build wasm     # freestanding + simd128, into zig-out/bin/ and js/
```

[`js/qdgeo.js`](js/qdgeo.js) is the binding, and `load()` takes no argument: it
defaults to the `qdgeo.wasm` beside it, resolved through `import.meta.url`, so
Vite, webpack and Node all find the module without being told where it is. A
shape is a list of rings, each a list of `[x, y]`, shell first and holes after:

```js
import { load } from 'qdgeo';
const geo = await load();

const square = (x, y, w) => [
  [
    [x, y],
    [x + w, y],
    [x + w, y + w],
    [x, y + w],
    [x, y],
  ],
];
const a = square(0, 0, 10);
const b = square(5, 5, 10);

geo.union([a, b]); // one shape, area 175
geo.intersection([a], [b]); // the overlap
geo.difference([a], [b]); // a with b cut out
geo.symmetricDifference([a], [b]);
geo.buffer([a], 2); // grown by 2; negative shrinks
geo.buffer([a], 2, { steps: 32 }); // finer arcs

geo.intersects([a], [b]); // true
geo.contains(
  [a],
  [
    [2, 2],
    [
      [1, 1],
      [3, 3],
    ],
  ],
); // a point and a line, both inside
geo.touches([a], [square(10, 0, 10)]); // true: they share an edge
geo.relate([a], [b]); // '212101212', the DE-9IM matrix
geo.relate([a], [b], 'T*T***T**'); // true: a pattern match
```

The binary operations take two operand lists, so either side can hold several
shapes; `union` and `buffer` are n-ary over one list.

The predicates — `intersects`, `disjoint`, `contains`, `within`, `covers`,
`coveredBy`, `touches`, `crosses`, `overlaps` and `equals`, with JTS's
definitions — take any geometry on either side. A list holds any mix, told
apart by nesting: `[x, y]` is a point, `[[x, y], …]` a line and
`[[[x, y], …], …]` a polygon; `{ points, lines, polygons }` names them
instead. Each list is read as **one** geometry, the union of its members, so a
point on an edge two polygons in the list share is inside the list, and
`intersects([a, b, c], [d, e, f])` asks whether the two unions meet.

Every predicate is **lazy**. Each one is a pattern over the DE-9IM matrix, the
pattern goes into the module, and the module stops building the matrix the
moment the pattern is decided: `contains` stops at the first point of `b`
outside `a`, `touches` at the first interior point in common. Disjoint extents
answer any of them from the dimensions alone, before a coordinate is read, and
`intersects` goes one step further — the first contact answers `true` inside
the sweep, before anything is located. `relate(a, b)` returns the full matrix
as the nine characters JTS prints; `relate(a, b, pattern)` matches a pattern of
`T`, `F`, `0`, `1`, `2` and `*` lazily too, plus `A` for a group of cells of
which one must be non-empty — the extension that makes `covers` or `touches`
one pattern rather than four. The named methods are those patterns, exported
as `PATTERN`.

**What comes out goes back in.** A result is a collection of shapes, so it is an
operand anywhere one is accepted, and operations chain without unpacking
anything:

```js
const grown = geo.buffer(geo.union(userShapes), { distance: 15 });
const trimmed = geo.difference(grown, boundary);
```

That is not a convenience wrapper. A result carries `coordinates`, `ringEnds`
and `polygonEnds`, and feeding it back appends one array and shifts two index
arrays — no coordinate is read on the way in or out.

```js
const result = geo.union([a, b]);
result.coordinates; // Float64Array, every x and y
result.ringEnds; // Uint32Array, exclusive ends in coordinates
result.polygonEnds; // Uint32Array, exclusive ends in rings
result.length; // how many polygons
result.toArrays(); // [[[x, y], ...], ...] when a host wants pairs
```

That is the layout OpenLayers keeps and deck.gl wants, which is why the
[examples](examples/) hand it to both without touching a coordinate.

The module needs no host functions and instantiates with an empty import
object, so calling it directly is reasonable too — `geo.apply(op, a, b, opts)`
is the generic form, and [Host ABI](#host-abi) describes the block layout and
the eight exports.

### Loading the module

`load()` also takes a URL or path, a `Response` (or a promise of one, so
`load(fetch(url))` works), raw bytes, or an already-compiled
`WebAssembly.Module` — the last for a strict CSP, or to instantiate the same
module more than once:

```js
await load(); // beside the binding, the default
await load('https://example.com/qdgeo.wasm'); // anywhere else
await load(new URL('./qdgeo.wasm', import.meta.url)); // what the default does
await load(await WebAssembly.compile(bytes)); // compiled already
```

In Node the `file:` case is read through `node:fs` rather than fetched, because
Node's `fetch` does not implement that scheme. The same call works in a browser,
a worker, a bundler and a test runner.

### The package

ESM only, `sideEffects: false`, types generated from the JSDoc by
`npm run types`. The same doc comments also produce the
**[API reference](https://theduckylittle.github.io/qdgeo/api/)**, published
beside the examples; `npm run docs` builds it locally into `docs/api/`. Four
entry points:

|                    |                                                          |
| ------------------ | -------------------------------------------------------- |
| `qdgeo`            | the binding                                              |
| `qdgeo/deck`       | deck.gl binary conversion                                |
| `qdgeo/leaflet`    | Leaflet's open rings, both directions                    |
| `qdgeo/qdgeo.wasm` | the module itself, for pointing a bundler straight at it |

The last is what makes a custom setup possible without guessing at paths:
`new URL('qdgeo/qdgeo.wasm', import.meta.url)` resolves through the `exports`
map, and a bundler fingerprints and emits it.

### Examples

Five pages in [`examples/`](examples/) — plain canvas, OpenLayers, deck.gl,
MapLibre GL JS and Leaflet — each running all four boolean operations and the
buffer with live controls, and each showing what that host wants geometry to
look like.
They are published from `main` at
**[theduckylittle.github.io/qdgeo](https://theduckylittle.github.io/qdgeo/)**.

To run them locally:

```sh
zig build wasm            # also writes js/qdgeo.wasm, which is what load() finds
npm run examples          # vite, on a URL it prints
```

They are a Vite project importing their dependencies from npm, including the
binding as `qdgeo`, so they read like code someone would write rather than like
a demo harness. See [examples/README.md](examples/README.md).

### Building everything else

```sh
zig build                                 # static library/module
zig build run                             # rounded rectangle example
zig build native -Doptimize=ReleaseSafe   # zig-out/lib/libqdgeo_native.so
```

### Testing

```sh
npm run check     # zig build test, twice, then every JavaScript suite
```

Zig and Node, about two seconds, nothing else to install. That covers the
geometry, the WASM artifact, the binding, both adapters and the JTS Topology
Suite. The differential suite against GEOS and four other engines is a separate,
opt-in process. [TESTING.md](TESTING.md) covers both.

## Design goals

**1. Speed.** WebAssembly and vector operations, to be meaningfully faster than
libraries like Turf rather than incidentally faster. On the full parcel dataset
union that is **24x Turf**, 24x JSTS, and 3.0x native GEOS.

**2. Small size.** Zig's standard library is minimal and pay-for-what-you-use,
and it emits C-compatible library formats. Every byte in the artifact is paid
for by every page that loads it.

**3. Tight scope.** Buffers and boolean operations are very nearly the whole of
what web GIS does with geometry. Anything else has to argue its way in.

**4. Correctness.** Operations are tested against GEOS and against the JTS
Topology Suite's own test cases. Where an optimisation and an answer conflict,
the answer wins.

The shipped WASM keeps its runtime safety checks. They are close to free:

|                         |      raw | gzipped | speed | output        |
| ----------------------- | -------: | ------: | ----: | ------------- |
| `ReleaseSafe` (shipped) | 173.9 KB | 66.5 KB | 1.00x | —             |
| `ReleaseFast`           | 171.0 KB | 62.0 KB | 1.09x | bit-identical |

`ReleaseFast` is 9% faster, 2.9 KB smaller raw and 4.5 KB smaller gzipped, and
produces byte-for-byte identical geometry across all 26 workloads. It ships
`ReleaseSafe` anyway, for the runtime safety checks — goal 4 — not for size.
`ReleaseSmall` reaches 97.3 KB raw and 43.3 KB gzipped if size ever matters more
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

Three runs because one is not reproducible enough to publish. Across the three,
engine geometric means moved by up to 18%, and individual cases by far more:
JSTS's `donut-buffer--1` spanned 0.27-1.2 ms and qdgeo's own `edge-point-contact`
0.015-0.066 ms. Sub-millisecond cases are dominated by scheduling and JIT warmup
rather than by geometry, and that reaches the WASM engines too, not only the
JavaScript ones. The large workloads are steady: the
4,040-parcel union held within 1% for qdgeo and 5% for every engine except GEOS,
which spanned 406-514 ms. Ratios are quoted to two significant figures because
the third is noise.

**A wrong answer is not a fast answer.** Where an engine returns the wrong
geometry its time is marked †, and it is excluded from every average. Rust Geo
fails all four parcel unions, which are its biggest wins.

Versions: GEOS 3.13.1 (Shapely 2.1.2), JSTS 2.12.1, Turf 7.4.0, polyclip-ts
0.16.8, Rust Geo 0.33.1. Reproduce with `npm run fetch-data && npm run compare`.

### Correctness

|             | workloads passed | worst vertex error | rings returned |
| ----------- | ---------------: | -----------------: | -------------: |
| **qdgeo**   |      **26 / 26** |            **0 m** |            444 |
| GEOS        |          26 / 26 |           7.2e-5 m |            445 |
| JSTS        |          24 / 26 |           1.4e-5 m |            447 |
| Turf        |          23 / 26 |           2.0e-4 m |            444 |
| polyclip-ts |          10 / 12 |           2.0e-4 m |            444 |
| Rust Geo    |          18 / 26 |             1961 m |        **382** |

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

| parcels | qdgeo wasm | qdgeo native | GEOS | Rust Geo |   JSTS |   Turf | polyclip-ts |
| ------: | ---------: | -----------: | ---: | -------: | -----: | -----: | ----------: |
|      10 |       0.18 |        0.095 | 0.25 |  0.061 † |     11 |    2.4 |         4.1 |
|     100 |        1.4 |          1.0 |  3.5 |   0.19 † |     34 |     19 |          20 |
|   1,000 |         16 |           14 |   54 |    2.5 † |  390 † |  380 † |       360 † |
|   4,040 |        120 |          110 |  370 |     13 † | 2900 † | 2900 † |      3000 † |

On the two largest unions, only qdgeo and GEOS return the right geometry.

### Buffer

| case                           | qdgeo wasm |  GEOS | Rust Geo | JSTS | Turf |
| ------------------------------ | ---------: | ----: | -------: | ---: | ---: |
| 1 parcel, +2 m                 |      0.035 | 0.041 |    0.029 | 0.34 | 0.87 |
| 100 parcels, +2 m              |        1.1 |   3.7 |     0.28 |   25 |   24 |
| 100 parcels, -10 m             |        1.2 |   4.7 |   0.39 † |   25 |   23 |
| 19,208-coordinate parcel, +2 m |         25 |   8.7 |       47 |   26 |   75 |
| 19,208-coordinate parcel, -2 m |         25 |    12 |       57 |   23 |   71 |

### Overall

Geometric mean against qdgeo in WASM, over each engine's **correct** workloads
only. Above 1.00 is slower than qdgeo.

|                |     speed | workloads averaged | excluded as wrong                                |
| -------------- | --------: | -----------------: | ------------------------------------------------ |
| Rust Geo       |     0.86x |                 18 | all 4 parcel unions, 2 eroding buffers, 2 others |
| **qdgeo wasm** | **1.00x** |                 26 | none                                             |
| GEOS native    |      1.8x |                 26 | none                                             |
| JSTS           |      7.3x |                 24 | 2 parcel unions                                  |
| Turf           |       19x |                 23 | 2 parcel unions, 1 buffer                        |
| polyclip-ts    |       26x |                 10 | 2 parcel unions                                  |

Across the three runs those means spanned 0.79-0.95, 1.2-1.9, 6.4-8.6, 14-20 and
22-29 respectively. Treat them as one significant figure of real information
each. Measured against the 1.0.0 artifact in the same process, interleaved,
qdgeo's own union and buffer are 5-12% faster than at 1.0.0 — the 4,040-parcel
union 139 ms against 124 ms; the rest of the movement from the previous tables
is machine state, which GEOS's column moved by too.

Timing boundaries are not equal across engines. qdgeo and Rust Geo are the only
matched pair: both WASM, same Node process, same flat ABI. GEOS is native and
receives live geometry objects, so it pays no parse or encode where qdgeo pays a
full WKB round trip. Turf's buffers include reprojection. Medians also move with
machine state, so treat a gap under 20% as unresolved.
[tests/compare/README.md](tests/compare/README.md) documents each boundary.

### Predicates

The differential suite does not cover predicates, so these come from a
separate benchmark on the same 4,040 parcels: the median of three runs, each a
median of seven. Every engine returned the same answer on every workload.
qdgeo and Rust Geo are the matched pair here too: both WASM, both starting from
nested JavaScript arrays and copying them into linear memory on every call.
JSTS and Turf start from geometry objects they already hold. GEOS is native,
measured in its own process, and its vectorized column is one C loop over all
4,040.

Milliseconds for the whole workload.

| workload                                  | qdgeo | Rust Geo | JSTS |  Turf | GEOS loop | GEOS vectorized |
| ----------------------------------------- | ----: | -------: | ---: | ----: | --------: | --------------: |
| `intersects`, disc vs each parcel × 4,040 |    17 |       10 |   18 |   280 |        16 |             0.9 |
| `contains`, parcel vs a point × 4,040     |    13 |       20 |   80 | 2.6 ‡ |        25 |             2.9 |
| `contains`, disc vs each parcel × 4,040   |    27 |       19 |  9.0 |   140 |        12 |             0.3 |
| `touches`, neighbour pairs × 1,000        |   4.4 |      4.2 |  4.5 |     — |       4.6 |               — |
| `relate`, neighbour pairs × 1,000         |    17 |      7.4 |   11 |     — |       4.0 |               — |
| `intersects`, rect vs all 4,040 as one    |   7.9 |      4.7 |  0.0 |     — |       0.0 |               — |
| `relate`, rect vs all 4,040 as one        |   360 |      490 |  ✗ § |     — |       1.6 |               — |

‡ Turf's `booleanPointInPolygon`, a point-only routine; its general
`booleanContains` is not tested against points here. § JSTS throws
`TopologyException: side location conflict`: adjacent parcels make the merged
MultiPolygon invalid under OGC rules, and JSTS's relate cannot label it. qdgeo
reads a list as a union and answers. Turf has no `relate` or `touches` on
polygons that runs on this data. Rust Geo goes through `rg_predicate` in
`tests/compare/rust`, built with `--features predicates`.

**On predicates qdgeo is not the fastest overall.** Against Rust Geo, the
matched pair, it is ahead on point-in-polygon and whole-dataset `relate`, level
on `touches`, and behind on the rest by 1.4-2.3x. A point against polygons,
lines or other points never builds an arrangement: it is located directly, so
point-in-polygon is 4.6x faster than it was and ahead of every engine but
Turf's point-only routine and vectorized GEOS. qdgeo is level with JSTS on
`intersects` and `touches`, 6x faster on point-in-polygon, behind on `contains`
of whole parcels and on `relate`, and 10-16x faster than Turf. Against one
geometry built from the whole dataset, JSTS and GEOS answer `intersects` in
microseconds through a rectangle fast path, and GEOS's `relate` through
RelateNG's indexes.

Bundled the way `npm run sizes` bundles, adding the predicates costs:

|          |  without | with predicates |    added |
| -------- | -------: | --------------: | -------: |
| qdgeo    |  50.5 KB |         66.5 KB | +16.0 KB |
| JSTS     |  73.9 KB |         75.8 KB |  +1.9 KB |
| Turf     |  81.9 KB |         95.8 KB | +13.9 KB |
| Rust Geo | 102.1 KB |        162.2 KB | +60.1 KB |

JSTS adds the least because `relate` reuses the geometry graph its overlay
already carries. Turf's is nine separate `@turf/boolean-*` packages. Rust Geo's
is its `Relate`, `Intersects` and `Contains` traits monomorphised for the two
operand pairs the shim asks about; it is the largest artifact here with or
without them.

## Invalid input

**qdgeo rejects invalid geometry. It does not repair it.**

A ring with zero area, fewer than four points, or a coordinate outside the
supported range returns an error code. Nothing is snapped, clamped, or collapsed
to make a call succeed.

JTS and GEOS choose differently. They buffer a degenerate polygon by falling
back to its linework, and when floating-point noding fails they retry on
progressively coarser snap-rounded grids before giving up.

|                  | qdgeo               | JTS / GEOS                |
| ---------------- | ------------------- | ------------------------- |
| Degenerate ring  | error               | buffers its linework      |
| Noding failure   | error               | retries on coarser grids  |
| Precision option | none                | fixed precision models    |
| When it answers  | the answer is exact | the answer may be snapped |

The "noding failure" row is not only about bad geometry — it is also the one
case where **valid** input can fail. See the next section.

That is why they answer where qdgeo errors. It is also why a snapped result
answers a slightly different question than the one you asked.

This choice costs qdgeo 3 of 158 JTS assertions, all degenerate rings, and it is
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
- It has its own code: ABI status `7`, distinct from status `5`'s malformed
  input, so a host can tell "fix your geometry" from "this arrangement cannot
  be represented" without checking anything itself. The binding throws a
  `QdgeoError` whose `code` is `'UNREPRESENTABLE'` rather than
  `'INVALID_GEOMETRY'`, and the Zig API says `error.UnnodableCrossing` rather
  than `error.NodingFailure`.
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

| workload                         | input coordinates | peak heap | KiB per coordinate |
| -------------------------------- | ----------------: | --------: | -----------------: |
| union, 10 parcels                |                80 |   1.5 MiB |               19.2 |
| union, 100 parcels               |               936 |   2.8 MiB |               3.08 |
| union, 1,000 parcels             |            17,231 |  11.6 MiB |               0.69 |
| union, 4,040 parcels             |           135,080 |  81.8 MiB |               0.62 |
| buffer, 19,208-coordinate parcel |            19,208 |  23.7 MiB |               1.26 |

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
  `tests/wasm.test.mjs` asserts both.

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
npm test -- tests/jts
```

| File                                               |    pass |  fail |   skip |
| -------------------------------------------------- | ------: | ----: | -----: |
| `TestOverlayAA.xml`                                |      40 |     0 |      4 |
| `TestNGOverlayA.xml`                               |      80 |     0 |      8 |
| `TestBuffer.xml`                                   |      35 |     3 |      3 |
| `TestPreparedPointPredicate.xml`                   |       3 |     0 |      0 |
| `TestPreparedPolygonPredicate.xml`                 |      57 |     0 |      0 |
| `TestPreparedPredicatesWithGeometryCollection.xml` |      11 |     0 |      0 |
| `TestRectanglePredicate.xml`                       |      70 |     0 |      0 |
| `TestRelateAA.xml`                                 |      41 |     0 |      0 |
| `TestRelateLA.xml`                                 |      13 |     0 |      0 |
| `TestRelateLL.xml`                                 |      46 |     0 |      0 |
| `TestRelatePA.xml`                                 |      77 |     0 |     44 |
| `TestRelatePL.xml`                                 |       8 |     0 |      0 |
| `TestRelatePP.xml`                                 |       4 |     0 |      0 |
| **Total**                                          | **485** | **3** | **59** |

**Every boolean operation assertion passes: 120 of 120**, across both JTS's
original overlay engine and OverlayNG, and **every predicate assertion
passes: 330 of 330** — every `relate` matrix character for character, and
every named predicate over polygons, lines, points and collections of them.
The 44 predicate skips are all one shape, `MULTIPOINT(EMPTY, (0 0))`, which
JSTS's `WKTReader` cannot parse; that is JTS's answer to the input, not
qdgeo's, and it is counted separately.

Twelve of the skips expect a Point, LineString, or GeometryCollection. qdgeo
returns polygons only, so they are out of scope and are counted separately
rather than scored as passes. The other three belong to one case,
`POLYGON ((0 0, 10 10, 0 0))`, that JTS's own `WKTReader` refuses to load at
all — three points is not a LinearRing. The 3 failures are degenerate rings —
see [Invalid input](#invalid-input). They are named individually and asserted
with `test.fails`, so an unexpected _pass_ is reported too.

The reference side of this suite is JSTS — JTS itself, ported to JavaScript —
rather than a second implementation of JTS's comparison rules. `BufferResultMatcher`'s
constants and `DiscreteHausdorffDistance` are JTS's own. Buffers run at
`quadrantSegments = 8`, which is JTS's default and what the expected geometry
was generated with. Buffer results use the tolerance comparison
`TestBuffer.xml` asks for by name; overlay results must be exactly equal.
[TESTING.md](TESTING.md) covers both.

## Host ABI

**One representation: flat coordinate blocks.** Conversion to and from a host's
own types belongs to the host, which knows them. Both integration targets
already speak this layout — OpenLayers stores `flatCoordinates` plus ring and
polygon ends, and Shapely's `to_ragged_array` returns coordinates plus the same
offsets — so for both it is a bulk copy rather than a serialiser.

    [ 2 * coordinates f64 ][ rings u32 ][ polygons u32 ][ line strings u32 ]

Every index is an exclusive end offset. Offsets count _coordinates_, not
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
- `geom_relate(pattern, points, line_strings, polygons) -> answer` — the
  predicates, over the same block. The three counts say how many of the
  block's leading points, line strings and polygons form the first operand;
  the rest are the second. `pattern` is a DE-9IM pattern packed three bits
  per cell in JTS's order, first cell lowest: `*` 0, `T` 1, `F` 2, `0` 3,
  `1` 4, `2` 5, and `A` 6 for a group of cells of which one must be non-empty.
  Nine stars pack to 0 and ask for the matrix itself, two bits per cell — 0
  for empty, else the dimension plus one. Any other pattern answers 0 or 1,
  evaluated lazily. The named predicates are patterns the binding carries;
  the module carries none, the way `Mode` carries the boolean operations
  behind one `geom_apply`. A negative answer is a status, negated. Nothing
  here produces a result block, so the previous result is left alone.

Status: 0 success, 1 allocation error where recoverable, 2 unsupported geometry,
3 count/point limit, 4 precision/range error, 5 malformed geometry or overlay
failure, 6 invalid options, 7 valid input whose arrangement `f64` cannot
represent.

Status `5` means the input was bad; status `7` means the input was valid and
the answer still could not be built — see
[When valid input fails](#when-valid-input-fails), which is rare but real. The
two want different responses, which is why they are different codes.

The numbers are the ABI's; a JavaScript caller never sees them. The binding
throws `QdgeoError`, whose `code` is a name — `'INVALID_GEOMETRY'`,
`'UNREPRESENTABLE'`, `'OUT_OF_MEMORY'` and so on — so a branch reads at the
call site, and the exported `STATUS` map translates for a host driving the raw
exports.

### WKB, native only

The browser is 90% of the target and is size-sensitive, so WKB is kept out of
the WASM build entirely. The coordinate block is the whole browser surface:
eight exports, no parser, no writer.

The native library keeps WKB, because that is how qdgeo reaches GeoParquet,
PostGIS, and the comparison suite. A Python module would link the same path.
These are conversion conveniences for a host that already holds WKB, which is
why they are the ones carrying a qualifier. The operation is a value here too,
so both ABIs have the same five:

- `geom_wkb_apply(op, ptr, len, subject, distance, steps) -> status` — the same
  five operations and the same argument list as `geom_apply`, after the two that
  say where the bytes are.
- `geom_wkb_result_ptr()`, `geom_wkb_result_len()`

Input bytes are borrowed for the duration of the call. Results go through
`geom_clear()` like any other. Eleven exports in total: eight for the
coordinate block, three for WKB. The predicates have no WKB entry point; a
native host has the Zig API.

### Host adapters, JavaScript only

Two hosts have a conversion that is easy to get wrong and silent when it is, so
the package ships them alongside the binding:

```js
import { toBinary, toOutline } from 'qdgeo/deck'; // deck.gl binary layers
import { toLeaflet, fromLeaflet, openRings } from 'qdgeo/leaflet'; // open rings
```

They are separate entry points, load no WASM, and depend on nothing — not even
on deck.gl or Leaflet, whose projection is passed in — so a bundler drops what
is not imported. `qdgeo/deck` exists because deck.gl's attribute is
`instanceVertexValid` and a bare `vertexValid` is ignored without complaint;
`qdgeo/leaflet` because Leaflet's rings must be open where qdgeo's are closed.
Both are covered by `tests/deck.test.mjs` and `tests/leaflet.test.mjs`.

Nothing else gets an adapter. OpenLayers already speaks the flat layout, and
MapLibre needs only the binding's own `toArrays()`. The deck.gl and Leaflet
demos in `examples/` import these rather than carrying a copy, so the pages run
the code the tests cover.

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
both specs call a _Point_ a geometry, not a coordinate. `LinearRing` and
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
- `relate(allocator, Collection, Collection, RelateOptions) !Matrix` is the
  full DE-9IM matrix for one collection against another, with union semantics
  over each collection; `Matrix.string()` is its nine characters.
  `matches(allocator, a, b, "T*F**F***", options) !bool` evaluates a pattern
  lazily — the arrangement is walked only until the pattern is decided — and
  `predicate(allocator, a, b, .contains, options) !bool` does the same for a
  named predicate, whose pattern `Predicate.pattern(dims)` gives.
  `intersects(allocator, a, b, options) !bool` is the path with the exit
  inside the sweep.
- `buffer(allocator, BufferInput, distance, BufferOptions) !Geometry` is the
  only buffer entry point. It takes polygons, lines, and points together — a
  point buffers to a disc, a line to a stadium, and neither survives a negative
  distance — so the common case reads `buffer(a, .{ .polygons = shapes }, 2,
.{})`. Areal input is unioned first. Holes, splitting, and collapse are all
  supported. Zero distance runs union and normalisation, not a byte-identical
  copy.

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

**`ci.yml`** runs on every push and pull request: the Zig tests in Debug and
ReleaseSafe, all four build targets, `npm test` — the WASM runtime checks, the
binding, both adapters and the JTS Topology Suite — the examples build, the
generated declaration types and API reference, the package manifest, Prettier
and `zig fmt`. It
needs Zig and Node and nothing else, and it prints the artifact size to the run
summary, so a change that inflates the download is visible in the pull request.

The JTS suite has no count-based gate. The three [invalid input](#invalid-input)
failures are named in `POLICY_FAILURES` and asserted with `test.fails`, so a
regression and an unexpected fix both name the case rather than moving a
number.

**`pages.yml`** rebuilds the WASM module, assembles `examples/` into a site with
the fresh module, generates the API reference into `/api/`, checks every page is
present, and deploys to GitHub Pages. Enable it once under
**Settings → Pages → Source → GitHub Actions**.

The differential comparison suite is not in CI. It needs GEOS, the parcel
dataset and several npm engines — and optionally a Rust toolchain for the
rust-geo shim — and it measures timings, which a shared runner cannot do
meaningfully. Run it locally with `npm run compare`; [TESTING.md](TESTING.md)
lists what it needs and what is optional.

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
