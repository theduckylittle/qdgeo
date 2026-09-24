<!-- SPDX-License-Identifier: MIT -->
<!-- Copyright (c) 2026 Dan "Ducky" Little -->

# Testing qdgeo

There are two things to run, and they answer two different questions.

| | Question | Tools | Time | In CI |
| --- | --- | --- | --- | :---: |
| **[Correctness](#correctness)** | Is the answer right? | Zig, Node | ~2 s | yes |
| **[Comparison](#performance-and-comparison)** | Is it fast, and how does it stack up? | + Python/GEOS, optional Rust | minutes | no |

Correctness is cheap, so run it on every change. Comparison needs an oracle,
real data, and a quiet machine, so run it by hand when you need numbers.

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

### What each suite covers

| Suite | Question it answers | Runs against |
| --- | --- | --- |
| `src/tests.zig` | Does the geometry do what we intended? | the Zig code directly |
| `tests/wasm.test.mjs` | Does the browser artifact load and run with no host? | `zig-out/bin/qdgeo.wasm`, raw exports |
| `tests/binding.test.mjs` | Does `js/qdgeo.js` do what its JSDoc says? | the shipped binding |
| `tests/deck.test.mjs` | Does deck.gl render what we hand it? | `js/deck.js` + deck.gl's tesselator |
| `tests/leaflet.test.mjs` | Do rings survive the open/closed round trip? | `js/leaflet.js` + Leaflet itself |
| `tests/jts/jts.test.mjs` | Does it match the reference implementation's own tests? | the artifact, judged by JSTS |

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
assertions. Never edit a case to make it pass. If a case is out of scope, give
it a `test.skip` with a reason.

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
