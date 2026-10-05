# Changelog

Notable changes to qdgeo, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versions follow
[semver](https://semver.org/): after 1.0.0, the ABI exports, the status codes,
the binding's API and the package's entry points only change with a major
version.

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
