---
name: correctness
description: Run qdgeo's full correctness sweep — native tests, the JTS Topology Suite, the WASM runtime checks, and the parcel cluster corpora that find overlay failures the fixture suite misses. Use when asked to verify correctness, check for regressions, before committing an overlay change, or after touching sweep.zig, offset.zig or operations.zig.
---

# Verifying correctness

Four layers, cheapest first. Run all of them before publishing a claim about
correctness; run the first two — which is `npm run check` — before any commit
that touches the overlay.

Speed belongs to the `compare` skill. This one is only about answers.

## The rules that matter

**Green unit tests do not mean correct.** `zig build test` is 29 assertions on
shapes small enough to reason about. Every defect found in this engine so far
was found by one of the other three layers. Treat it as the compile check.

**Never read an exit code through a pipe.** `zig build test 2>&1 | tail` reports
`tail`'s status, which is always 0. This has produced "all green" three separate
times over a crashing run. Use `set -o pipefail`, or redirect and check.

**The cluster corpora are where overlay bugs live.** The 26-workload fixture
suite has never caught an overlay defect on its own. The 57,990 cluster buffers
and 3,946 cluster unions below found every one: the ~0.6% buffer defect, the
four unnodable unions, and the regression where graph labelling broke the
4,040-parcel union. They take about 30 seconds.

**A changed failure count is the finding.** Not the failure itself. Record the
before number, change the code, record the after. "0 of 57,990" means nothing
unless you know it was 6 yesterday.

**Failures are errors, never wrong answers.** If a change turns an error into a
silently wrong result, that is worse than the error, and no count will show it.
Compare areas against GEOS whenever the failure count drops.

## Steps

1. **Native tests**, both modes:

   ```sh
   set -o pipefail
   zig build test && zig build test -Doptimize=ReleaseSafe; echo "exit=$?"
   ```

2. **Everything above the ABI**, in one command. vitest over the WASM runtime
   checks (which assert the import list is empty — a `std.debug.print` left in a
   hot path breaks it), the binding, both adapters, and the JTS Topology Suite.
   `pretest` rebuilds the artifact, so there is nothing to remember:

   ```sh
   set -o pipefail
   npm test; echo "exit=$?"
   ```

   The JTS baseline is **155 passing of 158 applicable assertions**, with 15
   skipped — 12 non-areal, and 3 from one case JTS's own `WKTReader` will not
   load. The 3 failures are all degenerate rings and are the documented
   rejection policy, not bugs; they are named in `POLICY_FAILURES` and asserted
   with `test.fails`, so both a regression and an unexpected fix report the
   specific case rather than moving a number.

   Steps 1 and 2 together are `npm run check`. They need Zig and Node and
   nothing else, and take about two seconds.

3. **The cluster corpora.** Not in any fixture file; generated from the parcel
   dataset. This is the layer that finds overlay defects:

   ```sh
   .venv/bin/python .claude/skills/correctness/scripts/clusters.py
   ```

   Current baseline, which the script asserts:

   | corpus | calls | failures |
   | --- | ---: | ---: |
   | cluster buffers, 2-16 parcels, 5 distances, q = 1/4/16 | 57,990 | **0** |
   | cluster unions, 2-256 parcels | 3,946 | **4** |

   The 4 are `UnnodableCrossing` — a crossing whose rounded intersection lands
   on or past an endpoint. They are documented in the README under "When valid
   input fails". If that number moves either way, find out why before shipping.

4. **The differential suite**, if the change could alter geometry rather than
   only fail differently:

   ```sh
   timeout 3000 .venv/bin/python tests/compare/run.py > /tmp/diff.out 2>&1; echo "exit=$?"
   sed -n '/Failed checks/,$p' /tmp/diff.out | grep zig- || echo "no qdgeo failures"
   ```

   26 of 26 workloads, and **no line mentioning `zig-native` or `zig-wasm`** in
   the failed-checks block. Other engines' failures are expected and listed
   there permanently.

## When a failure count changes

Reduce it to the smallest input that still shows it, against an oracle that says
what "still shows it" means — "fails now and passed before", not just "fails".
Delta debugging over the parcel list gets from 4,000 polygons to 5 in about two
minutes; `scripts/reduce.py` does it. A reduction against the wrong oracle finds
a different, pre-existing bug and wastes the afternoon, which has happened.

Then check whether the arrangement is the problem before the labelling is: count
crossings whose intersection cannot be placed on either segment. If that count
is nonzero the input is at a noding fixpoint and no labelling change will help.
