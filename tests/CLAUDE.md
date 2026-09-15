# tests/CLAUDE.md

Context for the test suites. The root `CLAUDE.md` covers the library; this file
covers how it is checked, because the three suites answer three different
questions and it is easy to quote one as though it answered another.

| Suite | Question it answers | Run |
| --- | --- | --- |
| `src/tests.zig` | Does the code do what we intended? | `zig build test` |
| `tests/jts/` | Does it match the reference implementation's own tests? | `npm run test:jts` |
| `tests/compare/` | Is it right and fast on real parcel data, against live engines? | `npm run compare` |
| `tests/wasm.mjs` | Does the browser artifact load and run with no host? | `npm run test:wasm` |

**None of them substitutes for another.** `zig build test` passing says nothing
about the parcel suite. Quote the number from the suite that measured it.

## `tests/jts/` — the JTS Topology Suite's own cases

The XML in `cases/` is copied **verbatim** from JTS (see `cases/NOTICE.md`,
EDL-1.0). That is the point: "passes the JTS suite" has to mean the actual
suite. Never hand-edit a case to make it pass — if a case is genuinely out of
scope, it belongs in the skip path with a reason, where it is counted and
printed separately.

Three rules in `run.py` are load-bearing and non-obvious:

- **Buffers run at `quadrantSegments = 8`.** That is JTS's default and therefore
  what the expected geometry in `TestBuffer.xml` was generated with. At qdgeo's
  own default of 16 the arcs are *finer* than JTS's, and the resulting area
  difference alone exceeds the matcher's tolerance. Finer is not closer here.
- **Buffer uses a tolerance matcher, overlay does not.** `TestBuffer.xml` names
  `BufferResultMatcher` in its own `<resultMatcher>` element, because a rounded
  buffer is an approximation whose vertices are implementation-specific.
  `run.py` applies the same two tests that class applies, with JTS's constants:
  symmetric-difference area relative to the larger input (`1e-3`), and boundary
  Hausdorff scaled by the distance (`distance / 100`, floored at `1e-8`).
  Overlay is exact, so overlay results must be *topologically equal*, full stop.
- **Non-areal expected results are skipped, not passed.** qdgeo returns polygons
  only, by design. An overlay whose expected answer is a Point, LineString or
  GeometryCollection is out of scope, and counting it as a pass would inflate
  the number that gets quoted.

Out of the wider JTS suite, only three files are in scope: area-area overlay,
OverlayNG area, and buffer. `cases/NOTICE.md` records why the rest are not —
mostly fixed precision models, which qdgeo rejects outright, and operations it
does not have.

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

`.github/workflows/ci.yml` runs the Zig tests, all four build targets, the WASM
runtime checks, Prettier, `zig fmt`, and the JTS suite on every push.

The JTS step uses `--expect 155`, not `--strict`. Six failures are the
documented invalid-input policy, so `--strict` would always fail. If you make a
JTS case pass, raise the number in the workflow in the same commit — that is
what keeps the baseline honest.

The differential suite is deliberately **not** in CI: it needs Rust, GEOS, the
parcel dataset and several npm engines, and its timings are meaningless on a
shared runner. Run `npm run compare` locally before claiming a performance
change.

## Adding tests

- A geometry bug gets a case in `src/tests.zig` *and*, if JTS covers the shape,
  a check that the relevant JTS case passes.
- A parcel-data failure gets reduced and committed under
  `tests/compare/fixtures/`, then probed.
- Test data is data, not source: `fixtures/` and `generated/` are outside the
  Prettier and SPDX-header rules. Runners and harness code are source and follow
  both.
