# Changelog

Notable changes to qdgeo, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versions follow
[semver](https://semver.org/): after 1.0.0, the ABI exports, the status codes,
the binding's API and the package's entry points only change with a major
version.

## 1.2.0 — 2026-10-07

- `makeValid`: repairs invalid polygons, on request, with JTS's
  `GeometryFixer` rules. A ring covers everything it winds around in either
  direction, so a bowtie keeps both lobes and a loop that re-covers the shape
  leaves no hole; each ring is repaired alone; a hole is cut where it meets the
  shell and kept as a polygon where it does not; a collection's repaired
  polygons are unioned. Open rings are closed, `NaN` vertices removed, repeated
  ones merged, and parts with no area dropped. Exact, with no snapping. Op code
  5 through the existing `geom_apply`, so no new export; `geo.makeValid` in the
  binding and `makeValid` in Zig. Against Shapely's
  `make_valid(method='structure')` on 20,000 fuzzed hand-drawn polygons, 19,977
  agree and 21 are `UNREPRESENTABLE`; valid input comes back unchanged.
- **Fixed: four overlay defects that returned wrong geometry as if it were
  right**, in every release before this one, on valid input. None showed on
  the parcel data; all four on edited-style geometry, where vertices sit a few
  ulps off other edges. On 30,000 fuzzed union, intersection and difference
  calls, adjudicated in exact arithmetic, 1.1.0 is wrong 24 times — 5 of them
  invalid output — and 1.2.0 once.
  - `orient` judged two points collinear with a third whenever their rounded
    differences from it matched, so points an ulp apart far from it were
    "collinear", and ring assembly dropped the ring. A difference of two
    triangles came back empty instead of 22.2.
  - The sweep tested the wrong pair across the gap closings leave when an
    opening below shifted the status line, leaving crossings unnoded: a union
    of three valid triangles came back self-intersecting, area 1077 for 1047.
  - Cached windings went stale when a segment was split at the point just
    swept, or when two openings left the event queue out of order: an
    intersection came back as the whole first operand.
  - Splitting a segment rotates it by a rounding step, which can make a
    crossing behind the sweep line; and a crossing lost to rounding could
    leave two operands' edges in the wrong order. Both assembled wrong answers.
    Boolean results are now checked for crossing edges, lost crossings between
    operands are checked for consequence, and the graph labelling is never
    used on an arrangement with a lost crossing. Each declines to the
    re-noding pass, or to `UNREPRESENTABLE`.
- The one case left, measured and documented: a vertex within half an ulp of
  another polygon's edge in the **same** operand can still leave a union valid
  but wrong — once in 30,000 fuzzed calls.
- Speed: unions are 3-5% slower than 1.1.0 and buffers 1-4%, measured
  interleaved in one process, mostly the result check. The artifact is 182.3 KB
  raw and 69.5 KB gzipped, up 8.4 KB and 3.0 KB.
- `tests/compare/fuzz.py`: the edited-geometry fuzz, with an exact referee and
  recorded baselines, now part of the correctness sweep.
- The README's "Invalid input" section now says what the operations check —
  structure — and what they do not — topology, read by winding as JSTS's
  `buffer(0)` reads it.
## 1.1.0 — 2026-10-05

- The spatial predicates: `intersects`, `disjoint`, `contains`, `within`,
  `covers`, `coveredBy`, `touches`, `crosses`, `overlaps` and `equals`, and the
  DE-9IM `relate` matrix they are read from, with JTS's definitions, over any
  mix of points, lines and polygons. Each operand is read as the union of its
  members. Every predicate is lazy: it is a pattern over the matrix, and the
  module stops building the matrix once the pattern is decided. Disjoint
  extents answer from the dimensions alone; `intersects` answers at the first
  contact, inside the sweep.
- One new export, `geom_relate(pattern, points, line_strings, polygons)`: a
  DE-9IM pattern packed three bits per cell, zero for the matrix itself, and
  three counts on the block's operand split, one per kind. The artifact grows
  to 173.9 KB raw, 66.5 KB gzipped.
- Operand lists may mix geometries, told apart by nesting: `[x, y]`,
  `[[x, y], …]`, `[[[x, y], …], …]`.
- A predicates demo page, `predicates.html`: polygons, lines and points dragged
  on a canvas, with all ten predicates and the DE-9IM matrix updating live.
- The ten JTS predicate case files, run verbatim: 330 of 330 assertions pass.
- Fixed before release: `relate` trapped on a probe far outside the other
  operand's polygons (a long line reaching a distant polygon), and `crosses`,
  `touches` and `overlaps` counted `POLYGON EMPTY` toward an operand's
  dimension. Both were duplicated logic, and both have regression tests.
- A point against polygons, lines or points is located directly, with no
  arrangement: point-in-polygon is 2-13x faster per call, and a point on a
  line is answered by an exact `orient` test and the mod-2 endpoint rule.
- Union and buffer are 5-12% faster: `Extent` uses compare-and-select instead
  of `fmin`/`fmax` library calls, and the binding writes into one cached view
  of linear memory with indexed loops.

## 1.0.0 — 2026-10-01

First release.

- Five operations — union, intersection, difference, symmetric difference, and
  rounded buffer — over polygons, lines and points, with the buffer composable
  onto any boolean result in a single call.
- One WASM artifact (133.5 KB raw, 50.5 KB gzipped, `ReleaseSafe`, no imports)
  and a JavaScript binding: `load()`, one method per operation, and results
  as flat coordinate arrays that chain back in as operands.
- Host adapters as separate entry points: `qdgeo/deck` (deck.gl binary layers)
  and `qdgeo/leaflet` (open rings, both directions).
- Failures throw `QdgeoError` carrying a named `code` — `'INVALID_GEOMETRY'`,
  `'UNREPRESENTABLE'`, `'OUT_OF_MEMORY'`, … — with `'UNREPRESENTABLE'` (ABI
  status `7`) distinguishing "valid input whose arrangement f64 cannot
  represent" from `'INVALID_GEOMETRY'` (status `5`).
- TypeScript declarations generated from the JSDoc, and the
  [API reference](https://theduckylittle.github.io/qdgeo/api/) published with
  the [examples](https://theduckylittle.github.io/qdgeo/).
- Correctness: 26 of 26 differential workloads against GEOS, 155 of 158
  applicable JTS Topology Suite assertions, and 0 failures across 57,990
  parcel-cluster buffers. Invalid input is rejected, never repaired; the README
  documents the one case where valid input errors.
