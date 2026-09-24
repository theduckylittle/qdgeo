// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//
// The JTS Topology Suite's own test cases, run against the shipped WASM
// artifact through the shipped binding.
//
// The XML in `cases/` is JTS's, copied verbatim (see `cases/NOTICE.md`), so
// that "passes the JTS suite" means the actual suite and not a paraphrase of
// it. The reference side — WKT reading, topological equality, area, boundary
// Hausdorff — is JSTS, which is JTS itself ported to JavaScript. Using JTS to
// check a claim about JTS is the point: the matcher constants below are the
// ones `BufferResultMatcher` uses, and `DiscreteHausdorffDistance` is the class
// it uses, rather than a second implementation of the same idea.
//
// Two comparison rules, matching what JTS itself applies:
//
//   * **Overlay** results must be topologically equal to the expected geometry.
//     Overlay is exact, so there is nothing to tolerate.
//   * **Buffer** results are compared the way `TestBuffer.xml` asks for in its
//     own `<resultMatcher>` element, which names `BufferResultMatcher` —
//     tolerance-based, because a rounded buffer is an approximation whose
//     vertices depend on the implementation.
//
// Buffers run at `quadrantSegments = 8`, which is JTS's default and therefore
// what the expected geometry in `TestBuffer.xml` was generated with. At qdgeo's
// own default of 16 the arcs are finer than JTS's and the area difference alone
// exceeds the matcher's tolerance. Finer is not closer here.
//
// Cases whose expected result is not areal are **skipped, not passed**: qdgeo
// returns polygons only, by design, and counting them as passes would inflate
// the number that gets quoted.
import { describe, expect, test } from 'vitest';
import 'jsts/org/locationtech/jts/monkey.js';
import WKTReader from 'jsts/org/locationtech/jts/io/WKTReader.js';
import GeoJSONReader from 'jsts/org/locationtech/jts/io/GeoJSONReader.js';
import DiscreteHausdorffDistance from 'jsts/org/locationtech/jts/algorithm/distance/DiscreteHausdorffDistance.js';

import { load, OP } from '../../js/qdgeo.js';
import { caseFiles } from './cases.mjs';

// JTS BufferResultMatcher, verbatim.
const MIN_DISTANCE_TOLERANCE = 1.0e-8;
const MAX_RELATIVE_AREA_DIFFERENCE = 1.0e-3;
const MAX_HAUSDORFF_DISTANCE_FACTOR = 100;
const DENSIFY_FRACTION = 0.25;
const QUADRANT_SEGMENTS = 8;

// qdgeo refuses degenerate input rather than repairing it. JTS's buffer builder
// collapses a zero-area ring and carries on; ours reports `malformed geometry`.
// That is a deliberate policy difference, so the cases are named here instead
// of being absorbed into a pass count — `test.fails` asserts they still fail,
// and says so loudly if one of them starts passing.
const POLICY_FAILURES = new Set([
  // POLYGON ((-69 -90, -69 -90, ... )) — twelve copies of one point.
  'TestBuffer.xml :: Degenerate polygon which caused error in ver 1.10 :: buffer 0.0',
  // POLYGON ((100 100, 200 100, 200 100, 100 100)) — a ring with no area.
  'TestBuffer.xml :: Degenerate polygon - ring is flat. This case tests a fix made in ver 1.12 :: buffer 0.0',
  'TestBuffer.xml :: Degenerate polygon - ring is flat. This case tests a fix made in ver 1.12 :: buffer 10.0',
]);

const OPS = {
  union: OP.union,
  intersection: OP.intersection,
  difference: OP.difference,
  symdifference: OP.symmetricDifference,
  buffer: OP.buffer,
};

const wkt = new WKTReader();
const geojson = new GeoJSONReader();
const EMPTY = wkt.read('MULTIPOLYGON EMPTY');
const geo = await load();

function* explode(g) {
  const type = g.getGeometryType();
  if (type.startsWith('Multi') || type === 'GeometryCollection') {
    for (let i = 0; i < g.getNumGeometries(); i++) yield* explode(g.getGeometryN(i));
  } else yield g;
}

const ringOf = (line) => line.getCoordinates().map((c) => [c.x, c.y]);

/** A JSTS geometry as the binding's operand form: points, lines and polygons. */
function operand(g) {
  const points = [];
  const lines = [];
  const polygons = [];
  for (const part of explode(g)) {
    if (part.isEmpty()) continue;
    const type = part.getGeometryType();
    if (type === 'Point') points.push([part.getCoordinate().x, part.getCoordinate().y]);
    else if (type === 'LineString' || type === 'LinearRing') lines.push(ringOf(part));
    else if (type === 'Polygon') {
      const rings = [ringOf(part.getExteriorRing())];
      for (let i = 0; i < part.getNumInteriorRing(); i++)
        rings.push(ringOf(part.getInteriorRingN(i)));
      polygons.push(rings);
    } else throw new Error(`unsupported part ${type}`);
  }
  return { points, lines, polygons };
}

const toJsts = (result) => {
  const coordinates = result.toArrays();
  return coordinates.length === 0 ? EMPTY : geojson.read({ type: 'MultiPolygon', coordinates });
};

const areal = (g) =>
  g.isEmpty() || g.getGeometryType() === 'Polygon' || g.getGeometryType() === 'MultiPolygon';

/** JTS BufferResultMatcher: relative symmetric-difference area, then boundary Hausdorff. */
function bufferMismatch(actual, expected, distance) {
  if (actual.isEmpty() && expected.isEmpty()) return '';
  if (actual.isEmpty() !== expected.isEmpty()) return 'one side empty';
  const larger = Math.max(actual.getArea(), expected.getArea());
  if (larger > 0) {
    const difference = actual.symDifference(expected).getArea();
    if (difference > MAX_RELATIVE_AREA_DIFFERENCE * larger)
      return `area diff ${(difference / larger).toExponential(2)} relative`;
  }
  const tolerance = Math.max(
    Math.abs(distance) / MAX_HAUSDORFF_DISTANCE_FACTOR,
    MIN_DISTANCE_TOLERANCE,
  );
  const hausdorff = new DiscreteHausdorffDistance(actual.getBoundary(), expected.getBoundary());
  hausdorff.setDensifyFraction(DENSIFY_FRACTION);
  const separation = hausdorff.orientedDistance();
  if (separation > tolerance)
    return `boundary Hausdorff ${separation.toExponential(3)} > ${tolerance.toExponential(3)}`;
  return '';
}

function overlayMismatch(actual, expected) {
  if (actual.isEmpty() && expected.isEmpty()) return '';
  if (actual.equalsTopo(expected)) return '';
  return `not topologically equal (symdiff area ${actual.symDifference(expected).getArea().toExponential(3)})`;
}

for (const { name, cases } of caseFiles()) {
  describe(name, () => {
    for (const source of cases) {
      describe(source.desc, () => {
        // JTS's own WKTReader refuses a LinearRing with fewer than four points,
        // so a case built on one never loads. That is JTS's answer to the
        // input, not a qdgeo result, and it is reported as a skip.
        let operands;
        let unreadable;
        try {
          operands = Object.fromEntries(
            ['a', 'b'].filter((k) => source[k]).map((k) => [k, wkt.read(source[k])]),
          );
        } catch (error) {
          unreadable = String(error.message ?? error);
        }

        for (const { attributes, expected: raw } of source.tests) {
          // `intersectionNG` and friends are the OverlayNG spelling of the
          // same operation.
          const spelling = attributes.name;
          const op = spelling.endsWith('NG')
            ? spelling.slice(0, -2).toLowerCase()
            : spelling.toLowerCase();
          const label = op === 'buffer' ? `${spelling} ${attributes.arg2}` : spelling;
          const skip = (why) => test.skip(`${label} — ${why}`, () => {});

          if (unreadable) {
            skip(`input rejected by JTS's own WKT reader: ${unreadable}`);
            continue;
          }
          if (!(op in OPS)) {
            skip('operation not implemented');
            continue;
          }
          let expected;
          try {
            expected = wkt.read(raw);
          } catch (error) {
            skip(`unreadable expected result: ${error.message ?? error}`);
            continue;
          }
          if (!areal(expected)) {
            skip(`expected ${expected.getGeometryType()}, and qdgeo returns areal output only`);
            continue;
          }

          const first = operands[(attributes.arg1 ?? 'A').toLowerCase()];
          let run;
          if (op === 'buffer') {
            const distance = Number(attributes.arg2);
            run = () => {
              const actual = toJsts(
                geo.apply(OP.buffer, operand(first), [], { distance, steps: QUADRANT_SEGMENTS }),
              );
              expect(bufferMismatch(actual, expected, distance)).toBe('');
            };
          } else {
            const second = operands[(attributes.arg2 ?? 'B').toLowerCase()];
            if (!areal(first) || !areal(second)) {
              skip('non-areal operand for a boolean operation');
              continue;
            }
            run = () => {
              const actual = toJsts(
                geo.apply(OPS[op], operand(first).polygons, operand(second).polygons),
              );
              expect(overlayMismatch(actual, expected)).toBe('');
            };
          }

          // A policy failure is asserted to fail. If qdgeo ever accepts one of
          // these, this reports it as an unexpected pass rather than letting a
          // baseline count drift silently.
          const key = `${name} :: ${source.desc} :: ${op === 'buffer' ? `buffer ${attributes.arg2}` : spelling}`;
          (POLICY_FAILURES.has(key) ? test.fails : test)(label, run);
        }
      });
    }
  });
}
