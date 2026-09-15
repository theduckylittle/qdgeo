---
name: compare
description: Run qdgeo's differential comparison against GEOS, JSTS, Turf, polyclip-ts and Rust Geo, and update the README's size, speed and correctness tables. Use when asked to update comparisons, re-benchmark, refresh the benchmark numbers, or check how qdgeo stacks up against other geometry libraries.
---

# Updating the comparison

Produces the size, speed and correctness figures the README publishes. The
measurement is easy; the ways of getting it subtly wrong are the reason this
skill exists.

## The rules that matter

**A wrong answer is not a fast answer.** Speed is a geometric mean over each
engine's *correct* workloads only. Wrong results are marked † in the per-case
tables and excluded from every average. This is not a courtesy — Rust Geo's four
fastest workloads are four of its eight failures, so averaging them in would
report a speed nobody can actually use.

**Never read `generated/*.json` without checking the run's exit code.** A
crashed run leaves the previous report in place. Reading it silently republishes
stale numbers, and the output looks completely normal. This has happened.
`scripts/figures.py` refuses to read a report older than the artifacts, but the
shell habit matters too:

```sh
npm run compare > /tmp/compare.out 2>&1; echo "exit=$?"   # check it
npm run compare 2>&1 | tail -5                            # WRONG: $? is tail's
```

**One run is not publishable, however many repeats it has.** Three independent
suite runs, each at 11 repeats, and publish the median across them. Measured
2026-09-15 on an idle machine, two clean 11-repeat runs disagreed by:

| | spread between runs |
| --- | ---: |
| Turf, geometric mean | **31%** |
| polyclip-ts | 20% |
| JSTS | 16% |
| qdgeo native, GEOS, Rust Geo | 8-11% |
| Turf, `edge-point-contact` | **409%** (1.819 / 0.362 / 0.358 ms) |

The variance is JavaScript JIT warmup on the small cases, not geometry. It does
not touch the WASM or native engines. `scripts/aggregate.py` takes the three
report files and prints per-case medians plus the run-to-run spread:

```sh
.venv/bin/python .claude/skills/compare/scripts/aggregate.py runA.json runB.json runC.json
```

Save each run's `generated/report.json` under a different name before starting
the next, or the third overwrites the first.

**Quote two significant figures, never three.** `17x`, not `16.93x`. The third
digit is noise and publishing it claims precision the method does not have.

**Run it on an idle machine.** Editing files, building, or running another suite
during a run contaminates it — that is how the 31% spread above was produced.

**11 repeats per run**, 3 only for a quick sanity check. `figures.py` warns
below 9.

**Timing boundaries are not equal.** qdgeo and Rust Geo are the only matched
pair: both WASM, same Node process, same flat ABI. GEOS is native and receives
live geometry objects, paying no parse or encode where qdgeo pays a full WKB
round trip. Turf's buffers include reprojection. Say so whenever a ratio is
quoted.

**Medians move with machine state.** GEOS has measured 356 ms and 452 ms for the
same union hours apart. Treat a gap under 20% as unresolved, and never report a
change in qdgeo's own numbers without re-measuring the baseline in the same
session.

## Steps

1. **Build everything the suite measures.** All three, or the run compares a
   stale artifact:

   ```sh
   zig build wasm && zig build native -Doptimize=ReleaseSafe
   (cd tests/compare/rust && cargo build --release --target wasm32-unknown-unknown)
   ```

2. **Fetch the parcel dataset** if it is not already there. Public GeoMoose demo
   data, SHA-256 verified:

   ```sh
   npm run fetch-data
   ```

3. **Run the suite three times**, checking each exit code and keeping each
   report. Do nothing else on the machine while they run:

   ```sh
   for run in A B C; do
     timeout 3000 .venv/bin/python tests/compare/run.py --repeats 11 > /tmp/compare.$run.out 2>&1
     echo "run $run exit=$?"
     cp tests/compare/generated/report.json /tmp/report.$run.json
   done
   ```

4. **Measure sizes.** This is the README's source for the size column, so quote
   it rather than a local `gzip` — implementations differ by ~0.2 KB:

   ```sh
   npm run sizes
   ```

5. **Extract the figures.** `figures.py` reads the most recent run and is right
   for correctness and sizes; `aggregate.py` is what the speed tables come from,
   because it is the only one that sees all three runs:

   ```sh
   .venv/bin/python .claude/skills/compare/scripts/figures.py --sizes
   .venv/bin/python .claude/skills/compare/scripts/aggregate.py /tmp/report.{A,B,C}.json
   ```

   Both apply the exclusion rule. **`figures.py` prints sub-millisecond cells at
   two decimals**, which rounds 0.054 to "0.05" and 0.0518 to "0.05" — an 8%
   error that has twice survived into a draft README. Take small cells from
   `aggregate.py`, which prints three significant figures.

6. **Measure ring counts separately.** They are not in the report, and they are
   the most damning correctness number: Rust Geo drops 63 of 445 rings on the
   full parcel union while its symmetric-difference area barely moves. Measure
   from the geometry, never derive from hole counts:

   ```sh
   .venv/bin/python - <<'PY'
   import json, shapely
   from shapely.geometry import shape
   js = json.load(open('tests/compare/generated/js.json'))
   d = json.load(open('tests/compare/generated/fixtures.json'))
   c = {x['id']: x for x in d['cases']}['parcels-union-4040']
   rings = lambda g: sum(1 + len(p.interiors)
                         for p in (list(g.geoms) if g.geom_type == 'MultiPolygon' else [g]))
   print('GEOS', rings(shapely.union_all([shape(g) for g in c['geometries']])))
   for r in js:
       if r['id'] == 'parcels-union-4040' and 'geometry' in r:
           print(r['engine'], rings(shape(r['geometry'])))
   PY
   ```

7. **Update the README** — the at-a-glance table, the union, buffer and overall
   tables, and the artifact size in the banner, the build section and the
   optimize-mode table. Sizes appear in four places; grep for the old number
   rather than trusting memory.

8. **Verify what you wrote, with a script, not by eye.** Parse the README's
   tables back out and compare each cell against the median of the three
   reports, and the size claims against `npm run sizes`. Reading them over has
   failed repeatedly: size claims have been wrong by 60% and by a KiB/KB unit
   confusion, and the two-decimal rounding above slipped through twice. A
   fifteen-line checker catches all of it in one second, and every cell it
   passes is one you can defend.

## What is not measured here

CI does not run this suite: it needs Rust, GEOS, the dataset and several npm
engines, and timings on a shared runner are meaningless. That also means nothing
catches rot in `tests/compare/` automatically — run it before publishing numbers,
and treat a crash as a finding rather than noise.
