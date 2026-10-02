# CLAUDE.md

Guidance for working in this repository. This file holds what applies
everywhere; the deep context lives next to the code it describes:

| File | Covers |
| --- | --- |
| `src/CLAUDE.md` | The overlay engine, the buffer, the geometry invariants, the host ABI |
| `js/CLAUDE.md` | The binding, the adapters, the generated types and API reference, the npm package |
| `tests/CLAUDE.md` | The two test processes and the rules for each suite |
| `examples/CLAUDE.md` | The demo pages and the site they publish to |

## What this is

**qdgeo** — "Quick & Dirty Geographic Library". A narrow, allocator-explicit 2D
geometry library in **Zig 0.16.0**: the four boolean operations and rounded
signed buffer, over one degenerate-tolerant planar overlay, and the DE-9IM
predicates over the same exact arithmetic. The deployment target
is **WASM**; the native shared library exists so the differential harness can
call it, and so a Python module has something to link. It ships to npm as an
ESM package — the binding `js/qdgeo.js`, two host adapters, the WASM artifact
and generated declaration types.

Four goals, in the order they break ties:

1. **Speed** — WASM and vector operations, meaningfully faster than Turf.
2. **Small size** — Zig for its minimal, pay-for-what-you-use standard library
   and its C-compatible output. The shipped WASM is **`ReleaseSafe`**, not
   `ReleaseFast`, for its runtime safety checks — goal 4. That is a decision
   about safety, not size: measured with the predicates in, `ReleaseFast` is
   1.09x faster, 2.9 KB smaller raw and 4.5 KB smaller gzipped, and produces
   bit-identical geometry on all 26 workloads. Build it with
   `-Dwasm-optimize=ReleaseFast` to re-measure.
3. **Tight scope** — buffer and booleans are nearly all of web GIS geometry.
   New functionality is scrutinised hard; see the one-representation and
   browser-surface rules in `src/CLAUDE.md`.
4. **Correctness** — tested against GEOS *and* the JTS test suite. An
   optimisation that costs an answer is not an optimisation.

Read `TODO.md` before claiming status — it holds the current verified numbers
and the ordered list of what is still open ahead of a stable release.

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
zig build run                              # rounded rectangle demo
zig build native -Doptimize=ReleaseSafe    # zig-out/lib/libqdgeo_native.so
zig build wasm                             # freestanding, import-free, stripped

# Correctness. Zig + Node, nothing else, about two seconds.
npm run check                              # zig build test x2, then every JS suite
zig build test                             # 34 native tests
zig build test -Doptimize=ReleaseSafe
npm test                                   # vitest: ABI, binding, adapters, JTS
npm test -- tests/jts                      # one file or directory
npm run test:watch                         # vitest, re-running on save

# Comparison. Local and opt-in; needs GEOS, the dataset, optionally Rust.
npm run fetch-data                         # parcels.geoparquet for the compare suite
npm run compare                            # differential suite (see the `compare` skill)
npm run sizes                              # bundle sizes for every engine
.venv/bin/python tests/compare/probes.py   # precision probes

# Generated from the JSDoc on the binding and adapters.
npm run types                              # declaration types into types/
npm run docs                               # TypeDoc API reference into docs/api/

npm run format:check                       # Prettier, JS and HTML
```

`TESTING.md` is the full account of both test processes. Comparison-harness
setup (venv, `npm ci`, the optional `cargo build --release`) is in
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
| `src/relate.zig` | The predicates: `intersects` with its early exits, and the DE-9IM `relate` matrix every other one is read from |
| `src/abi.zig` | The host ABI — the whole browser surface, and the wasm root |
| `src/abi_wkb.zig` | The WKB ABI, linked into the native library only |
| `src/native.zig` | Root of the native library: both halves |
| `src/tests.zig` | All native tests |
| `js/` | The npm package: binding, adapters, platform shims |
| `types/` | Declaration types, generated from the JSDoc (gitignored) |
| `docs/api/` | TypeDoc API reference, generated from the JSDoc (gitignored) |
| `examples/` | Five demo pages; also the GitHub Pages site |
| `tests/` | vitest suites, the JTS cases, the differential suite |
| `docs/BUFFER_APPROACH.md` | Why the buffer is built the way it is, and the JTS/GEOS comparison |

## Conventions

- **Documentation aims at a 10th grade reading level**, in a professional but
  casual voice — the way you would explain something to a colleague who knows
  the field but not this codebase. Short sentences beat long ones, plain words
  beat formal ones, and what a thing does comes before why it is built that way.
  This applies to every `.md` file here, not just the README.
- **Names follow GeoJSON and OpenLayers.** A `Coordinate` is the x/y pair —
  *Point* means a geometry in both specs, so it is never the pair here. Rings are
  `LinearRing`, open chains are `LineString`, bounds are `Extent`, and a
  `Geometry` holds `polygons` / `line_strings` / `points`. Reach for the spec's
  word before inventing one.
- **Every source file carries an SPDX header.** Two lines, `SPDX-License-Identifier: MIT`
  and the copyright, above everything else — above a Zig `//!` module doc, below
  a `<!doctype>` or a shebang. New files get one. There is no third-party code
  in the tree; if any is ever vendored, it keeps its own licence and gets no
  header from us.
- **JavaScript and HTML are Prettier-formatted.** `npm run format`, checked with
  `npm run format:check`; config in `.prettierrc.json`. Committed JSON under
  `tests/compare/fixtures/` and `docs/` is data, not source, and is ignored,
  along with everything generated (`types/`, `docs/api/`).
- **Measure, then decide.** Every performance and size claim in these files was
  measured, and several "obvious" wins are recorded in `TODO.md` under "What
  was tried and did not pay" precisely so they are not tried twice. A change
  argued from a benchmark needs the benchmark in the commit message or the
  docs.
- **Invalid input is rejected, not repaired**, and failures are errors — the
  product decision behind the whole library. The full statement and its costs
  are in `src/CLAUDE.md`; the README's "Invalid input" section is the public
  version. Do not add a fixer, a tolerance, or a snap anywhere.

## Releasing

The package publishes to npm from a clean checkout: `prepack` rebuilds the WASM
artifact and regenerates `types/`, and CI's "Package manifest" step proves
every `exports` target is in the tarball. The version in `package.json` is the
single version of record. Before tagging a release: `npm run check`, the
cluster corpora via the `correctness` skill (expect 0 buffer / 4 union
failures), `npm run compare` if any engine or number changed, and a read
through `TODO.md`'s open items for anything that would change the public
surface — an ABI status code or an export added after 1.0 is a compatibility
promise, not a tweak.

## Traps

- The WASM build must stay import-free. Anything reaching for stderr — including
  `std.debug.print` — drags `std.posix` into `wasm32-freestanding` and fails on
  `IOV_MAX`. Guard any diagnostic behind a comptime target check, the way
  `operations.zig` does; `tests/wasm.test.mjs` asserts the import list is empty.
- **`zig build test` passing does not mean the parcel suite passes**, and
  neither implies the JTS suite. See `TESTING.md` and `tests/CLAUDE.md` — the
  suites answer different questions. All currently green: 34 native tests, 26 of
  26 differential workloads native and WASM, 155 of 158 applicable JTS overlay
  and buffer assertions, and 330 of 330 JTS predicate assertions.
- **The boundary metric adjudicates against exact arithmetic** (details in
  `tests/CLAUDE.md`), because GEOS is not a positional oracle on this data — it
  misplaces nearly parallel intersections by up to `1e-4 m` and emits filament
  rings. Never "fix" a Hausdorff failure by widening a tolerance; reconstruct
  the vertex with `fractions.Fraction` and find out which side is wrong.
  `tests/compare/README.md` has the method.
- Every reduced failure is committed under `tests/compare/fixtures/` and probed
  by `tests/compare/probes.py`. All five now pass.
