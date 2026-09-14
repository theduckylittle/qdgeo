// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// Run after `zig build wasm`: node tests/wasm.mjs
//
// The browser artifact carries the flat ABI and nothing else. WKB is native
// only; `tests/compare/run.py` covers it there.
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const module_ = new WebAssembly.Module(await readFile('zig-out/bin/qdgeo.wasm'));
// Freestanding and import-free: no WASI, no host functions, no shims.
assert.deepEqual(WebAssembly.Module.imports(module_), []);
const w = new WebAssembly.Instance(module_, {}).exports;

// The shape OpenLayers hands over: one flat coordinate array plus ring and
// polygon ends, and the shape Shapely's `to_ragged_array` returns.
function flat(
  { coordinates, ringEnds = [], polygonEnds = [], lineStringEnds = [], points = 0 },
  operation,
) {
  const n = coordinates.length / 2;
  const ptr = w.geom_flat_input(
    n,
    ringEnds.length,
    polygonEnds.length,
    lineStringEnds.length,
    points,
  );
  assert.notEqual(ptr, 0);
  // One bulk copy each, no per-coordinate work.
  new Float64Array(w.memory.buffer, ptr, coordinates.length).set(coordinates);
  const indices = new Uint32Array(
    w.memory.buffer,
    ptr + 16 * n,
    ringEnds.length + polygonEnds.length + lineStringEnds.length,
  );
  indices.set(ringEnds);
  indices.set(polygonEnds, ringEnds.length);
  indices.set(lineStringEnds, ringEnds.length + polygonEnds.length);
  assert.equal(operation(), 0);
  // An operation can grow memory, so every view is rebuilt afterwards.
  const out = w.geom_flat_result_ptr();
  const nc = w.geom_flat_result_coordinates();
  const nr = w.geom_flat_result_rings();
  const np = w.geom_flat_result_polygons();
  const ends = new Uint32Array(w.memory.buffer, out + 16 * nc, nr + np);
  return {
    coordinates: new Float64Array(w.memory.buffer, out, 2 * nc).slice(),
    ringEnds: Array.from(ends.slice(0, nr)),
    polygonEnds: Array.from(ends.slice(nr)),
  };
}
function area({ coordinates, ringEnds }) {
  let sum = 0,
    start = 0;
  for (const end of ringEnds) {
    for (let i = start; i < end - 1; i++)
      sum +=
        (coordinates[2 * i] * coordinates[2 * i + 3] -
          coordinates[2 * i + 2] * coordinates[2 * i + 1]) /
        2;
    start = end;
  }
  return sum;
}
const OP = { union: 0, intersection: 1, difference: 2, symmetricDifference: 3, buffer: 4 };
const square = (x0, y0, x1, y1) => [x0, y0, x1, y0, x1, y1, x0, y1, x0, y0];

// Two overlapping squares as one MultiPolygon: two polygons, one ring each.
const united = flat(
  {
    coordinates: [...square(0, 0, 2, 2), ...square(1, 1, 3, 3)],
    ringEnds: [5, 10],
    polygonEnds: [1, 2],
  },
  () => w.geom_flat_execute(OP.union, 0, 0, 0),
);
assert.equal(area(united), 7);
assert.equal(united.polygonEnds.length, 1);

// A Point buffers to a disc, an open LineString to a stadium.
const disc = flat({ coordinates: [7, -3], points: 1 }, () =>
  w.geom_flat_execute(OP.buffer, 0, 10, 16),
);
assert.ok(Math.abs(area(disc) - Math.PI * 100) < Math.PI);
const stadium = flat({ coordinates: [0, 0, 100, 0], lineStringEnds: [2] }, () =>
  w.geom_flat_execute(OP.buffer, 0, 10, 16),
);
assert.ok(Math.abs(area(stadium) - (2000 + Math.PI * 100)) < 25);

// A polygon keeps its hole, shell first.
const donut = flat(
  {
    coordinates: [...square(0, 0, 10, 10), ...square(3, 7, 7, 3)],
    ringEnds: [5, 10],
    polygonEnds: [2],
  },
  () => w.geom_flat_execute(OP.union, 0, 0, 0),
);
assert.equal(donut.ringEnds.length, 2);
assert.equal(area(donut), 84);

// Repeated calls reuse the input block and must not leak state.
for (let i = 0; i < 20; i++) {
  assert.equal(
    area(
      flat({ coordinates: square(0, 0, 2, 2), ringEnds: [5], polygonEnds: [1] }, () =>
        w.geom_flat_execute(OP.buffer, 0, -3, 16),
      ),
    ),
    0,
  );
}
w.geom_clear();
// The four boolean rules, over two overlapping squares split into operands.
const pair = {
  coordinates: [...square(0, 0, 2, 2), ...square(1, 1, 3, 3)],
  ringEnds: [5, 10],
  polygonEnds: [1, 2],
};
for (const [op, expected] of [
  [OP.union, 7],
  [OP.intersection, 1],
  [OP.difference, 3],
  [OP.symmetricDifference, 6],
]) {
  assert.equal(area(flat(pair, () => w.geom_flat_execute(op, 1, 0, 0))), expected);
}
// A nonzero distance buffers the result of a boolean operation, so a host gets
// "intersect, then grow" in one crossing. The intersection is the unit square
// (1, 1)-(2, 2); growing it by 1 adds its perimeter and four quarter-circles.
const grown = area(flat(pair, () => w.geom_flat_execute(OP.intersection, 1, 1, 16)));
assert.ok(
  Math.abs(grown - (1 + 4 + Math.PI)) < 0.02,
  `intersection buffered by 1 should be about ${(1 + 4 + Math.PI).toFixed(3)}, got ${grown}`,
);
// Zero leaves a boolean result exactly as it was.
assert.equal(area(flat(pair, () => w.geom_flat_execute(OP.union, 1, 0, 16))), 7);
// A negative distance erodes the result rather than growing it.
const eroded = area(flat(pair, () => w.geom_flat_execute(OP.union, 1, -0.25, 16)));
assert.ok(eroded > 0 && eroded < 7, `union eroded by 0.25 should shrink, got ${eroded}`);

// Difference is asymmetric: giving both squares to the subject leaves nothing to cut.
assert.equal(area(flat(pair, () => w.geom_flat_execute(OP.difference, 2, 0, 0))), 7);
assert.equal(w.geom_flat_execute(9, 0, 0, 0), 6);
w.geom_clear();
console.log('WASM runtime checks passed (flat ABI, four boolean ops, no imports)');
