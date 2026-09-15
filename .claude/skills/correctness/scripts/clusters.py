# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Buffer and union clusters of adjacent parcels, and check the failure counts.

The 26-workload differential suite has never caught an overlay defect by itself.
These corpora have caught every one, because adjacent parcels share boundaries
with vertices a nanometre apart and that is what breaks a planar overlay.

Exits nonzero if either count differs from the recorded baseline.
"""
import argparse
import ctypes as C
import json
import sys
import time
from pathlib import Path

from shapely.geometry import MultiPolygon, shape

ROOT = Path(__file__).resolve().parents[4]
LIB = ROOT / 'zig-out' / 'lib' / 'libqdgeo_native.so'
FIXTURES = ROOT / 'tests' / 'compare' / 'generated' / 'fixtures.json'
BUFFER_BASELINE = 0
UNION_BASELINE = 4


def parcels():
    cases = json.load(open(FIXTURES))['cases']
    case = next(c for c in cases if c['id'] == 'parcels-union-4040')
    out = []
    for g in (shape(x) for x in case['geometries']):
        out.extend(g.geoms if g.geom_type == 'MultiPolygon' else [g])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--quick', action='store_true', help='2- and 4-parcel clusters only')
    args = ap.parse_args()
    if not LIB.exists():
        sys.exit(f'{LIB} missing — run: zig build native -Doptimize=ReleaseSafe')
    if not FIXTURES.exists():
        sys.exit(f'{FIXTURES} missing — run: npm run fetch-data && npm run compare')

    parts = parcels()
    lib = C.CDLL(str(LIB))
    lib.geom_buffer_with_options.argtypes = [C.c_size_t, C.c_size_t, C.c_double, C.c_uint32]
    lib.geom_buffer_with_options.restype = C.c_uint32
    lib.geom_union.argtypes = [C.c_size_t, C.c_size_t]
    lib.geom_union.restype = C.c_uint32

    groups = (2, 4) if args.quick else (2, 4, 8, 16)
    distances, steps = (0.5, 2, 5, -0.5, -2), (1, 4, 16)
    bad_buf, n_buf, t0 = [], 0, time.perf_counter()
    for k in groups:
        for s in range(0, len(parts) - k, k):
            blob = MultiPolygon(parts[s:s + k]).wkb
            buf = C.create_string_buffer(blob, len(blob))
            for d in distances:
                for q in steps:
                    n_buf += 1
                    if lib.geom_buffer_with_options(C.addressof(buf), len(blob), d, q) != 0:
                        bad_buf.append((k, s, d, q))
    print(f'cluster buffers: {len(bad_buf):5d} of {n_buf} fail   {time.perf_counter() - t0:5.1f}s')

    bad_uni, n_uni, t0 = [], 0, time.perf_counter()
    for k in (groups if args.quick else (2, 4, 8, 16, 64, 256)):
        for s in range(0, len(parts) - k, k):
            blob = MultiPolygon(parts[s:s + k]).wkb
            buf = C.create_string_buffer(blob, len(blob))
            n_uni += 1
            if lib.geom_union(C.addressof(buf), len(blob)) != 0:
                bad_uni.append((k, s))
    print(f'cluster unions:  {len(bad_uni):5d} of {n_uni} fail   {time.perf_counter() - t0:5.1f}s')
    if bad_uni:
        print(f'  union failures: {bad_uni}')

    if args.quick:
        print('\n--quick: counts are not comparable to the baseline')
        return 0
    ok = True
    for label, got, want in (('buffer', len(bad_buf), BUFFER_BASELINE), ('union', len(bad_uni), UNION_BASELINE)):
        if got != want:
            print(f'\nBASELINE MOVED: {label} failures {want} -> {got}')
            ok = False
    if ok:
        print(f'\nbaseline held: {BUFFER_BASELINE} buffer, {UNION_BASELINE} union')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
