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

// `vertexValid` is zero at exactly the last vertex of each ring.
assert.equal(binary.attributes.vertexValid.length, result.coordinates.length / 2);
const zeros = [...binary.attributes.vertexValid].flatMap((v, i) => (v === 0 ? [i] : []));
assert.deepEqual(
  zeros,
  Array.from(result.ringEnds, (end) => end - 1),
);

// The positions are the library's own array rather than a rebuild of it. This
// is the claim the demo makes, so it is worth asserting rather than describing.
assert.equal(binary.attributes.getPolygon.value, result.coordinates);
assert.equal(binary.attributes.getPolygon.size, 2);

console.log('deck.gl binary checks passed (startIndices, vertexValid, zero-copy positions)');
