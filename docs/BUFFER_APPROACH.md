# How JTS/JSTS and GEOS buffer, and what this library should do

Read alongside `TODO.md`. Sources examined: JSTS 2.7.1
(`org/locationtech/jts/operation/buffer/`, the JTS 1.x algorithm) and GEOS 3.13.1,
which is a port of the same design. Turf's buffer is turf-jsts 1.2.3, the same
code again — so all three references in `tests/compare` share one algorithm.

## What they do

```
BufferOp.computeGeometry
 ├─ bufferOriginalPrecision()                       full double precision
 └─ on any RuntimeException:
    bufferReducedPrecision()                        12 → 0 significant digits
      └─ ScaledNoder(MCIndexSnapRounder, scale)     snap rounding on an integer grid
```

Inside one attempt, `BufferBuilder.buffer`:

1. **`OffsetCurveSetBuilder` → `OffsetCurveBuilder.getRingCurve`** — emits **one
   closed offset curve per ring**, labelled `left = EXTERIOR, right = INTERIOR`
   (flipped for holes). That label is a `depthDelta` of ±1. The curve is allowed
   to be wildly self-intersecting; nothing tries to prevent that.
2. **`computeNodedEdges`** — `MCIndexNoder` with a `RobustLineIntersector` bound
   to a precision model. Duplicate edges are merged and their `depthDelta`s
   summed.
3. **`PlanarGraph`** over the noded edges.
4. **`createSubgraphs` / `buildSubgraphs`** — connected components, each seeded by
   a ray cast from its rightmost coordinate through the already-processed
   subgraphs (`SubgraphDepthLocater`), then `computeDepth` propagates, and
   `findResultEdges` keeps edges where depth crosses 0/1.
5. **`PolygonBuilder`** assembles shells and holes.

`OffsetSegmentGenerator` builds the curve vertex by vertex: a fillet arc on an
outside turn, "closing segments" on an inside turn, plus these distance-relative
tolerances, none of which is optional:

| Constant | Value | Role |
| --- | ---: | --- |
| `BufferParameters.DEFAULT_SIMPLIFY_FACTOR` | `0.01 · d` | Douglas-Peucker on the input ring |
| `OFFSET_SEGMENT_SEPARATION_FACTOR` | `1e-3 · d` | collapse an outside turn to one point |
| `INSIDE_TURN_VERTEX_SNAP_DISTANCE_FACTOR` | `1e-3 · d` | snap an inside turn |
| `CURVE_VERTEX_SNAP_DISTANCE_FACTOR` | `1e-6 · d` | minimum vertex spacing on the emitted curve |
| `MAX_CLOSING_SEG_LEN_FACTOR` | `80` | length of inside-turn closing segments |
| `DEFAULT_MITRE_LIMIT` | `5.0` | mitre join cap |
| `DEFAULT_QUADRANT_SEGMENTS` | `8` | half our default |

## How this library differs

The **depth machinery is the same idea**: `depthDelta` is the winding delta
carried per layer here, and JTS's 0/1 crossing test is `filled()`. Curve
construction is also the same now — one self-intersecting offset curve per ring,
line and point, ported from JTS. A 19,208-coordinate parcel yields 7 curves and
32,031 segments, 1.67x its input.

What still differs is **when the depth decision is made, and from what**.

| | JTS / GEOS | qdgeo |
| --- | --- | --- |
| when | after the whole noded graph exists | during the sweep, per segment |
| from | one propagation over a finished `PlanarGraph` | `below`, a winding cached at the segment's opening event |
| seeded by | a ray cast from each subgraph's rightmost coordinate through the subgraphs already placed (`SubgraphDepthLocater`) | the status line as it stood at two moments in time |
| selection | `findResultEdges`, depth crossing 0/1 | `transition != 0` on each segment independently |
| both directions of an edge | always, as `DirectedEdge` pairs | one, oriented by the transition |

GEOS derives every edge's depth from a **single propagation over a structure that
is already complete**, so the selected edges form a closed boundary by
construction. qdgeo makes a **streaming, order-dependent decision per segment**
and nothing checks that the union of those decisions closes until the contour
walk runs off the end.

That was the whole of the difference, and `sweep.execute` now closes it: it
retries the overlay with a JTS-style graph labelling whenever the streaming one
returns `NodingFailure`. See "Two labellings, one fallback" in `CLAUDE.md`. What
survives the retry is a different problem — an arrangement that is not fully
noded — described below.

### Why it shows up in buffers and not booleans

Measured over ~300,000 random valid inputs before the fallback: **0 failures
across ~120,000 boolean operations, 190 across ~30,000 buffers**. Offset curves
manufacture exact coincidences by construction — arcs meeting straight runs,
curves from separate rings touching at a single point — at a density real parcel
data never reaches. The streaming labelling is where two segments meeting at
such a junction can be labelled from inconsistent snapshots.

With the fallback, on 57,990 buffers of 2-to-16-parcel clusters across five
distances and three arc resolutions: **10 failures become 6**. The graph
labelling rescues every case the streaming one gets wrong *for labelling
reasons*. The remaining 6 failed under both, because the arrangement still held
crossings with no node on them — pairs of vertices a couple of nanometres apart
where a computed split point rounded off the other segment's line.

Those 6 are now **0**, because `execute` sweeps its own arrangement once more
before giving up. Every crossing the first sweep found is an endpoint the second
time, so the second sweep has only the ones rounding moved left to find. The
figure-eight LineString buffer closes the same way and matches GEOS at
4.2689251551415985. No coordinate is changed and no tolerance is introduced; see
"One re-noding pass" in `CLAUDE.md`.

What survives even that is a genuinely unrepresentable crossing: the exact
intersection, rounded to f64, lands on or past an endpoint of one of the two
segments, so putting a vertex there would move the crossing off the other
segment's line. The noding reaches a fixpoint with the hole still in it —
measured at 847 segments in and 847 out, pass after pass. `execute` reports
`error.UnnodableCrossing` for these, which is the precision limit talking rather
than a bug. It is 4 of 3,946 cluster unions, and only snapping the two vertices
together would close it.

### Robustness policy, corrected

JTS and GEOS do carry a fallback: on any exception they retry on progressively
coarser snap-rounded integer grids, twelve times. **That is not what saves them
here.** Every one of 24 inputs qdgeo cannot buffer, GEOS buffers correctly on the
*first* attempt at full double precision — the output carries irrational arc
vertices with full mantissas and nothing lands on a coarse grid, so
`bufferReducedPrecision` never runs. The difference is the graph, not the grid.

qdgeo has no *snap-rounding* fallback and will not grow one: an exact-arithmetic
failure is an error, by the rule in `CLAUDE.md`. Fixing the labelling removed
most of the errors without touching that policy — the graph-labelling retry
changes nothing about precision, only about which pass assigns the fill. The
residue is exactly the part where the policy costs something — 4 of 3,946
cluster unions, reported as `error.UnnodableCrossing` — and that trade is still
open.

## The bar: turf/buffer coverage

`@turf/buffer` 7.4.0 is JSTS 2.7.1 (`@turf/jsts`) plus a d3 azimuthal-equidistant
projection. Measured, not assumed — every type below returns a usable result:

| Input | turf, +200 m | turf, -200 m | here |
| --- | --- | --- | --- |
| Point | Polygon | null | ok (a disc) |
| MultiPoint | MultiPolygon | null | ok |
| LineString | Polygon | null | ok (a stadium) |
| MultiLineString | MultiPolygon | null | ok |
| Polygon | Polygon | Polygon | ok |
| Polygon with hole | Polygon | Polygon | ok |
| MultiPolygon | MultiPolygon | MultiPolygon | ok |
| GeometryCollection | Polygon | empty | ok (all three parts at once) |

On the parcel workloads in `tests/compare`, turf passes **13 of 14** — it fails
`donut-buffer--1`, where it emits a self-intersecting, invalid polygon. This
library passes 12 of 14 on the `graph` backend.

So "meet or beat turf" is two numbers: **8 of 8 input shapes** (currently 2) and
**13 of 14 workloads** (currently 12). The type gap is the larger one, and it is
also the gap that blocks the GeoMoose swap, where buffering a drawn point or line
is the common case rather than an edge case.

## What was built

The JTS/GEOS construction, on this library's overlay. `src/offset.zig` emits one
raw curve per ring, per line and per point; `operations.zig` hands them to the
overlay as `layer = 0` paths and keeps what they wind at least once. The band
decomposition is gone, and with it `Mode.subtract_band` — buffer and union now
want the same thing from the overlay, so `Mode` has one variant.

One change bought both axes of the bar, as expected: a point has no ring to band
but it has a circle, and a line has no interior but it has two offset sides and
two caps.

Two things are deliberately **not** copied from JTS:

- **Input simplification is off by default.** JTS and GEOS simplify at
  `0.01 * distance` because their noder needs the help. Measured here it costs
  exactly that much accuracy — worst-case Hausdorff against GEOS went from
  `2e-6 m` to `1.1e-2 m` at a 2 m buffer with it switched on — and it fixes
  nothing this construction cannot already do. It survives as
  `BufferOptions.simplify_factor`, defaulting to 0.
- **No reduced-precision retry ladder.** It was not needed. Every workload
  completes exactly, so the "failures are errors, not repairs" rule stands.

`isErodedCompletely` *is* copied, and is load-bearing: a ring narrower than twice
the erosion distance offsets to a curve that has turned inside out — still
closed, still wound positively, enclosing a region that is not in the buffer.
Winding alone cannot tell that curve from a real one.

## Result against the bar

| | turf/buffer | here |
| --- | --- | --- |
| input shapes | 8 of 8 | **8 of 8** |
| parcel workloads | 13 of 14 | **14 of 14** |
| invalid outputs | 1 (`donut-buffer--1`) | **0** |
| worst relative area difference vs GEOS | — | **9.05e-11** |

That was written when two engines shipped. Current numbers across all 26
workloads live in the README: 26 for qdgeo, 26 for GEOS, 24 for JSTS, 23 for
turf, 18 for Rust Geo. The complex parcel is 40 ms in WASM against turf's 140 ms
and GEOS's 11 ms, and the 100-parcel buffers are 1.5 ms against turf's 35 ms.

## Original recommendation

Adopt the JTS/GEOS construction, keep this library's overlay. One change buys
both axes of the bar, which is what settles the approach: the band decomposition
*cannot* be extended to points and lines, because it unions its input first and
then bands the boundary of the result — a point has no ring and a line has no
interior. JTS has no such problem, because `OffsetCurveBuilder` exposes
`getLineCurve` for open input and caps alongside `getRingCurve` for closed input,
feeding the same noder and the same depth analysis.

1. **Replace the band decomposition with one offset curve per ring.** Emit fillet
   arcs on outside turns and closing segments on inside turns, hand the resulting
   self-intersecting curve to the existing overlay as a single `layer = 1` path,
   and let winding depth resolve it. This removes the pathology at its source and
   should close most of the 34x gap on the complex parcel.
2. **Adopt their distance-relative curve tolerances** rather than the
   arc-sagitta rule invented here. They are tuned against exactly this kind of
   data and cover cases the sagitta rule does not.
3. **Then decide on the snap-rounding ladder** — see `TODO.md`. It is the only
   part that contradicts a stated house rule, and it is what separates "returns a
   slightly rounded answer" from "returns an error".

Step 1 keeps the exactness rule intact and is worth doing regardless of step 3.
