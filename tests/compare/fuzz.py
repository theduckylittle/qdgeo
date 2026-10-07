# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Fuzz the overlay and makeValid with hand-digitized-style polygons.

The parcel corpora never found what this finds. Parcels are clean; edited
geometry is not. This generates rings the way people break them by hand —
twists, backtracks, spikes, repeated vertices, overshoots at the close, holes
inside, across and outside the shell, half on an integer grid where collinear
overlaps are exact — and checks qdgeo against GEOS.

GEOS is the reference, not the oracle. Every disagreement is settled with
exact arithmetic: a point inside the region where the two answers differ is
located against the original input with `fractions.Fraction`, and whichever
side has it wrong is counted. Only qdgeo's wrong answers fail the run.

    overlay     two valid operands each — GEOS's repair of a generated
                polygon, so valid but full of vertices at rounded crossings —
                through union, intersection and difference
    make-valid  each generated polygon through makeValid, against Shapely's
                make_valid(method='structure'), which follows the same rules

    zig build native -Doptimize=ReleaseSafe
    .venv/bin/python tests/compare/fuzz.py overlay [--cases N] [--seed S]
    .venv/bin/python tests/compare/fuzz.py make-valid [--cases N] [--seed S]

The baselines below are for the default seed and case count, and the run
fails if a count of qdgeo's wrong answers moves. UNREPRESENTABLE is not
wrong: it is the documented answer for a crossing f64 cannot hold, and
GEOS answers those only by snapping.
"""
import argparse
import ctypes as C
import math
import random
import sys
import time
from collections import Counter
from fractions import Fraction as F
from pathlib import Path

import shapely
from shapely import MultiPolygon, Polygon, make_valid

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / 'zig-out' / 'lib' / 'libqdgeo_native.so'
UNION, INTERSECTION, DIFFERENCE, MAKE_VALID = 0, 1, 2, 5
STATUS = {1: 'OUT_OF_MEMORY', 3: 'LIMIT_EXCEEDED', 4: 'COORDINATE_RANGE',
          5: 'INVALID_GEOMETRY', 6: 'INVALID_OPTIONS', 7: 'UNREPRESENTABLE'}

# qdgeo answers the exact referee calls wrong, at the default seed and count.
# The overlay's one is a union: a vertex within half an ulp of an edge of
# another polygon in the same operand, so the crossing cannot be placed and
# the sweep keeps a stale winding along the edge. Between operands that is
# caught and declined (`misorders` in src/sweep.zig); within one operand the
# same test cannot tell this wedge from the 2 nm cracks between adjacent
# parcels that the parcel unions close the same way GEOS does, without a size
# threshold. It comes back valid, 4.5 units of area over.
BASELINE = {'overlay': 1, 'make-valid': 0}


def digitized(rng, grid, cx, cy, radius):
    """A ring traced around a centre, then broken the ways a hand breaks one."""
    angles = sorted(rng.uniform(0, 2 * math.pi) for _ in range(rng.randint(4, 40)))
    ring = []
    for a in angles:
        r = radius * rng.uniform(0.4, 1.0)
        ring.append([cx + r * math.cos(a), cy + r * math.sin(a)])
    for _ in range(rng.randint(0, 4)):
        kind = rng.choice(('twist', 'backtrack', 'spike', 'repeat', 'jump'))
        i = rng.randrange(len(ring))
        if kind == 'twist' and len(ring) > 3:
            j = rng.randrange(len(ring))
            ring[i], ring[j] = ring[j], ring[i]
        elif kind == 'backtrack' and i > 1:
            ring[i:i] = [list(p) for p in reversed(ring[max(0, i - 3):i])]
        elif kind == 'spike':
            p = ring[i]
            ring[i + 1:i + 1] = [[p[0] + rng.uniform(-60, 60), p[1] + rng.uniform(-60, 60)], list(p)]
        elif kind == 'repeat':
            ring.insert(i, list(ring[i]))
        elif kind == 'jump':
            ring.insert(i, [cx + rng.uniform(-1.5, 1.5) * radius, cy + rng.uniform(-1.5, 1.5) * radius])
    if rng.random() < 0.15:
        ring.extend(list(p) for p in ring[: rng.randint(1, 3)])  # overshoot at the close
    if rng.random() < 0.3:
        ring.reverse()
    if grid:
        ring = [[round(x / grid) * grid, round(y / grid) * grid] for x, y in ring]
    return ring + [list(ring[0])]


def generate(rng):
    """One to three polygons, each a shell and up to three holes, as rings."""
    grid = rng.choice((0, 1, 5, 10)) if rng.random() < 0.5 else 0
    polygons = []
    for k in range(rng.choice((1, 1, 1, 2, 3))):
        cx, cy = rng.uniform(-80, 80) * k, rng.uniform(-80, 80) * k
        rings = [digitized(rng, grid, cx, cy, 100)]
        for _ in range(rng.choice((0, 0, 1, 2, 3))):
            rings.append(digitized(rng, grid, cx + rng.uniform(-120, 120), cy + rng.uniform(-120, 120),
                                   rng.uniform(10, 50)))
        polygons.append(rings)
    return polygons


def to_shapely(polygons):
    return MultiPolygon([Polygon(p[0], p[1:]) for p in polygons])


def parts(geometry):
    if geometry.geom_type == 'Polygon':
        return [] if geometry.is_empty else [geometry]
    return [g for g in getattr(geometry, 'geoms', []) if g.geom_type == 'Polygon']


class Native:
    def __init__(self):
        self.lib = C.CDLL(str(LIB))
        self.lib.geom_wkb_apply.argtypes = [C.c_uint32, C.c_size_t, C.c_size_t, C.c_uint32, C.c_double, C.c_uint32]
        self.lib.geom_wkb_apply.restype = C.c_uint32
        self.lib.geom_wkb_result_ptr.restype = C.c_size_t
        self.lib.geom_wkb_result_len.restype = C.c_size_t

    def apply(self, op, subject, clip=()):
        blob = shapely.to_wkb(MultiPolygon(list(subject) + list(clip)))
        buf = C.create_string_buffer(blob, len(blob))
        code = self.lib.geom_wkb_apply(op, C.addressof(buf), len(blob), len(subject), 0.0, 16)
        if code:
            return STATUS.get(code, code)
        return shapely.from_wkb(C.string_at(self.lib.geom_wkb_result_ptr(), self.lib.geom_wkb_result_len()))


def winding(coords, p):
    """The exact winding number of a closed coordinate list around `p`."""
    w = 0
    pts = [(F(x), F(y)) for x, y in coords]
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        cross = (x2 - x1) * (p[1] - y1) - (p[0] - x1) * (y2 - y1)
        if y1 <= p[1] < y2 and cross > 0:
            w += 1
        elif y2 <= p[1] < y1 and cross < 0:
            w -= 1
    return w


def inside(polygon, p):
    """Exact membership in a valid polygon: inside the shell and no hole."""
    return winding(polygon.exterior.coords, p) != 0 and not any(
        winding(r.coords, p) != 0 for r in polygon.interiors)


def adjudicate(got, want, truth):
    """Which side is wrong, decided at one point of each region they disagree on."""
    wrong = set()
    for holder, region in (('qdgeo', got.difference(want)), ('GEOS', want.difference(got))):
        for part in getattr(region, 'geoms', [region]):
            if part.is_empty or part.area < 1e-9:
                continue
            q = part.representative_point()
            member = truth((F(q.x), F(q.y)))
            # A point only one side has: that side is right exactly when it belongs.
            wrong.add(('GEOS' if holder == 'qdgeo' else 'qdgeo') if member else holder)
    return wrong


SHOWN = []


def show(label, *operands):
    """Keep a qdgeo-wrong input for printing, as WKT that round-trips."""
    SHOWN.append((label, [[shapely.to_wkt(p, rounding_precision=-1) for p in o] for o in operands]))


def overlay_case(native, rng, outcome):
    a = parts(make_valid(to_shapely(generate(rng)), method='structure', keep_collapsed=False))
    b = parts(make_valid(to_shapely(generate(rng)), method='structure', keep_collapsed=False))
    if not a or not b:
        return
    ga, gb = shapely.union_all(a), shapely.union_all(b)
    for name, op, reference, rule in (
        ('union', UNION, lambda: shapely.union_all(a + b), lambda x, y: x or y),
        ('intersection', INTERSECTION, lambda: ga.intersection(gb), lambda x, y: x and y),
        ('difference', DIFFERENCE, lambda: ga.difference(gb), lambda x, y: x and not y),
    ):
        got = native.apply(op, a, [] if op == UNION else b) if op != UNION else native.apply(op, a + b)
        if isinstance(got, str):
            outcome[f'{name}: {got}'] += 1
            continue
        if not got.is_valid:
            outcome[f'{name}: qdgeo wrong (invalid output)'] += 1
            show(name, a, b)
            continue
        want = reference()
        if got.symmetric_difference(want).area / max(want.area, got.area, 1) <= 1e-9:
            outcome[f'{name}: match'] += 1
            continue
        truth = lambda p: rule(any(inside(q, p) for q in a), any(inside(q, p) for q in b))
        for side in adjudicate(got, want, truth) or {'neither (sub-1e-9 area)'}:
            outcome[f'{name}: {side} wrong'] += 1
            if side == 'qdgeo':
                show(name, a, b)


def make_valid_case(native, rng, outcome):
    polygons = generate(rng)
    source = to_shapely(polygons)
    got = native.apply(MAKE_VALID, list(source.geoms))
    if isinstance(got, str):
        outcome[f'make-valid: {got}'] += 1
        return
    if not got.is_valid:
        outcome['make-valid: qdgeo wrong (invalid output)'] += 1
        show('make-valid', list(source.geoms))
        return
    want = make_valid(source, method='structure', keep_collapsed=False)
    if got.symmetric_difference(want).area / max(want.area, got.area, 1) <= 1e-9:
        outcome['make-valid: match'] += 1
        return

    # GeometryFixer's rule, exactly: a ring covers what it winds around in
    # either direction; holes that meet the shell are cut, the rest kept.
    # Membership is exact, but whether a repaired hole meets its repaired
    # shell is a question about repaired rings, and neither side's are exact:
    # GEOS snaps, and collapses a ring that doubles back over itself to
    # nothing; qdgeo rounds crossings, which can turn a zero-width spike into
    # a sliver 1e-15 wide. Where the two classify a hole differently, the
    # rule's answer depends on rounding and no side is called wrong.
    def classify(fix):
        rules = []
        for rings in polygons:
            shell = fix(rings[0])
            cut, outside = [], []
            for hole in rings[1:]:
                (cut if shell.intersects(fix(hole)) else outside).append(hole)
            rules.append((rings[0], cut, outside))
        return rules

    def ours(ring):
        g = native.apply(MAKE_VALID, [Polygon(ring)])
        return shapely.union_all(parts(g)) if not isinstance(g, str) else Polygon()

    rules = classify(ours)
    if rules != classify(lambda ring: make_valid(Polygon(ring), method='structure', keep_collapsed=False)):
        outcome['make-valid: hole classification depends on rounding'] += 1
        return

    def truth(p):
        return any(
            (winding(shell, p) != 0 and not any(winding(h, p) != 0 for h in cut))
            or any(winding(h, p) != 0 for h in outside)
            for shell, cut, outside in rules)

    for side in adjudicate(got, want, truth) or {'neither (sub-1e-9 area)'}:
        outcome[f'make-valid: {side} wrong'] += 1
        if side == 'qdgeo':
            show('make-valid', list(source.geoms))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('suite', choices=('overlay', 'make-valid'))
    ap.add_argument('--cases', type=int, default=None, help='default: 10,000 overlay, 20,000 make-valid')
    ap.add_argument('--seed', type=int, default=None, help='default: 7 overlay, 1 make-valid')
    ap.add_argument('--show', action='store_true', help='print every input qdgeo got wrong')
    args = ap.parse_args()
    if not LIB.exists():
        sys.exit(f'{LIB} missing — run: zig build native -Doptimize=ReleaseSafe')
    default = {'overlay': (10000, 7), 'make-valid': (20000, 1)}[args.suite]
    cases = args.cases if args.cases is not None else default[0]
    seed = args.seed if args.seed is not None else default[1]

    native, rng, outcome = Native(), random.Random(seed), Counter()
    run = overlay_case if args.suite == 'overlay' else make_valid_case
    start = time.perf_counter()
    for _ in range(cases):
        run(native, rng, outcome)
    print(f'{args.suite}: {cases} cases, seed {seed}, {time.perf_counter() - start:.1f}s')
    for key in sorted(outcome):
        print(f'  {key:52} {outcome[key]}')
    if args.show:
        for label, operands in SHOWN:
            print(f'\n{label}:', *operands, sep='\n  ')

    wrong = sum(n for k, n in outcome.items() if 'qdgeo wrong' in k)
    if (cases, seed) != default:
        print(f'\n{wrong} wrong; not compared with the baseline, which is for the defaults')
        return 0 if wrong == 0 else 1
    expected = BASELINE[args.suite]
    print(f'\nbaseline {"held" if wrong == expected else "MOVED"}: {wrong} qdgeo wrong, expected {expected}')
    return 0 if wrong == expected else 1


if __name__ == '__main__':
    sys.exit(main())
