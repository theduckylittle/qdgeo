<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Dan "Ducky" Little -->

# Testing qdgeo

There are two things to run, and they answer two different questions.

| | Question | Tools | Time | In CI |
| --- | --- | --- | --- | :---: |
| **[Correctness](#correctness)** | Is the answer right? | Zig, Node | ~2 s | yes |
| **[The ceiling](#the-ceiling)** | How big an input before it fails, and how does it fail? | Zig, Node | ~15 s | no, opt-in |
| **[Comparison](#performance-and-comparison)** | Is it fast, and how does it stack up? | + Python/GEOS, optional Rust | minutes | no |

Correctness is cheap, so run it on every change. The ceiling is the same
tooling, grown until the 512 MiB instance gives out, and is opt-in because the
biggest steps hold a quarter of a gigabyte. Comparison needs an oracle, real
data, and a quiet machine, so run it by hand when you need numbers.

## Setup

### For correctness

You need [Zig 0.16.0](https://ziglang.org/download/) and Node 22 or newer.

```sh
npm ci
npm --prefix examples ci     # only for the deck.gl and Leaflet tests
```

The second line installs deck.gl and Leaflet. Without it those two test files
skip instead of running. Everything else works either way.

### For comparison

Adds Python 3.13 and the parcel dataset. Rust is optional.

```sh
python3 -m venv .venv
.venv/bin/pip install -r tests/compare/requirements.txt
npm run fetch-data                          # ~1.9 MB, checksum verified
zig build native -Doptimize=ReleaseSafe     # the WKB path, measured natively

# Optional: builds the rust-geo column and nothing else.
cargo build --release --locked --target wasm32-unknown-unknown \
  --manifest-path tests/compare/rust/Cargo.toml
```

Skip the `cargo` line and rust-geo drops out of the run. Its column reads `—`
and every other engine still gets measured.

## Correctness

```sh
npm run check
```

That runs `zig build test` in Debug and ReleaseSafe, then `vitest run` over
every JavaScript suite. About two seconds.

The pieces, when you want one of them:

```sh
zig build test                            # the geometry itself
zig build test -Doptimize=ReleaseSafe     # again, with the optimiser on
npm test                                  # everything above the ABI
npm run test:watch                        # vitest, re-running on save
npm test -- tests/jts                     # one file or directory
```

`npm test` builds the WASM artifact first, through `pretest`. Zig's cache makes
that a no-op when nothing changed, so you never have to remember it.

### The unit tests

`src/tests.zig` holds every native test — 47, run in Debug and again in
ReleaseSafe, because the optimiser has changed an answer before. They are
small shapes you can reason about by hand, grouped by what they pin:

- **The operations.** Union over overlap, containment, duplicates, disjoint
  parts, edge and point contacts; holes preserved, filled and constructed;
  the four booleans over two squares and over a polygon with a hole; buffers
  positive, zero, negative and collapsing, of points, lines, needles and
  closed lines. A random-rectangle union is checked against an integer-cell
  reference and for idempotence.
- **The overlay's own defects.** One test per bug the fuzz suites found, named
  `overlay: …`, each the smallest input that showed it and its exact area.
  This is where a fuzz failure ends up once it is reduced.
- **`makeValid`.** JTS `GeometryFixer`'s rules on hand-digitized mistakes,
  holes repaired alone and then cut or kept, and valid polygons left as they
  are.
- **The predicates.** The DE-9IM matrix for the textbook cases in JTS's order,
  lines and points against polygons, collections read as unions, lazy pattern
  evaluation and the early exits.
- **The edges of the library.** WKB parsing of every 2D OGC type with every
  truncated prefix and deterministic mutations; flat blocks that reject bad
  indices; the ABI separating a precision limit from malformed input; and
  every allocation failure path releasing its memory, checked under a failing
  allocator.

Green unit tests mean the code compiles and the shapes we thought of still
work. Every overlay defect so far was found by a layer below, which is why
they exist.

### What each suite covers

| Suite | Question it answers | Runs against |
| --- | --- | --- |
| `src/tests.zig` | Does the geometry do what we intended? | the Zig code directly |
| `tests/wasm.test.mjs` | Does the browser artifact load and run with no host? | `zig-out/bin/qdgeo.wasm`, raw exports |
| `tests/binding.test.mjs` | Does `js/qdgeo.js` do what its JSDoc says? | the shipped binding |
| `tests/deck.test.mjs` | Does deck.gl render what we hand it? | `js/deck.js` + deck.gl's tesselator |
| `tests/leaflet.test.mjs` | Do rings survive the open/closed round trip? | `js/leaflet.js` + Leaflet itself |
| `tests/jts/jts.test.mjs` | Does it match the reference implementation's own tests? | the artifact, judged by JSTS |
| `tests/stress.test.mjs` | How big an input before it fails, and how does it fail? Opt-in. | fresh instances of the artifact, judged by closed forms |

**No suite stands in for another.** `zig build test` passing tells you nothing
about the JTS suite, and the JTS suite tells you nothing about parcel data.
Quote the number from the suite that measured it.

### The JTS suite

The XML in `tests/jts/cases/` is copied straight from JTS, unedited, so "passes
the JTS suite" means the real suite. The reference side is JSTS, which is JTS
ported to JavaScript, so the matcher constants are JTS's own.

Four rules are easy to get wrong. `tests/CLAUDE.md` explains why each one
matters:

- Buffers run at `quadrantSegments = 8`, which is JTS's default. Finer is not
  closer here.
- Buffer uses a tolerance matcher. Overlay is exact and must match topologically.
- Non-areal results are skipped, not passed. qdgeo returns polygons only.
- The three policy failures are named in `POLICY_FAILURES` and asserted with
  `test.fails`, so an unexpected pass gets reported too.

Current state: **155 passing, 3 expected failures, 15 skipped**, out of 173
overlay and buffer assertions, and **330 passing, 0 failures, 44 skipped** out
of 374 predicate assertions — the skips all one `MULTIPOINT(EMPTY, …)` shape
JSTS's reader refuses. Never edit a case to make it pass. If a case is out of
scope, give it a `test.skip` with a reason.

### The adapter tests

`tests/deck.test.mjs` and `tests/leaflet.test.mjs` check structure on their own,
then run the real library over the output. That needs
`npm --prefix examples ci`. Without it they skip and say so. In CI they throw
instead, because a structure-only pass is exactly what those two files exist to
catch.

### What CI runs

`.github/workflows/ci.yml` runs on every push: the Zig tests in Debug and
ReleaseSafe, all four build targets, `npm test`, the examples build, the
generated types, the package manifest, Prettier, and `zig fmt`. Zig and Node
only. No Python step and no Rust step.

### Fuzzing edited geometry

```sh
zig build native -Doptimize=ReleaseSafe
.venv/bin/python tests/compare/fuzz.py overlay      # about a minute
.venv/bin/python tests/compare/fuzz.py make-valid   # about forty seconds
```

Opt-in and local, like the comparison: it needs GEOS. It generates polygons the
way people break them, runs them through the overlay and `makeValid`, and
settles every disagreement with GEOS in exact arithmetic, so a failure means
qdgeo is wrong, not just different. Each suite asserts a recorded baseline at
its default seed. `tests/CLAUDE.md` has the rules.

## The ceiling

```sh
npm run stress                                 # about fifteen seconds
QDGEO_STRESS=1 npm test -- tests/stress        # the same, by hand
```

This finds the largest input each operation takes on the 512 MiB instance, and
checks what happens past it. It is a test, not a benchmark: it fails when the
engine gives a wrong answer at any size, traps instead of returning a status,
or when the ceiling moves from the recorded one.

The input is a **fabric**, built by `tests/support/fabric.mjs`: an n-by-n grid
of cells that share every interior edge vertex for vertex, the way parcels do,
with every node and every edge vertex jittered so nothing is axis-aligned or
evenly spaced. The outside stays a straight square, and that is what makes the
answers exact at any size without a reference engine:

- the union, and `makeValid`, of the cells is the square, area `width²`;
- a positive buffer is the square grown by `d` with four rounded corners, and
  an arc of `steps` segments has an exact fan area;
- a negative buffer is the square shrunk by `|d|`;
- the intersection with a copy shifted by half a cell is a rectangle.

Every vertex comes from a hash of its grid position and a seed, so the fabric
is identical on every machine, both cells of a shared edge produce the same
bits without storing the edge, and a million cells build in well under a
second straight into the flat layout.

Each operation starts at 4,096 cells and grows by the square root of two per
side, so the coordinates double each step, on a **fresh instance each step**
— WASM memory never shrinks, so that is the only way the peak is one call's.
It stops at the first failure. At every step it asserts:

1. a result's area matches the closed form to one part in 10⁹, which no wrong
   topology survives;
2. a failure is a `QdgeoError` with one of the three codes valid input may
   produce — `OUT_OF_MEMORY`, `LIMIT_EXCEEDED`, `UNREPRESENTABLE` — and
   never a trap or a host `RangeError`;
3. afterwards, that the last passing step and its peak heap match the
   baseline recorded at the top of the file.

Memory here is deterministic, so a changed baseline is a finding either way.
Lower peak or a higher ceiling is an improvement worth recording in the commit
that made it; higher peak or a lower ceiling is a regression. It runs at UTM
magnitudes (origin 500,000, 5,000,000), where the parcels that motivated it
live and where a crossing is most likely to be unrepresentable.

Current baseline, 2026-10-24:

| operation | ceiling | coordinates | peak heap | stopped by |
| --- | ---: | ---: | ---: | --- |
| union | 256 × 256 cells | 983,280 | 260 MiB | `max_segments` at the next step |
| buffer +20 m | 256 × 256 | 983,280 | 260 MiB | `max_segments` |
| buffer −20 m | 256 × 256 | 983,280 | 261 MiB | `max_segments` |
| `makeValid` | 256 × 256 | 983,280 | 325 MiB | `max_segments` |
| intersection, shifted copy | 128 × 128 | 246,083 | 292 MiB | out of memory at 492,566 |

Its first run found that `makeValid` held five times the heap of the union it
ends with, and ran out at 492,566 coordinates; the fix is in the changelog.
The README's memory section quotes this table.

## Performance and comparison

```sh
npm run compare     # the differential suite
npm run sizes       # what a browser downloads, per library
```

This measures rather than gates. It asks whether qdgeo is right *and* fast on
real cadastral data, against live engines.

### Reading the results fairly

**GEOS is the reference, not an oracle.** On this data it misplaces nearly
parallel intersections by up to `1e-4 m` and leaves filament rings behind. So
the harness adjudicates: it rebuilds the disputed vertex with exact rational
arithmetic and fails whichever side is actually wrong. Never widen a tolerance
to clear a failure. Find out who is wrong instead.

**Timing boundaries are not equal.** qdgeo and Rust Geo are the only matched
pair, both WASM in the same Node process behind the same ABI. GEOS is native and
takes live geometry objects, so it pays no parse cost where qdgeo pays a full
WKB round trip, and Turf's buffers include reprojection. Say which boundary you
mean whenever you quote a ratio.

**Medians move with machine state.** GEOS has measured 356 ms and 452 ms for the
same union hours apart. Treat a gap under 20% as unresolved, and re-measure the
baseline in the same session before reporting a change.

`tests/compare/README.md` has the full method, the workload list, and every
timing boundary.

### Updating the published numbers

Use the **`compare` skill** (`.claude/skills/compare/`). It covers two rules
that are easy to miss: average speed only over each engine's *correct*
workloads, and check a run's exit code before reading its report. A crashed run
leaves the old report in place, and stale numbers look normal.

The parcel cluster sweep lives in the **`correctness` skill**. It has caught
every overlay bug this engine has had, so run it before publishing any
correctness claim.

## Adding tests

- A geometry bug gets a case in `src/tests.zig`. If JTS covers the shape, check
  the matching JTS case too.
- A parcel-data failure gets reduced, committed under `tests/compare/fixtures/`,
  then probed by `probes.py`.
- Test data is data, not source. `fixtures/` and `generated/` sit outside the
  Prettier and SPDX-header rules. Harness code is source and follows both.
