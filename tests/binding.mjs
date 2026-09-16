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
const { load, OP, STATUS, close, Result } = await import('../js/qdgeo.js');
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
const area = (result) =>
  result.toArrays().reduce(
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

// The generic form and the named one are the same call.
near(area(geo.apply(OP.union, [a, b])), area(geo.union([a, b])));
near(area(geo.apply(OP.difference, [a], [b])), area(geo.difference([a], [b])));

// A failure is an Error carrying the status text, not a silent wrong answer.
assert.throws(() => geo.buffer([a], 1, { steps: 0 }), /invalid options/);
assert.equal(STATUS[6], 'invalid options');

// `close` meets the API's contract that every ring is closed. The shape
// generators the demos use are not the library's job and live in examples/.
assert.deepEqual(
  close([
    [0, 0],
    [1, 0],
    [1, 1],
  ]).at(-1),
  [0, 0],
);

// The result is the layout the library produced, not a nested rebuild of it.
const out = geo.union([a, b]);
assert.ok(out instanceof Result);
assert.ok(out.coordinates instanceof Float64Array);
assert.ok(out.ringEnds instanceof Uint32Array);
assert.equal(out.length, 1);
assert.equal(out.ringEnds.length, 1);
assert.equal(out.coordinates.length, 2 * out.ringEnds[0]);
assert.deepEqual(out.ring(0), [0, out.ringEnds[0]]);

// It survives the next call, because it owns its arrays rather than viewing
// the module's block.
const before = out.coordinates.slice();
geo.buffer([a], 3);
assert.deepEqual(out.coordinates, before);

// A shape may arrive flat, which is what OpenLayers and deck.gl already hold.
// Same answer, and no exploding coordinates into pairs first.
const flatA = { coordinates: [0, 0, 10, 0, 10, 10, 0, 10, 0, 0], ringEnds: [5] };
const flatB = { coordinates: [5, 5, 15, 5, 15, 15, 5, 15, 5, 5], ringEnds: [5] };
near(area(geo.union([flatA, flatB])), 175);
near(area(geo.difference([flatA], [flatB])), 75);
near(area(geo.union([flatA, b])), 175); // the two forms mix freely

// A result that collapses to nothing is still a Result.
const empty = geo.buffer([a], -50);
assert.equal(empty.length, 0);
assert.deepEqual(empty.toArrays(), []);

geo.clear();
console.log('JS binding checks passed (five operations, flat and nested input)');
