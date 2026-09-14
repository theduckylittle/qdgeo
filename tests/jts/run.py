# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Dan "Ducky" Little
"""Run the JTS Topology Suite's own test cases against qdgeo.

The XML in `cases/` is JTS's, copied verbatim (see `cases/NOTICE.md`), so that
"passes the JTS suite" means the actual suite and not a paraphrase of it.

Two comparison rules, matching what JTS itself uses:

* **Overlay** results must be topologically equal to the expected geometry.
  Overlay is exact, so there is nothing to tolerate.
* **Buffer** results are compared the way `TestBuffer.xml` asks for in its own
  `<resultMatcher>` element: JTS names `BufferResultMatcher`, which is
  tolerance-based because a rounded buffer is an approximation whose vertices
  depend on the implementation. This runner applies the same two tests that
  class applies — symmetric-difference area relative to the larger input, and
  boundary Hausdorff distance scaled by the buffer distance. The constants below
  are JTS's.

Buffers run at `quadrantSegments = 8`, which is JTS's default and therefore what
the expected geometry in `TestBuffer.xml` was generated with. At qdgeo's own
default of 16 the arcs are finer than JTS's and the area difference alone
exceeds the matcher's tolerance.

Cases whose expected result is not areal are **skipped, not passed**: qdgeo
returns polygons only, by design. They are counted and listed separately so the
number that gets quoted is never inflated by them.
"""
import argparse
import ctypes as C
import json
import math
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import shapely
from shapely import wkt as shapely_wkt

HERE = Path(__file__).parent
ROOT = HERE.parent.parent
LIBRARY = ROOT / 'zig-out/lib/libqdgeo_native.so'

# JTS BufferResultMatcher.
MIN_DISTANCE_TOLERANCE = 1.0e-8
MAX_RELATIVE_AREA_DIFFERENCE = 1.0e-3
MAX_HAUSDORFF_DISTANCE_FACTOR = 100
QUADRANT_SEGMENTS = 8

OPS = {'union': 0, 'intersection': 1, 'difference': 2, 'symdifference': 3, 'buffer': 4}
STATUS = {
    1: 'allocation failed',
    2: 'unsupported geometry',
    3: 'limit exceeded',
    4: 'coordinate out of range',
    5: 'malformed geometry or overlay failure',
    6: 'invalid options',
}


class Qdgeo:
    """The flat ABI, through ctypes. Same entry points the browser uses."""

    def __init__(self, path=LIBRARY):
        if not path.exists():
            sys.exit(f'{path} is missing — run: zig build native -Doptimize=ReleaseSafe')
        self.lib = C.CDLL(str(path))
        self.lib.geom_flat_input.restype = C.c_void_p
        self.lib.geom_flat_input.argtypes = [C.c_uint32] * 5
        self.lib.geom_flat_execute.restype = C.c_uint32
        self.lib.geom_flat_execute.argtypes = [C.c_uint32, C.c_uint32, C.c_double, C.c_uint32]
        self.lib.geom_flat_result_ptr.restype = C.c_void_p
        for name in ('coordinates', 'rings', 'polygons'):
            getattr(self.lib, f'geom_flat_result_{name}').restype = C.c_uint32

    def run(self, parts, op, subject=0, distance=0.0, steps=QUADRANT_SEGMENTS):
        """`parts` is (points, lines, polygons) in the flat block's own order."""
        points, lines, polygons = parts
        coordinates = list(points)
        line_ends = []
        for line in lines:
            coordinates.extend(line)
            line_ends.append(len(coordinates))
        ring_ends, polygon_ends = [], []
        for rings in polygons:
            for ring in rings:
                coordinates.extend(ring)
                ring_ends.append(len(coordinates))
            polygon_ends.append(len(ring_ends))

        total = len(coordinates)
        block = self.lib.geom_flat_input(
            total, len(ring_ends), len(polygon_ends), len(line_ends), len(points)
        )
        if not block and total:
            raise RuntimeError('input allocation failed')
        if total:
            flat = (C.c_double * (2 * total)).from_address(block)
            for i, (x, y) in enumerate(coordinates):
                flat[2 * i], flat[2 * i + 1] = x, y
            count = len(ring_ends) + len(polygon_ends) + len(line_ends)
            indices = (C.c_uint32 * count).from_address(block + 16 * total)
            for i, v in enumerate(ring_ends + polygon_ends + line_ends):
                indices[i] = v

        status = self.lib.geom_flat_execute(OPS[op], subject, distance, steps)
        if status:
            raise RuntimeError(STATUS.get(status, f'status {status}'))
        return self._result()

    def _result(self):
        total = self.lib.geom_flat_result_coordinates()
        rings = self.lib.geom_flat_result_rings()
        shapes = self.lib.geom_flat_result_polygons()
        if not total:
            return shapely.from_wkt('MULTIPOLYGON EMPTY')
        base = self.lib.geom_flat_result_ptr()
        xy = (C.c_double * (2 * total)).from_address(base)
        ends = (C.c_uint32 * (rings + shapes)).from_address(base + 16 * total)
        out, ring, point = [], 0, 0
        for s in range(shapes):
            shell_and_holes = []
            while ring < ends[rings + s]:
                coords = []
                while point < ends[ring]:
                    coords.append((xy[2 * point], xy[2 * point + 1]))
                    point += 1
                shell_and_holes.append(coords)
                ring += 1
            out.append(shapely.Polygon(shell_and_holes[0], shell_and_holes[1:]))
        return shapely.MultiPolygon(out) if len(out) != 1 else out[0]


def parts_of(geometry):
    """Split a geometry into the flat block's (points, lines, polygons)."""
    points, lines, polygons = [], [], []
    for g in _explode(geometry):
        kind = g.geom_type
        if g.is_empty:
            continue
        if kind == 'Point':
            points.append((g.x, g.y))
        elif kind == 'LineString':
            lines.append(list(g.coords))
        elif kind == 'LinearRing':
            lines.append(list(g.coords))
        elif kind == 'Polygon':
            polygons.append([list(g.exterior.coords)] + [list(r.coords) for r in g.interiors])
        else:
            raise ValueError(f'unsupported part {kind}')
    return points, lines, polygons


def _explode(geometry):
    if geometry.geom_type.startswith('Multi') or geometry.geom_type == 'GeometryCollection':
        for g in geometry.geoms:
            yield from _explode(g)
    else:
        yield geometry


def areal(geometry):
    return geometry.is_empty or geometry.geom_type in ('Polygon', 'MultiPolygon')


def buffer_matches(actual, expected, distance):
    """JTS BufferResultMatcher: symmetric-difference area, then boundary Hausdorff."""
    if actual.is_empty and expected.is_empty:
        return True, ''
    if actual.is_empty != expected.is_empty:
        return False, 'one side empty'
    larger = max(actual.area, expected.area)
    if larger > 0:
        difference = actual.symmetric_difference(expected).area
        if difference > MAX_RELATIVE_AREA_DIFFERENCE * larger:
            return False, f'area diff {difference / larger:.2e} rel'
    tolerance = max(abs(distance) / MAX_HAUSDORFF_DISTANCE_FACTOR, MIN_DISTANCE_TOLERANCE)
    separation = actual.boundary.hausdorff_distance(expected.boundary)
    if separation > tolerance:
        return False, f'boundary Hausdorff {separation:.3e} > {tolerance:.3e}'
    return True, ''


def overlay_matches(actual, expected):
    if actual.is_empty and expected.is_empty:
        return True, ''
    if actual.equals(expected):
        return True, ''
    difference = actual.symmetric_difference(expected).area
    return False, f'not topologically equal (symdiff area {difference:.3e})'


def run_file(path, engine, verbose=False):
    rows = []
    root = ET.parse(path).getroot()
    for index, case in enumerate(root.findall('case')):
        desc = ' '.join((case.findtext('desc') or f'case {index}').split())
        try:
            operands = {
                letter: shapely_wkt.loads(case.findtext(letter).strip())
                for letter in ('a', 'b')
                if case.findtext(letter)
            }
        except Exception as error:
            rows.append(dict(file=path.name, case=desc, op='-', status='skip',
                             reason=f'unreadable input: {error}'))
            continue

        for test in case.findall('test'):
            op_node = test.find('op')
            raw = op_node.get('name')
            name = raw[:-2].lower() if raw.endswith('NG') else raw.lower()
            if name not in OPS:
                rows.append(dict(file=path.name, case=desc, op=raw, status='skip',
                                 reason='operation not implemented'))
                continue
            row = dict(file=path.name, case=desc, op=raw)
            try:
                expected = shapely_wkt.loads((op_node.text or '').strip())
            except Exception as error:
                rows.append({**row, 'status': 'skip', 'reason': f'unreadable expected: {error}'})
                continue

            if not areal(expected):
                rows.append({**row, 'status': 'skip',
                             'reason': f'expected {expected.geom_type} — qdgeo returns areal output only'})
                continue

            try:
                if name == 'buffer':
                    source = operands[op_node.get('arg1', 'A').lower()]
                    distance = float(op_node.get('arg2'))
                    actual = engine.run(parts_of(source), 'buffer', distance=distance)
                    ok, reason = buffer_matches(actual, expected, distance)
                else:
                    first = operands[op_node.get('arg1', 'A').lower()]
                    second = operands[op_node.get('arg2', 'B').lower()]
                    if not (areal(first) and areal(second)):
                        rows.append({**row, 'status': 'skip',
                                     'reason': 'non-areal operand for a boolean operation'})
                        continue
                    _, _, left = parts_of(first)
                    _, _, right = parts_of(second)
                    actual = engine.run(([], [], left + right), name, subject=len(left))
                    ok, reason = overlay_matches(actual, expected)
            except Exception as error:
                rows.append({**row, 'status': 'fail', 'reason': f'{type(error).__name__}: {error}'})
                continue
            rows.append({**row, 'status': 'pass' if ok else 'fail', 'reason': reason})
            if verbose and not ok:
                print(f'  FAIL {path.name} :: {desc} :: {raw} — {reason}', file=sys.stderr)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', type=Path, default=HERE / 'cases')
    parser.add_argument('--json', type=Path, help='write the full row-by-row result here')
    parser.add_argument('--verbose', action='store_true')
    parser.add_argument('--strict', action='store_true', help='exit nonzero if anything fails')
    args = parser.parse_args()

    engine = Qdgeo()
    rows = []
    for path in sorted(args.cases.glob('*.xml')):
        rows.extend(run_file(path, engine, args.verbose))

    counts = {}
    for row in rows:
        per = counts.setdefault(row['file'], {'pass': 0, 'fail': 0, 'skip': 0})
        per[row['status']] += 1

    width = max(len(f) for f in counts) if counts else 10
    print(f'{"file":<{width}}  {"pass":>5} {"fail":>5} {"skip":>5}')
    for name, per in sorted(counts.items()):
        print(f'{name:<{width}}  {per["pass"]:>5} {per["fail"]:>5} {per["skip"]:>5}')
    passed = sum(p['pass'] for p in counts.values())
    failed = sum(p['fail'] for p in counts.values())
    skipped = sum(p['skip'] for p in counts.values())
    print(f'{"TOTAL":<{width}}  {passed:>5} {failed:>5} {skipped:>5}')
    run = passed + failed
    print(f'\n{passed} of {run} applicable JTS assertions pass'
          + (f' ({skipped} skipped as out of scope)' if skipped else ''))

    if failed:
        print('\nFailures:')
        for row in rows:
            if row['status'] == 'fail':
                print(f'  {row["file"]} :: {row["case"]} :: {row["op"]} — {row["reason"]}')
    if skipped and args.verbose:
        print('\nSkipped:')
        for row in rows:
            if row['status'] == 'skip':
                print(f'  {row["file"]} :: {row["case"]} :: {row["op"]} — {row["reason"]}')

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(rows, indent=2))
    return 1 if (failed and args.strict) else 0


if __name__ == '__main__':
    sys.exit(main())
