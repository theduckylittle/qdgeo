# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Reproducible parcel/backend review. GEOS is an oracle, not a proof of correctness.

Run from the repository root. Build/install instructions: tests/compare/README.md.
"""
import argparse
import ctypes as C
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time
from fractions import Fraction
import shapely
from shapely.geometry import shape, mapping, MultiPolygon, Polygon, Point
from shapely.strtree import STRtree
from prepare import prepare, DEFAULT_SOURCE

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'tests/compare/generated'

def measure(fn, repeats):
    fn()
    times = []
    for _ in range(repeats):
        start = time.perf_counter_ns()
        result = fn()
        times.append((time.perf_counter_ns()-start)/1e6)
    return result, times

class Native:
    def __init__(self):
        self.lib = C.CDLL(str(ROOT / 'zig-out/lib/libqdgeo_native.so'))
        self.lib.geom_union.argtypes = [C.c_void_p, C.c_size_t]
        self.lib.geom_buffer_with_options.argtypes = [C.c_void_p, C.c_size_t, C.c_double, C.c_uint32]
        self.lib.geom_result_ptr.restype = C.c_void_p
        self.lib.geom_result_len.restype = C.c_size_t
    def run(self, blob, c):
        # The library borrows these bytes for the call and never takes ownership,
        # so Python keeps them. The result is copied before geom_clear releases it.
        try:
            if c['operation'] == 'union':
                status = self.lib.geom_union(blob, len(blob))
            else:
                status = self.lib.geom_buffer_with_options(blob, len(blob), c['distance'], c['steps'])
            if status:
                raise RuntimeError(f'native status {status}')
            return C.string_at(self.lib.geom_result_ptr(), self.lib.geom_result_len())
        finally:
            self.lib.geom_clear()

def parts(g):
    if g.is_empty: return []
    return list(g.geoms) if g.geom_type == 'MultiPolygon' else [g]

def rings(g):
    for p in parts(g):
        yield p.exterior
        for hole in p.interiors:
            yield hole

def is_filament(ring, tolerance):
    """A ring thinner than the positional tolerance along its whole length: its
    area is under half its own perimeter times that tolerance. GEOS leaves these
    behind where parcels share a boundary — one hole in the 4,040-parcel union is
    1591 m round and 1.5 mm2 in area. They carry no area, so symmetric difference
    cannot see them, but they wreck a boundary Hausdorff."""
    length = ring.length
    return length > 0 and Polygon(ring).area < 0.5 * length * tolerance

def drop_filaments(g, tolerance):
    kept = []
    for p in parts(g):
        if is_filament(p.exterior, tolerance): continue
        kept.append(Polygon(p.exterior, [h for h in p.interiors if not is_filament(h, tolerance)]))
    return MultiPolygon(kept) if kept else shapely.from_wkt('MULTIPOLYGON EMPTY')

_segment_cache = {}
def input_segments(c):
    """Every input edge, indexed. Vertices of a correct overlay are either input
    vertices or intersections of two input edges, so these are enough to check a
    disputed vertex against exact arithmetic."""
    if c['id'] not in _segment_cache:
        segs = []
        for gj in c['geometries']:
            for p in parts(shape(gj)):
                for ring in [p.exterior] + list(p.interiors):
                    coords = list(ring.coords)
                    segs += [shapely.LineString(coords[i:i+2]) for i in range(len(coords)-1)]
        _segment_cache[c['id']] = (segs, STRtree(segs))
    return _segment_cache[c['id']]

def exact_meet(e0, e1):
    (ax, ay), (bx, by) = [tuple(map(Fraction, p)) for p in e0]
    (cx, cy), (dx, dy) = [tuple(map(Fraction, p)) for p in e1]
    ux, uy, vx, vy = bx-ax, by-ay, dx-cx, dy-cy
    denominator = ux*vy - uy*vx
    if denominator == 0: return None
    t = ((cx-ax)*vy - (cy-ay)*vx) / denominator
    return float(ax + t*ux), float(ay + t*uy)

def adjudicate(engine, reference, c):
    """Reconstruct every disputed vertex exactly and report how far each side is
    from the truth. GEOS is the reference, not an oracle: on nearly parallel
    parcel edges its f64 line intersector misplaces a vertex by up to 1e-4 m,
    which a boundary Hausdorff then charges to whichever engine got it right.
    This is symmetric — an engine whose vertices are wrong still fails."""
    segs, tree = input_segments(c)
    worst = {'engine': 0.0, 'reference': 0.0}
    counted = {'engine': 0, 'reference': 0}
    unresolved = 0
    for name, geom, other in (('engine', engine, reference.boundary), ('reference', reference, engine.boundary)):
        for xy in shapely.get_coordinates(geom):
            point = Point(xy)
            if point.distance(other) <= 1e-9: continue
            near = []
            for i in tree.query(point.buffer(1e-6)):
                coords = list(segs[i].coords)
                if segs[i].distance(point) < 1e-6 and coords not in near and coords[::-1] not in near:
                    near.append(coords)
            meet = exact_meet(*near) if len(near) == 2 else None
            if meet is None:
                unresolved += 1
                continue
            worst[name] = max(worst[name], math.hypot(xy[0]-meet[0], xy[1]-meet[1]))
            counted[name] += 1
    return worst, counted, unresolved

def metrics(g, ref, c):
    result = dict(valid=bool(shapely.is_valid(g)), validity=shapely.is_valid_reason(g),
                  area=float(g.area), polygons=len(parts(g)), holes=sum(len(p.interiors) for p in parts(g)),
                  points=int(shapely.get_num_coordinates(g)))
    if not result['valid']:
        result['pass'] = False
        return result
    diff = g.symmetric_difference(ref).area
    # Positional envelope, not an exact mathematical error bound. Round joins
    # have different tessellation phase across engines: allow two sagittas.
    position_tol = 1e-7
    if c['operation'] == 'buffer':
        position_tol += 2*abs(c['distance'])*(1-math.cos(math.pi/(4*c['steps']))) + 2e-5
    area_tol = max(1e-6, ref.length * position_tol)
    result.update(symdiff_area=float(diff), symdiff_relative=float(diff/max(ref.area,1e-30)),
                  area_tolerance=area_tol, pass_area=bool(diff <= area_tol))
    # Full boundary Hausdorff is quadratic; cap it explicitly, do not silently
    # substitute an approximate metric for large parcel sets.
    # Hairline rings are compared out of the boundary metric on both sides, and
    # counted, so neither engine can hide one.
    result['filaments'] = sum(1 for r in rings(g) if is_filament(r, position_tol))
    result['reference_filaments'] = sum(1 for r in rings(ref) if is_filament(r, position_tol))
    solid, solid_ref = drop_filaments(g, position_tol), drop_filaments(ref, position_tol)
    hd = None
    if not solid.is_empty and not solid_ref.is_empty and max(shapely.get_num_coordinates(solid),shapely.get_num_coordinates(solid_ref)) <= 5000:
        hd = float(shapely.hausdorff_distance(solid.boundary,solid_ref.boundary))
    result['boundary_hausdorff'] = hd
    result['position_tolerance'] = position_tol
    result['pass'] = result['pass_area'] and (hd is None or hd <= position_tol)
    if hd is not None and hd > position_tol:
        worst, counted, unresolved = adjudicate(solid, solid_ref, c)
        result.update(exact_error=worst['engine'], reference_exact_error=worst['reference'],
                      adjudicated=counted, adjudication_unresolved=unresolved)
        # A vertex placed exactly cannot be a positional failure, whatever the
        # reference put there.
        if unresolved == 0 and worst['engine'] <= worst['reference']:
            result['pass'] = result['pass_area']
    if g.is_empty != ref.is_empty:
        result['pass'] = False
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--reuse-external', action='store_true', help='Reuse existing JS/Rust outputs, for report development only')
    parser.add_argument('--strict', action='store_true', help='Nonzero exit on any comparison failure, including domain-limit probes')
    args = parser.parse_args()
    if args.repeats < 1: parser.error('--repeats must be positive')
    os.chdir(ROOT)
    OUT.mkdir(parents=True, exist_ok=True)
    fixture = prepare(args.source)
    fixture_path = OUT/'fixtures.json'
    fixture_path.write_text(json.dumps(fixture,separators=(',',':')))
    if not args.reuse_external:
        subprocess.run(['node','tests/compare/js.mjs',str(fixture_path),str(OUT/'js.json'),str(args.repeats)], check=True, timeout=900)
    external = json.loads((OUT/'js.json').read_text())
    natives = {'zig-native': Native()}
    rows = []
    for c in fixture['cases']:
        gs = [shape(g) for g in c['geometries']]
        def geos():
            united = shapely.union_all(gs)
            return united if c['operation']=='union' else united.buffer(c['distance'],quad_segs=c['steps'])
        ref, times = measure(geos, args.repeats)
        if not ref.is_valid: raise RuntimeError(f'Invalid GEOS reference: {c["id"]}')
        rows.append(dict(id=c['id'],engine='geos',times_ms=times,timing='geometry-in/out',**metrics(ref,ref,c)))
        blob = shapely.to_wkb(MultiPolygon([p for g in gs for p in parts(g)]),byte_order=1)
        for name, native in natives.items():
            try:
                output, times = measure(lambda:native.run(blob,c), args.repeats)
                g = shapely.from_wkb(output)
                rows.append(dict(id=c['id'],engine=name,times_ms=times,timing='wkb-in/out + host copy',**metrics(g,ref,c)))
            except Exception as e:
                rows.append(dict(id=c['id'],engine=name,error=str(e),**{'pass':False}))
        for r in (r for r in external if r['id']==c['id']):
            r = dict(r)
            if 'error' in r: r['pass']=False
            else:
                try: r.update(metrics(shape(r.pop('geometry')),ref,c))
                except Exception as e: r.update(error=str(e),**{'pass':False})
            rows.append(r)
    for row in rows:
        if 'times_ms' in row:
            row['median_ms'] = statistics.median(row['times_ms'])
            row['p95_ms'] = sorted(row['times_ms'])[math.ceil(.95*len(row['times_ms']))-1]
    report = dict(metadata=fixture['metadata'], environment=dict(platform=platform.platform(),machine=platform.machine(),
        python=platform.python_version(), geos=shapely.geos_version_string, shapely=shapely.__version__,
        node=subprocess.check_output(['node','--version'],text=True).strip(),
        zig=subprocess.check_output(['zig','version'],text=True).strip(),
        rust=subprocess.check_output(['rustc','--version'],text=True).strip(),
        polyclip_ts='0.16.8', turf='7.4.0', jsts='2.12.1', rust_geo='0.33.1',
        repeats=args.repeats, reused_external=args.reuse_external), results=rows)
    (OUT/'report.json').write_text(json.dumps(report,indent=2))
    engines=['zig-native','zig-wasm','jsts','polyclip-ts','turf','rust-geo','geos']
    lines=['# Measured engine comparison','', 'Median milliseconds; timing boundaries differ (see README).', '',
           '| Case | '+' | '.join(engines)+' |','| --- | '+' | '.join(['---:']*len(engines))+' |']
    for c in fixture['cases']:
        selected={r['engine']:r for r in rows if r['id']==c['id']}
        cells=[]
        for engine in engines:
            r=selected.get(engine)
            cells.append('—' if r is None else 'ERROR' if 'error' in r else f'{r["median_ms"]:.3f}'+(' ⚠' if not r['pass'] else ''))
        lines.append('| '+c['id']+' | '+' | '.join(cells)+' |')
    lines += ['', '## Failed checks / domain limits', '']
    failed=[r for r in rows if not r['pass']]
    for r in failed:
        detail=r.get('error',r.get('validity') if not r.get('valid') else f"symdiff={r.get('symdiff_area')}, Hausdorff={r.get('boundary_hausdorff')}")
        lines.append(f'- {r["engine"]} / {r["id"]}: {detail}')
    (OUT/'report.md').write_text('\n'.join(lines)+'\n')
    print('\n'.join(lines))
    if args.strict and failed: raise SystemExit(1)

if __name__ == '__main__': main()
