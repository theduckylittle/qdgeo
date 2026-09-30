# Changelog

Notable changes to qdgeo, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/), and versions follow
[semver](https://semver.org/): after 1.0.0, the ABI exports, the status codes,
the binding's API and the package's entry points only change with a major
version.

## 1.0.0 — unreleased

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
