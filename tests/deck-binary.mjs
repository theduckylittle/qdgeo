// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The deck.gl binary conversion the demo publishes.
//
// It is example code, but it is the one piece with invariants a browser will
// not complain about: get `startIndices` or `vertexValid` wrong and deck.gl
// renders a plausible, wrong polygon. The assertions below are deck.gl's own
// documented contract for SolidPolygonLayer.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

globalThis.fetch = async (url) => ({
  ok: true,
  status: 200,
  arrayBuffer: async () => readFileSync(url).buffer,
});
const { load } = await import('../js/qdgeo.js');
const { toBinary } = await import('../examples/src/deck-binary.js');
const geo = await load('zig-out/bin/qdgeo.wasm');

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

assert.equal(result.length, 2, 'two disjoint polygons');
assert.equal(result.ringEnds.length, 3, 'three rings, one of them a hole');

// `startIndices` has length + 1 entries, starts at zero, ends at the vertex
// total, never decreases, and every entry lands on a ring boundary.
assert.equal(binary.length, result.length);
assert.equal(binary.startIndices.length, result.length + 1);
assert.equal(binary.startIndices[0], 0);
assert.equal(binary.startIndices.at(-1), result.coordinates.length / 2);
for (let i = 1; i < binary.startIndices.length; i++) {
  assert.ok(binary.startIndices[i] >= binary.startIndices[i - 1]);
}
const boundaries = new Set([0, ...result.ringEnds]);
for (const start of binary.startIndices) {
  assert.ok(boundaries.has(start), `startIndex ${start} is not a ring boundary`);
}

// `instanceVertexValid` is zero at exactly the last vertex of each ring, and is
// a `{ size, value }` pair holding a Uint16Array. The name and the wrapper both
// matter: `SolidPolygonLayer` reads
// `props.data.attributes.instanceVertexValid.value` and ignores anything else,
// so getting either wrong renders nothing and reports no error.
assert.ok(binary.attributes.instanceVertexValid.value instanceof Uint16Array);
assert.equal(binary.attributes.instanceVertexValid.size, 1);
assert.equal(binary.attributes.instanceVertexValid.value.length, result.coordinates.length / 2);
const zeros = [...binary.attributes.instanceVertexValid.value].flatMap((v, i) =>
  v === 0 ? [i] : [],
);
assert.deepEqual(
  zeros,
  Array.from(result.ringEnds, (end) => end - 1),
);

// The positions are the library's own array rather than a rebuild of it. This
// is the claim the demo makes, so it is worth asserting rather than describing.
assert.equal(binary.attributes.getPolygon.value, result.coordinates);
assert.equal(binary.attributes.getPolygon.size, 2);

// Structure is necessary but not sufficient: the reason this test exists is
// that a wrong attribute name renders nothing and reports no error. So run
// deck.gl's own tesselator over the binary and check the triangles it produces
// cover the same area as the geometry. That needs the examples' dependencies,
// which CI installs before this runs; skip rather than fail without them.
const { existsSync } = await import('node:fs');
const { createRequire } = await import('node:module');
const tesselatorPath =
  '../examples/node_modules/@deck.gl/layers/dist/solid-polygon-layer/polygon-tesselator.js';
const require = createRequire(import.meta.url);

if (!existsSync(new URL(tesselatorPath, import.meta.url))) {
  console.log('deck.gl binary checks passed (structure only — deck.gl not installed)');
} else {
  const PolygonTesselator = require(tesselatorPath).default;

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

  const shapeArea = (r) =>
    r.toArrays().reduce(
      (total, shape) =>
        total +
        shape.reduce((sum, ring) => {
          let a = 0;
          for (let i = 0; i < ring.length - 1; i++) {
            a += ring[i][0] * ring[i + 1][1] - ring[i][1] * ring[i + 1][0];
          }
          return sum + a / 2;
        }, 0),
      0,
    );

  for (const [label, geometry] of [
    ['a donut beside a square', result],
    ['a buffered square', geo.buffer([square(50, 0, 10)], 4)],
    ['an eroded donut', geo.buffer([donut], -2)],
  ]) {
    const { triangles, covered } = tesselate(toBinary(geometry));
    const want = shapeArea(geometry);
    assert.ok(triangles > 0, `${label}: deck.gl produced no triangles`);
    assert.ok(
      Math.abs(covered - want) < Math.max(0.01, 0.001 * want),
      `${label}: triangles cover ${covered}, geometry is ${want}`,
    );
  }

  console.log(
    'deck.gl binary checks passed (structure, and deck.gl tesselates it to the right area)',
  );
}
