# tests/CLAUDE.md

Context for the test suites. The root `CLAUDE.md` covers the library and
[`TESTING.md`](../TESTING.md) covers how to run things; this file covers the
handful of decisions that are easy to get wrong from inside `tests/`.

Two processes, and conflating them is the recurring mistake:

| | Answers | Tools | Run |
| --- | --- | --- | --- |
| Correctness | Is it right? | Zig, Node | `npm run check` |
| Comparison | Is it fast, and how does it compare? | + Python/GEOS, Rust, parcel data | `npm run compare` |

**No suite substitutes for another.** `zig build test` passing says nothing
about the JTS suite, and the JTS suite says nothing about the parcel data.
Quote the number from the suite that measured it.

## The correctness suites — `npm test`

vitest over `tests/**/*.test.mjs`. One process per file (`pool: 'forks'`),
because the ABI keeps module-level state and `wasm.test.mjs` deliberately
exhausts the 512 MiB heap.

`pretest` runs `zig build wasm`, so the artifact under test is never stale and
there is no setup step to forget.

- **`wasm.test.mjs`** drives the raw exports; **`binding.test.mjs`** drives
  `js/qdgeo.js`. They are separate on purpose: a rename in the ABI should break
  one of them loudly rather than both vaguely.
- **`deck.test.mjs`** and **`leaflet.test.mjs`** need the examples'
  dependencies (`npm --prefix examples ci`) to run the real libraries over the
  output. Without them they skip; under `CI` they throw instead, because a
  structural-only pass is exactly what those two files exist to catch.

## `tests/jts/` — the JTS Topology Suite's own cases

The XML in `cases/` is copied **verbatim** from JTS (`cases/NOTICE.md`,
EDL-1.0). Never hand-edit a case to make it pass — if a case is genuinely out
of scope it belongs in a `test.skip` with a reason, where it is counted and
printed separately.

The reference side is **JSTS**: JTS itself, ported to JavaScript. That is what
makes the matcher constants JTS's own rather than a reimplementation of them,
and it is what let this suite drop Python and Shapely entirely.

Four load-bearing, non-obvious rules — `TESTING.md` explains each in full:

- Buffers run at `quadrantSegments = 8` (JTS's default). Finer is not closer.
- Buffer uses `BufferResultMatcher`'s tolerances; overlay must be exactly
  topologically equal.
- Non-areal expected results are skipped, not passed.
- The three invalid-input failures are named in `POLICY_FAILURES` and asserted
  with `test.fails`. There is no `--expect N` gate any more: a count cannot tell
  you *which* case changed, and an unexpected pass now reports itself.

`cases.mjs` reads the XML directly. JTS's format is four element names deep with
no entities, no CDATA and no namespaces, which is small enough not to justify a
dependency — and a dependency is what the Python runner really was.

## `tests/compare/` — the differential suite

GEOS is the reference, **not an oracle**. On this data it misplaces nearly
parallel intersections by up to `1e-4 m` and emits filament rings, so the
harness *adjudicates* rather than assumes: filaments are compared out on both
sides, and a boundary Hausdorff exceedance is resolved by reconstructing the
disputed vertex with `fractions.Fraction` and failing whichever side is actually
wrong. It is symmetric, and it still fails Rust Geo, JSTS, polyclip-ts and Turf
where they are less accurate than GEOS.

**Never widen a tolerance to clear a Hausdorff failure.** Reconstruct the vertex
and find out who is wrong. `tests/compare/README.md` has the method.

This is the one place Python belongs, and it is not glue: Shapely *is* GEOS, and
GEOS is the independent second opinion the whole suite is built on. Replacing it
with Zig would be qdgeo checking qdgeo.

Rust is **optional**. `rust/` builds only the rust-geo comparison shim; without
`cargo build` that engine drops out of the run and everything else is still
measured.

Timing boundaries are **not** equal across engines, and the differences are big
enough to change conclusions — qdgeo and Rust Geo are the only symmetric pair.
`tests/compare/README.md` documents each one; read it before quoting a ratio.

Every reduced failure is committed under `fixtures/` and re-probed by
`probes.py`. Everything under `generated/` is gitignored build output.

## Updating the published comparison

Use the **`compare` skill** (`.claude/skills/compare/`). It encodes the two
rules that are easy to get wrong: speed is averaged only over each engine's
*correct* workloads, and a report must never be read without checking the run's
exit code — a crashed run leaves the previous one in place and the stale numbers
look entirely normal.

## What CI gates

`.github/workflows/ci.yml` runs the Zig tests in Debug and ReleaseSafe, all four
build targets, `npm test`, the examples build, the declaration types, the
package manifest, Prettier and `zig fmt` on every push. Zig and Node; no Python
step, no Rust step.

The differential suite is deliberately **not** in CI: it needs GEOS, the parcel
dataset and several npm engines, and its timings are meaningless on a shared
runner. Run `npm run compare` locally before claiming a performance change.

## Adding tests

- A geometry bug gets a case in `src/tests.zig` *and*, if JTS covers the shape,
  a check that the relevant JTS case passes.
- A parcel-data failure gets reduced and committed under
  `tests/compare/fixtures/`, then probed.
- Test data is data, not source: `fixtures/` and `generated/` are outside the
  Prettier and SPDX-header rules. Runners and harness code are source and follow
  both.
