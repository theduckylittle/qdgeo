// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The deck.gl binary conversion the library ships as `qdgeo/deck`.
//
// Get `startIndices` or `vertexValid` wrong and deck.gl renders a plausible,
// wrong polygon with no error anywhere. The assertions below are deck.gl's own
// documented contract for SolidPolygonLayer, and `examples/src/deckgl.jsx`
// imports exactly what is checked here.
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { describe, expect, test } from 'vitest';

import { load } from '../js/qdgeo.js';
import { toBinary, toOutline } from '../js/deck.js';
import { nestedArea } from './support/area.mjs';

const geo = await load();

const square = (x, y, w) => [
  [
    [x, y],
    [x + w, y],
    [x + w, y + w],
    [x, y + w],
    [x, y],
  ],
];
// A donut is the interesting case: one polygon, two rings, so `vertexValid` is
// what tells deck.gl where the hole starts.
const donut = [
  [
    [0, 0],
    [30, 0],
    [30, 30],
    [0, 30],
    [0, 0],
  ],
  [
    [10, 10],
    [10, 20],
    [20, 20],
    [20, 10],
    [10, 10],
  ],
];

const result = geo.union([donut, square(50, 0, 10)]);
const binary = toBinary(result);

describe('the geometry under test', () => {
  test('is a donut beside a square', () => {
    expect(result.length, 'two disjoint polygons').toBe(2);
    expect(result.ringEnds.length, 'three rings, one of them a hole').toBe(3);
  });
});

describe('toBinary, against SolidPolygonLayer’s contract', () => {
  test('startIndices has length + 1 entries, from zero to the vertex total', () => {
    expect(binary.length).toBe(result.length);
    expect(binary.startIndices.length).toBe(result.length + 1);
    expect(binary.startIndices[0]).toBe(0);
    expect(binary.startIndices.at(-1)).toBe(result.coordinates.length / 2);
  });

  test('and never decreases, with every entry on a ring boundary', () => {
    for (let i = 1; i < binary.startIndices.length; i++) {
      expect(binary.startIndices[i]).toBeGreaterThanOrEqual(binary.startIndices[i - 1]);
    }
    const boundaries = new Set([0, ...result.ringEnds]);
    for (const start of binary.startIndices) {
      expect(boundaries.has(start), `startIndex ${start} is not a ring boundary`).toBe(true);
    }
  });

  // The name and the wrapper both matter: `SolidPolygonLayer` reads
  // `props.data.attributes.instanceVertexValid.value` and ignores anything
  // else, so getting either wrong renders nothing and reports no error.
  test('instanceVertexValid is a { size, value } pair holding a Uint16Array', () => {
    expect(binary.attributes.instanceVertexValid.value).toBeInstanceOf(Uint16Array);
    expect(binary.attributes.instanceVertexValid.size).toBe(1);
    expect(binary.attributes.instanceVertexValid.value.length).toBe(result.coordinates.length / 2);
  });

  test('and is zero at exactly the last vertex of each ring', () => {
    const zeros = [...binary.attributes.instanceVertexValid.value].flatMap((v, i) =>
      v === 0 ? [i] : [],
    );
    expect(zeros).toEqual(Array.from(result.ringEnds, (end) => end - 1));
  });

  // This is the claim the demo makes, so it is worth asserting rather than
  // describing.
  test('the positions are the library’s own array rather than a rebuild of it', () => {
    expect(binary.attributes.getPolygon.value).toBe(result.coordinates);
    expect(binary.attributes.getPolygon.size).toBe(2);
  });
});

// The outline is the same positions cut into rings rather than polygons, for
// the `PathLayer` that strokes the result.
describe('toOutline, against PathLayer’s contract', () => {
  const outline = toOutline(result);

  test('is one path per ring, plus a final total', () => {
    expect(outline.length, 'one path per ring').toBe(result.ringEnds.length);
    expect(outline.startIndices.length).toBe(result.ringEnds.length + 1);
    expect(outline.startIndices[0]).toBe(0);
    expect(outline.startIndices.at(-1)).toBe(result.coordinates.length / 2);
    expect([...outline.startIndices.slice(1)]).toEqual([...result.ringEnds]);
  });

  test('and shares the same positions', () => {
    expect(outline.attributes.getPath.value, 'no copy here either').toBe(result.coordinates);
    expect(outline.attributes.getPath.size).toBe(2);
  });
});

// Structure is necessary but not sufficient: the reason this test exists is
// that a wrong attribute name renders nothing and reports no error. So run
// deck.gl's own tesselator over the binary and check the triangles it produces
// cover the same area as the geometry. That needs the examples' dependencies,
// which CI installs before this runs; skip rather than fail without them.
const tesselatorPath =
  '../examples/node_modules/@deck.gl/layers/dist/solid-polygon-layer/polygon-tesselator.js';
const haveDeck = existsSync(new URL(tesselatorPath, import.meta.url));
// CI installs `examples/` before this runs, so a skip there means the workflow
// changed rather than that the adapter is genuinely untestable. Say so.
if (!haveDeck && process.env.CI)
  throw new Error('deck.gl is missing: CI must run `npm --prefix examples ci` before `npm test`');

// A skipped suite still has its body collected, so requiring deck.gl has to sit
// behind the branch rather than behind `skipIf`.
if (!haveDeck) {
  describe.skip('deck.gl’s own tesselator over the binary (deck.gl is not installed)', () => {
    test('needs `npm --prefix examples ci`', () => {});
  });
} else {
  describe('deck.gl’s own tesselator over the binary', () => {
    const PolygonTesselator = createRequire(import.meta.url)(tesselatorPath).default;

    // Exactly the call `SolidPolygonLayer.updateGeometry` makes.
    const tesselate = (data) => {
      const t = new PolygonTesselator({
        data,
        normalize: false,
        geometryBuffer: data.attributes.getPolygon,
        buffers: data.attributes,
        positionFormat: 'XY',
        fp64: false,
      });
      const indices = t.get('indices');
      const positions = t.get('positions');
      let covered = 0;
      for (let i = 0; i < indices.length; i += 3) {
        const [x, y, z] = [indices[i] * 3, indices[i + 1] * 3, indices[i + 2] * 3];
        covered +=
          Math.abs(
            (positions[y] - positions[x]) * (positions[z + 1] - positions[x + 1]) -
              (positions[z] - positions[x]) * (positions[y + 1] - positions[x + 1]),
          ) / 2;
      }
      return { triangles: indices.length / 3, covered };
    };

    test.for([
      ['a donut beside a square', () => result],
      ['a buffered square', () => geo.buffer([square(50, 0, 10)], 4)],
      ['an eroded donut', () => geo.buffer([donut], -2)],
    ])('covers the right area for %s', ([label, build]) => {
      const geometry = build();
      const { triangles, covered } = tesselate(toBinary(geometry));
      const want = nestedArea(geometry.toArrays());
      expect(triangles, `${label}: deck.gl produced no triangles`).toBeGreaterThan(0);
      expect(
        Math.abs(covered - want),
        `${label}: triangles cover ${covered}, geometry is ${want}`,
      ).toBeLessThan(Math.max(0.01, 0.001 * want));
    });
  });
}
