# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Committed-fixture probes for the reduced failures; prints facts, repairs nothing.

Grid sweeps are gone: qdgeo is floating precision only and has no precision
option at all, so what is worth probing now is which degeneracies it survives.
"""
import json
from pathlib import Path
import shapely
from shapely.geometry import shape, MultiPolygon
from run import Native, OUT, parts

native = Native()
rows = []
for path in sorted((Path(__file__).parent / 'fixtures').glob('*.json')):
    c = json.loads(path.read_text())
    gs = [shape(g) for g in c['geometries']]
    blob = shapely.to_wkb(MultiPolygon([p for g in gs for p in parts(g)]), byte_order=1)
    reference = shapely.union_all(gs)
    if c['operation'] != 'union':
        reference = reference.buffer(c['distance'], quad_segs=c['steps'])
    row = dict(fixture=c['id'], operation=c['operation'], distance=c['distance'],
               rows=c['rows'], input_valid=all(g.is_valid for g in gs))
    try:
        output = shapely.from_wkb(native.run(blob, c))
        row.update(status='ok', output_valid=bool(output.is_valid),
                   reason=shapely.is_valid_reason(output),
                   symdiff_area=float(output.symmetric_difference(reference).area))
    except Exception as error:
        row.update(status=str(error))
    rows.append(row)
print(json.dumps(rows, indent=2))
OUT.mkdir(parents=True, exist_ok=True)
(OUT / 'probes.json').write_text(json.dumps(rows, indent=2))
