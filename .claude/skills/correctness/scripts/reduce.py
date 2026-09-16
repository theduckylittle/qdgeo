# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Delta-debug a failing overlay down to the smallest parcel set that shows it.

The oracle matters more than the algorithm. Reducing against "this fails" finds
whichever failure is easiest to reach, which is usually a different, older bug
than the one being chased — that has happened here and cost an afternoon. Give
it an oracle that says what *this* failure is, for example "the current library
fails where a saved baseline .so succeeds".

    reduce.py --op union                          # any failure
    reduce.py --op union --slice 768:1024         # a known-failing window
    reduce.py --op union --against old.so         # fails now, passed before

Writes the reduced input to reduced.wkb and prints its WKT.
"""
import argparse
import ctypes as C
import json
import sys
from pathlib import Path

from shapely.geometry import MultiPolygon, shape

ROOT = Path(__file__).resolve().parents[4]


def engine(path):
    lib = C.CDLL(str(path))
    lib.geom_wkb_apply.argtypes = [
        C.c_uint32, C.c_size_t, C.c_size_t, C.c_uint32, C.c_double, C.c_uint32
    ]
    lib.geom_wkb_apply.restype = C.c_uint32
    return lib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--op', choices=('union', 'buffer'), default='union')
    ap.add_argument('--distance', type=float, default=0.0)
    ap.add_argument('--steps', type=int, default=16)
    ap.add_argument('--count', type=int, default=4127, help='parcels to start from')
    ap.add_argument('--slice', help='START:END window of the parcel list, e.g. 768:1024')
    ap.add_argument('--against', type=Path, help='baseline .so that must SUCCEED for a case to be interesting')
    ap.add_argument('--lib', type=Path, default=ROOT / 'zig-out' / 'lib' / 'libqdgeo_native.so')
    args = ap.parse_args()

    cases = json.load(open(ROOT / 'tests/compare/generated/fixtures.json'))['cases']
    case = next(c for c in cases if c['id'] == 'parcels-union-4040')
    parts = []
    for g in (shape(x) for x in case['geometries']):
        parts.extend(g.geoms if g.geom_type == 'MultiPolygon' else [g])
    if args.slice:
        lo, hi = (int(v) for v in args.slice.split(':'))
        parts = parts[lo:hi]
    else:
        parts = parts[:args.count]

    now = engine(args.lib)
    before = engine(args.against) if args.against else None

    def status(lib, idx):
        blob = MultiPolygon([parts[i] for i in idx]).wkb
        buf = C.create_string_buffer(blob, len(blob))
        op = 0 if args.op == 'union' else 4
        return lib.geom_wkb_apply(op, C.addressof(buf), len(blob), 1, args.distance, args.steps)

    def interesting(idx):
        if not idx or status(now, idx) == 0:
            return False
        return before is None or status(before, idx) == 0

    cur = list(range(len(parts)))
    if not interesting(cur):
        sys.exit('the starting set is not interesting — check the oracle, not the reducer')

    n = 2
    while len(cur) > 1:
        chunk = max(1, len(cur) // n)
        for s in range(0, len(cur), chunk):
            cand = cur[:s] + cur[s + chunk:]
            if interesting(cand):
                cur, n = cand, max(n - 1, 2)
                break
        else:
            if n >= len(cur):
                break
            n = min(n * 2, len(cur))

    reduced = MultiPolygon([parts[i] for i in cur])
    Path('reduced.wkb').write_bytes(reduced.wkb)
    print(f'reduced to {len(cur)} polygons: {cur}')
    print('written to reduced.wkb\n')
    print(reduced.wkt[:4000])


if __name__ == '__main__':
    main()
