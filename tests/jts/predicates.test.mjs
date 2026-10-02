// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//
// The JTS Topology Suite's predicate cases — relate, intersects, contains and
// the rest — run against the shipped WASM artifact through the shipped
// binding. The XML is JTS's own, verbatim (see `cases/NOTICE.md`), and so are
// the expected answers: a `relate` test names the DE-9IM pattern JTS expects
// to match, and every other test names a boolean.
//
// There is nothing to tolerate here. A predicate is exact, so each case is
// either right or wrong, and the matrix a `relate` case asks for is checked
// character for character.
import { describe, expect, test } from 'vitest';
import 'jsts/org/locationtech/jts/monkey.js';
import WKTReader from 'jsts/org/locationtech/jts/io/WKTReader.js';

import { load } from '../../js/qdgeo.js';
import { caseFiles, isPredicateFile } from './cases.mjs';

// JTS's spelling of each predicate, and the binding's.
const PREDICATES = {
  relate: 'relate',
  intersects: 'intersects',
  disjoint: 'disjoint',
  contains: 'contains',
  within: 'within',
  covers: 'covers',
  coveredBy: 'coveredBy',
  touches: 'touches',
  crosses: 'crosses',
  overlaps: 'overlaps',
  equalsTopo: 'equals',
};

// qdgeo refuses invalid input rather than repairing it. Cases whose operands
// JTS's own `isValid` rejects are named here and asserted to fail, the same
// way the overlay suite names its policy failures, so that a change in the
// policy reports itself rather than drifting a count.
const POLICY_FAILURES = new Set([]);

const wkt = new WKTReader();
const geo = await load();

function* explode(g) {
  const type = g.getGeometryType();
  if (type.startsWith('Multi') || type === 'GeometryCollection') {
    for (let i = 0; i < g.getNumGeometries(); i++) yield* explode(g.getGeometryN(i));
  } else yield g;
}

const pointsOf = (line) => line.getCoordinates().map((c) => [c.x, c.y]);

/** A JSTS geometry as the binding's operand form: points, lines and polygons. */
function operand(g) {
  const points = [];
  const lines = [];
  const polygons = [];
  for (const part of explode(g)) {
    if (part.isEmpty()) continue;
    const type = part.getGeometryType();
    if (type === 'Point') points.push([part.getCoordinate().x, part.getCoordinate().y]);
    else if (type === 'LineString' || type === 'LinearRing') lines.push(pointsOf(part));
    else if (type === 'Polygon') {
      const rings = [pointsOf(part.getExteriorRing())];
      for (let i = 0; i < part.getNumInteriorRing(); i++)
        rings.push(pointsOf(part.getInteriorRingN(i)));
      polygons.push(rings);
    } else throw new Error(`unsupported part ${type}`);
  }
  return { points, lines, polygons };
}

for (const { name, cases } of caseFiles(isPredicateFile)) {
  describe(name, () => {
    for (const source of cases) {
      describe(source.desc, () => {
        let operands;
        let unreadable;
        try {
          operands = Object.fromEntries(
            ['a', 'b'].filter((k) => source[k]).map((k) => [k, wkt.read(source[k])]),
          );
        } catch (error) {
          unreadable = String(error.message ?? error);
        }

        for (const { attributes, expected } of source.tests) {
          const op = attributes.name;
          const label = op === 'relate' ? `relate ${attributes.arg3}` : op;
          const skip = (why) => test.skip(`${label} — ${why}`, () => {});
          if (unreadable) {
            skip(`input rejected by JTS's own WKT reader: ${unreadable}`);
            continue;
          }
          if (!(op in PREDICATES)) {
            skip('operation not implemented');
            continue;
          }
          const want = expected.trim() === 'true';
          const first = operand(operands[(attributes.arg1 ?? 'A').toLowerCase()]);
          const second = operand(operands[(attributes.arg2 ?? 'B').toLowerCase()]);
          const run = () => {
            if (op === 'relate') {
              expect(geo.relate(first, second, attributes.arg3)).toBe(want);
              // A fully specified pattern that is expected to match is the
              // whole matrix, so it is checked character for character too.
              if (want && !/[T*]/.test(attributes.arg3))
                expect(geo.relate(first, second)).toBe(attributes.arg3);
            } else {
              expect(geo[PREDICATES[op]](first, second)).toBe(want);
            }
          };
          const key = `${name} :: ${source.desc} :: ${label}`;
          (POLICY_FAILURES.has(key) ? test.fails : test)(label, run);
        }
      });
    }
  });
}
