// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The JavaScript binding, exercised through its named methods.
//
// `wasm.mjs` covers the raw exports; this covers `js/qdgeo.js`, which is what a
// host actually calls. The two are separate on purpose: a rename in the ABI
// should break one of them loudly rather than both vaguely.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

// The binding fetches its module, which Node will not do for a local path.
globalThis.fetch = async (url) => ({
  ok: true,
  status: 200,
  arrayBuffer: async () => readFileSync(url).buffer,
});
const { load, OP, STATUS, close, regular, star } = await import('../js/qdgeo.js');
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
const area = (shapes) =>
  shapes.reduce(
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
const near = (got, want, tolerance = 1e-9) =>
  assert.ok(Math.abs(got - want) < tolerance, `expected ${want}, got ${got}`);

const a = square(0, 0, 10);
const b = square(5, 5, 10);

near(area(geo.union([a, b])), 175);
near(area(geo.intersection([a], [b])), 25);
near(area(geo.difference([a], [b])), 75);
near(area(geo.symmetricDifference([a], [b])), 150);

// Either operand may hold several shapes. This is what the ABI's `subject`
// split buys, and why the binding works it out rather than asking for it.
near(area(geo.difference([a, b], [square(-1, -1, 100)])), 0);
near(area(geo.intersection([a, b], [square(5, 5, 5)])), 25);

// `distance` composes onto a boolean, so growing a result is one call.
near(area(geo.union([a, b], { distance: 0 })), 175);
assert.ok(area(geo.union([a, b], { distance: 1 })) > 175);

// Buffer is n-ary, takes the longer form for non-areal input, and shrinks.
near(Math.round(area(geo.buffer({ points: [[0, 0]] }, 10))), 314);
assert.ok(
  area(
    geo.buffer(
      {
        lines: [
          [
            [0, 0],
            [100, 0],
          ],
        ],
      },
      5,
    ),
  ) > 1000,
);
assert.ok(area(geo.buffer([a], -2)) < 100);
assert.deepEqual(geo.buffer([a], -50), []);

// The generic form and the named one are the same call.
near(area(geo.apply(OP.union, [a, b])), area(geo.union([a, b])));
near(area(geo.apply(OP.difference, [a], [b])), area(geo.difference([a], [b])));

// A failure is an Error carrying the status text, not a silent wrong answer.
assert.throws(() => geo.buffer([a], 1, { steps: 0 }), /invalid options/);
assert.equal(STATUS[6], 'invalid options');

// The geometry helpers the examples lean on.
assert.deepEqual(
  close([
    [0, 0],
    [1, 0],
    [1, 1],
  ]).at(-1),
  [0, 0],
);
assert.equal(regular(0, 0, 1, 6).length, 7);
assert.equal(star(0, 0, 2, 1).length, 11);

geo.clear();
console.log('JS binding checks passed (five operations, both operand forms)');
