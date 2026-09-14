# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Geometry-only fixtures. Never exports parcel owner/address/tax attributes."""
import hashlib
import json
from pathlib import Path
import pyarrow.parquet as pq
from pyproj import CRS, Transformer
import shapely
from shapely.geometry import Polygon, box, mapping

DEFAULT_SOURCE = Path(__file__).parent / 'data' / 'parcels.geoparquet'

def prepare(source=DEFAULT_SOURCE):
    # Public data, fetched on first use, so the published numbers reproduce.
    if source == DEFAULT_SOURCE and not source.exists():
        from fetch import fetch
        fetch(source)
    meta = json.loads(pq.read_metadata(source).metadata[b'geo'])
    col = meta['primary_column']
    desc = meta['columns'][col]
    if desc['encoding'] != 'WKB':
        raise ValueError('Only WKB GeoParquet is supported')
    crs = CRS.from_user_input(desc.get('crs', 'OGC:CRS84'))
    blobs = pq.read_table(source, columns=[col])[col].to_pylist()
    gs = shapely.from_wkb(blobs)
    if not all(shapely.is_valid(gs)) or any(shapely.is_empty(gs)):
        raise ValueError('Input has invalid, null or empty geometries; do not silently repair/skip')
    if any(g.geom_type not in ('Polygon', 'MultiPolygon') for g in gs):
        raise ValueError('Expected polygonal parcels')
    to_wgs = Transformer.from_crs(crs, 'OGC:CRS84', always_xy=True)
    wgs = shapely.transform(gs, to_wgs.transform, interleaved=False)
    bounds = shapely.total_bounds(wgs)
    lon, lat = (bounds[0]+bounds[2])/2, (bounds[1]+bounds[3])/2
    # Same spherical radius used by Turf. Keeps projection-vs-ellipsoid differences
    # out of the algorithm comparison; this is NOT an official cadastral CRS.
    local = f'+proj=aeqd +lon_0={lon} +lat_0={lat} +R=6371008.8 +units=m +no_defs'
    project = Transformer.from_crs('OGC:CRS84', local, always_xy=True)
    gs = shapely.orient_polygons(shapely.transform(wgs, project.transform, interleaved=False))
    if not all(shapely.is_valid(gs)):
        raise ValueError('Projection changed input validity')
    # Spatially clustered, stable selection. Source row ids remain in the manifest.
    centers = shapely.centroid(gs)
    order = sorted(range(len(gs)), key=lambda i: (centers[i].x**2 + centers[i].y**2, i))
    cases = []
    def add(name, geometries, operation='union', distance=0, rows=None):
        geometries = [shapely.orient_polygons(g) for g in geometries]
        cases.append(dict(id=name, operation=operation, distance=distance, steps=16,
                          rows=rows, input_points=int(sum(shapely.get_num_coordinates(g) for g in geometries)),
                          geometries=[mapping(g) for g in geometries]))
    for size in (10, 100, 1000, len(gs)):
        indices = order[:size]
        add(f'parcels-union-{size}', [gs[i] for i in indices], rows=indices)
    for size in (1, 100):
        indices = order[:size]
        for d in (2, 10, -2, -10):
            add(f'parcels-buffer-{size}-{d:+}', [gs[i] for i in indices], 'buffer', d, indices)
    complex_index = max(range(len(gs)), key=lambda i: shapely.get_num_coordinates(gs[i]))
    for d in (2, -2):
        add(f'complex-parcel-buffer-{d:+}', [gs[complex_index]], 'buffer', d, [complex_index])
    add('sloped-overlap', [Polygon([(0,0),(4,0),(2,4)]), Polygon([(1,-1),(5,-1),(3,3)])])
    add('edge-point-contact', [box(0,0,2,2), box(2,0,4,2), box(4,2,6,4)])
    donut = Polygon(box(0,0,20,20).exterior.coords, [box(2,2,18,18).exterior.coords])
    island = Polygon(box(4,4,16,16).exterior.coords, [box(6,6,14,14).exterior.coords])
    add('nested-island-hole', [donut, island])
    for d in (1, -1, -20):
        add(f'donut-buffer-{d:+}', [donut], 'buffer', d)
    # Erosion splits the narrow connecting neck.
    neck = shapely.union_all([box(0,0,4,4), box(4,1.8,8,2.2), box(8,0,12,4)])
    add('neck-split', [neck], 'buffer', -0.3)
    # Valid finite inputs that sit at the edges of the floating-point domain.
    add('subgrid-sliver', [box(0,0,1e-10,1)])
    add('near-coincident', [box(0,0,1,1), box(1-2e-9,0,2,1)])
    add('large-origin', [box(1e9,1e9,1e9+2,1e9+2), box(1e9+1,1e9+1,1e9+3,1e9+3)])
    add('range-limit', [box(0,0,1e8,1)])
    cases.append(json.loads((Path(__file__).parent/'fixtures/parcel-invalid-union.json').read_text()))
    return dict(metadata=dict(source=str(source), sha256=hashlib.sha256(Path(source).read_bytes()).hexdigest(),
                              rows=len(gs), points=int(sum(shapely.get_num_coordinates(gs))),
                              source_crs=crs.to_string(), projection=local, center=[lon,lat],
                              all_inputs_valid=True), cases=cases)

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--out', type=Path, default=Path('tests/compare/generated/fixtures.json'))
    args = parser.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(prepare(args.source), separators=(',', ':')))
    print(args.out)
