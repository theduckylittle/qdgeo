# Parcel correctness and performance comparison

This suite exists to **review**, not endorse, the library. Known failures are
retained and reported, and nothing is suppressed to make a number look better.
Don't read the native Zig unit tests as a substitute for it.

## Reproduce

From the repository root, using Zig 0.16.0, Node 22+, Python 3.13 and Rust 1.88+:

```sh
python3 -m venv .venv
.venv/bin/pip install -r tests/compare/requirements.txt
npm ci --ignore-scripts
cargo build --release --locked --target wasm32-unknown-unknown --manifest-path tests/compare/rust/Cargo.toml
zig build native -Doptimize=ReleaseSafe
zig build wasm
node tests/wasm.mjs
.venv/bin/python tests/compare/run.py --repeats 5
.venv/bin/python tests/compare/probes.py
```

Default input: `~/Projects/geomoose/gm3/examples/desktop/parcels.geoparquet`.
Override with `--source PATH`. Only geometry is read/exported: no owner names,
addresses or tax attributes. GeoParquet CRS metadata is honored (omitted CRS means
OGC:CRS84). Null/empty/invalid/nonpolygonal inputs cause preparation to fail, not
silent skipping or repair. Adjacent repeated vertices are retained.

`generated/fixtures.json` records source SHA-256, source row ids, CRS, projection,
normalized geometry, grid, buffer resolution, and input sizes. `generated/report.json`
contains validity, area, symmetric-difference area, boundary Hausdorff, component/
hole/vertex counts, raw timings, medians, empirical p95 and engine versions.
`generated/report.md` is a readable table. Everything under `generated/` is
ignored by git and rebuilt by a run; there is no committed snapshot.

`--strict` exits nonzero on any invalid output, engine error, or comparison outside
the configured envelope, including intentionally out-of-domain probes. The default
mode completes the diagnostic report even when tests fail. `--reuse-external`
is only for report development: it reuses stale JS/Rust runs and must not be used
for publishable timings. It is marked in the report.

## Workloads

- Spatially clustered unions of 10, 100, 1,000 and all 4,040 parcels.
- Signed buffers at ±2 m and ±10 m of 1 and 100 parcels (union, then buffer).
- ±2 m buffer of the most complex parcel: source row 4013, 19,208 coordinates.
- Sloped overlaps, edge/point contacts, holes/nested islands, collapse and erosion
  that splits a narrow neck.
- Sub-grid slivers, nearly coincident boundaries, large coordinate origins and
  range-limit probes. These expose numerical policy, not just crashes.
- A reduced **three-parcel, 49-coordinate** invalid-union regression, committed as
  `fixtures/parcel-invalid-union.json`, source rows 1582, 239, 1687. Coordinates are
  already in the recorded local projection. The default source checksum and
  projection are in the review snapshot. `probes.py` runs this without needing
  the original GeoParquet and compares grid sizes and input batches.

## Comparison policy

All planar engines see identical local spherical AEQD coordinates in metres,
centered on the dataset bounding box; radius 6,371,008.8 m matches Turf. This avoids
comparing degree distances to metres or introducing spherical/ellipsoidal scale
bias. It is a benchmark CRS, **not a prescribed cadastral CRS**. Input winding is
normalized consistently outside timings; the Zig adapter normalizes again internally.

rust-geo is compared **as WASM, in the same Node host, through the same flat
coordinate block**, because comparing this library's WASM against a native Rust
binary measures the toolchain as much as the algorithm. `tests/compare/rust/src/lib.rs`
is that shim; the native binary in `main.rs` is kept only for spot checks.

Turf union uses `polyclip-ts`; they are not independent correctness oracles. Turf
buffers use JSTS, and require geographic coordinates. Its timed buffer path unions
in the common planar CRS, inverse-projects to lon/lat, runs Turf's own local AEQD
buffer, and projects back. Residual projection differences remain; outputs are not
expected to have byte-identical arc vertices. polyclip-ts itself has no buffer API.
A lone union input is duplicated for Turf's two-feature requirement.

GEOS/Shapely is the reference, not an infallible exact-arithmetic oracle, and on
this dataset it demonstrably is not one for *position*. Two measured effects:

- On nearly parallel parcel edges its f64 line intersector misplaces a vertex by
  up to `1.2e-4 m`. Reconstructed with rational arithmetic from the two input
  edges, the exact meeting point is known, and the reference is the side that is
  wrong.
- Its 4,040-parcel union contains 127 **filament rings** — one is four
  coordinates, 1591 m round, and 1.5 mm² in area. They carry no area, so
  symmetric difference cannot see them, but they move a boundary Hausdorff by
  hundreds of metres.

So the boundary metric adjudicates rather than assumes:

1. Rings thinner than the positional tolerance along their whole length (area
   under half their perimeter times that tolerance) are compared out, **on both
   sides**, and counted per engine as `filaments` and `reference_filaments`, so
   neither can hide one.
2. If the Hausdorff still exceeds the envelope, every vertex one side has and the
   other does not is reconstructed as the exact intersection of the two input
   edges through it, using `fractions.Fraction`. The result records
   `exact_error` and `reference_exact_error`. An engine passes the positional
   check only if its own vertices are at least as accurate as the reference's,
   and only if the area check already passed.

This is symmetric and it discriminates: it clears engines whose disputed vertices
are exact and still fails Rust Geo, whose are out by up to 1.9 km, and
polyclip-ts and Turf where they are less accurate than GEOS.

Every output is independently checked with `is_valid`; invalid outputs are not
repaired before comparison. All planar buffers request 16 segments/quadrant.
Arc phase and rounding still differ between implementations.

Union positional envelope is `max(4*grid, 1e-7)` metres. Buffer envelope adds twice
the arc sagitta and 20 micrometres for reprojection. Area envelope is reference
perimeter times that positional envelope, at least 1e-6 m². These are explicit
**test tolerances, not proven error bounds or parcel acceptance criteria**.
Hausdorff is measured on complete boundaries for outputs up to 5,000 coordinates;
otherwise it is explicitly null (quadratic cost). Topology counts are diagnostic.

Tiny holes/cracks make boundary Hausdorff discontinuous: losing a nearly zero-width
hole can give a large Hausdorff distance and near-zero symmetric-difference area.
A flag on polyclip-ts's full union therefore does **not** prove a 209 m exterior
boundary displacement. GEOS and polyclip differ by one effectively zero-area hole.
Negative buffering can amplify such differences into substantial strips of area.
A domain-specific precision/topology policy must precede engine selection.

## Timing boundaries and limitations

One warmup, then the requested number of repetitions, serial execution. Module
loading, compilation, GeoParquet decoding, fixture JSON parsing, input WKB creation,
GEOS validation/differencing and result-file serialization are **not timed**.

Boundaries are **not** the same for every engine, and the differences are large
enough to change conclusions. Read a row with them in mind:

- **Zig WASM and Rust Geo** are symmetric, and are the only pair that is. Both
  go through this library's flat ABI in the same Node host: allocate the input
  block, copy coordinates and ends into linear memory, execute, read the result
  back out and copy it. `tests/compare/rust/src/lib.rs` puts rust-geo behind that
  ABI precisely so the comparison measures the algorithm and not the toolchain.
- **Zig native**: WKB parse → overlay → WKB encode → copy to host → release.
  Native borrows Python's existing input bytes. End-to-end API timings.
- **GEOS** gets the most favourable boundary of any engine: `shapely.union_all`
  over geometries that are *already* GEOS objects, so it pays no parse and no
  encode. A GEOS row is operation-only; every Zig row is operation plus codec.
- **polyclip-ts and Turf**: prepared geometry → operation → geometry. Turf
  buffers include the projection work described above.
- Rust Geo buffers include the union. Its default multithreading is off
  (`default = []`), so no row here is threaded.

Medians also move with machine state between runs — GEOS measured 417 ms and
356 ms for the same workload an hour apart. Treat a difference under ~20% as
unresolved unless both were measured in the same process and window.

These are useful application-level comparisons, **not equal kernel microbenchmarks**.
Rust Geo and this library are the one symmetric pair — both compiled to WASM and
timed in the same host through the same ABI. GEOS is native and pays no codec,
so its column flatters it. No cold-start, peak-RSS or cross-browser benchmark is
claimed.
Five repeats give only a rough p95 (the maximum here), not a reliable latency tail.
WASM memory reports retained linear-memory capacity, not per-case peak/live memory.
Run more repetitions on representative devices after choosing correctness policy.
