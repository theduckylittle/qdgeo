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

The **depth machinery is already the same idea**: `depthDelta` is the winding
delta each engine here carries per layer, and JTS's 0/1 crossing test is
`filled()`. That part needs no change.

Two things differ, and both matter.

### 1. Curve construction

| | JTS/GEOS | here |
| --- | --- | --- |
| pieces per ring | 1 self-intersecting curve | 1 ring + one quad per edge + one sector per non-mitred vertex |
| complex parcel (19,208 coords) | one curve | **10,857 closed paths, 55,846 segments** |
| runtime, that parcel | 7 ms (GEOS) | 240 ms (WASM), 331 ms (native) |

Every quad overlaps its two neighbours and every sector overlaps two quads, so
the arrangement is dominated by mutual overlap that carries no information. That
is the direct cause of both remaining buffer failures and of the one workload
where this library is far slower than Turf.

### 2. Robustness policy

JTS and GEOS **do not** achieve robust buffering in floating point. They try, and
on failure retry on progressively coarser snap-rounded integer grids, twelve
times, before giving up. Everything above about "exact predicates" is orthogonal:
their line intersector is bound to a precision model that rounds constructed
points onto a grid.

This library currently has no fallback. An exact-arithmetic failure is fatal, by
the rule in `CLAUDE.md` that failures are errors rather than repairs. That rule
is what leaves `parcel-buffer-wide` and `parcel-buffer-mitre` as hard errors
where GEOS returns an answer.

## The bar: turf/buffer coverage

`@turf/buffer` 7.4.0 is JSTS 2.7.1 (`@turf/jsts`) plus a d3 azimuthal-equidistant
projection. Measured, not assumed — every type below returns a usable result:

| Input | turf, +200 m | turf, -200 m | here |
| --- | --- | --- | --- |
| Point | Polygon | null | **rejected** (status 2) |
| MultiPoint | MultiPolygon | null | **rejected** |
| LineString | Polygon | null | **rejected** |
| MultiLineString | MultiPolygon | null | **rejected** |
| Polygon | Polygon | Polygon | ok |
| Polygon with hole | Polygon | Polygon | ok |
| MultiPolygon | MultiPolygon | MultiPolygon | ok |
| GeometryCollection | Polygon | empty | **rejected** |

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

Measured on both backends, native and WASM. Overall across all 26 workloads,
including the unions: 23 for this library, 20 for turf, 26 for GEOS.

Timings moved with it — the complex parcel went from 240 ms to 80 ms in WASM,
level with turf's 80 ms, and the 100-parcel buffers from 6.5 ms to 2.9 ms
against turf's 26 ms.

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
