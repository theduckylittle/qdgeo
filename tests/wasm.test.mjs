// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//
// The raw exports of the browser artifact, with no binding in the way.
//
// `binding.test.mjs` covers `js/qdgeo.js`, which is what a host actually calls.
// The two are separate on purpose: a rename in the ABI should break one of them
// loudly rather than both vaguely.
//
// The artifact carries the coordinate ABI and nothing else. WKB is native only;
// `tests/compare/run.py` covers it there.
import { readFile } from 'node:fs/promises';
import { describe, expect, test } from 'vitest';
import { area } from './support/area.mjs';

const module_ = new WebAssembly.Module(await readFile('zig-out/bin/qdgeo.wasm'));
const w = new WebAssembly.Instance(module_, {}).exports;

// The shape OpenLayers hands over: one flat coordinate array plus ring and
// polygon ends, and the shape Shapely's `to_ragged_array` returns.
function flat(
  { coordinates, ringEnds = [], polygonEnds = [], lineStringEnds = [], points = 0 },
  operation,
) {
  const n = coordinates.length / 2;
  const ptr = w.geom_input(n, ringEnds.length, polygonEnds.length, lineStringEnds.length, points);
  expect(ptr).not.toBe(0);
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
  expect(operation()).toBe(0);
  // An operation can grow memory, so every view is rebuilt afterwards.
  const out = w.geom_result_ptr();
  const nc = w.geom_result_coordinates();
  const nr = w.geom_result_rings();
  const np = w.geom_result_polygons();
  const ends = new Uint32Array(w.memory.buffer, out + 16 * nc, nr + np);
  return {
    coordinates: new Float64Array(w.memory.buffer, out, 2 * nc).slice(),
    ringEnds: Array.from(ends.slice(0, nr)),
    polygonEnds: Array.from(ends.slice(nr)),
  };
}

const OP = { union: 0, intersection: 1, difference: 2, symmetricDifference: 3, buffer: 4 };
const square = (x0, y0, x1, y1) => [x0, y0, x1, y0, x1, y1, x0, y1, x0, y0];

// Two overlapping squares as one MultiPolygon: two polygons, one ring each.
const pair = {
  coordinates: [...square(0, 0, 2, 2), ...square(1, 1, 3, 3)],
  ringEnds: [5, 10],
  polygonEnds: [1, 2],
};

describe('the module itself', () => {
  test('is freestanding and import-free: no WASI, no host functions, no shims', () => {
    expect(WebAssembly.Module.imports(module_)).toEqual([]);
  });

  test('reports an unknown operation as a status rather than trapping', () => {
    expect(w.geom_apply(9, 0, 0, 0)).toBe(6);
  });
});

describe('the coordinate ABI', () => {
  test('unions two overlapping squares into one polygon', () => {
    const united = flat(pair, () => w.geom_apply(OP.union, 0, 0, 0));
    expect(area(united)).toBe(7);
    expect(united.polygonEnds.length).toBe(1);
  });

  test('buffers a bare point to a disc', () => {
    const disc = flat({ coordinates: [7, -3], points: 1 }, () =>
      w.geom_apply(OP.buffer, 0, 10, 16),
    );
    // A 16-step quarter circle is a chord approximation, so it is inscribed:
    // within one sagitta's worth of area of the true disc.
    expect(Math.abs(area(disc) - Math.PI * 100)).toBeLessThan(Math.PI);
  });

  test('buffers an open line to a stadium', () => {
    const stadium = flat({ coordinates: [0, 0, 100, 0], lineStringEnds: [2] }, () =>
      w.geom_apply(OP.buffer, 0, 10, 16),
    );
    expect(Math.abs(area(stadium) - (2000 + Math.PI * 100))).toBeLessThan(25);
  });

  test('keeps a hole, shell first', () => {
    const donut = flat(
      {
        coordinates: [...square(0, 0, 10, 10), ...square(3, 7, 7, 3)],
        ringEnds: [5, 10],
        polygonEnds: [2],
      },
      () => w.geom_apply(OP.union, 0, 0, 0),
    );
    expect(donut.ringEnds.length).toBe(2);
    expect(area(donut)).toBe(84);
  });

  test('reuses the input block across calls without leaking state', () => {
    for (let i = 0; i < 20; i++) {
      const eroded = flat(
        { coordinates: square(0, 0, 2, 2), ringEnds: [5], polygonEnds: [1] },
        () => w.geom_apply(OP.buffer, 0, -3, 16),
      );
      expect(area(eroded)).toBe(0);
    }
    w.geom_clear();
  });
});

describe('the four boolean rules, over two overlapping squares split into operands', () => {
  test.for([
    ['union', OP.union, 7],
    ['intersection', OP.intersection, 1],
    ['difference', OP.difference, 3],
    ['symmetric difference', OP.symmetricDifference, 6],
  ])('%s', ([, op, expected]) => {
    expect(area(flat(pair, () => w.geom_apply(op, 1, 0, 0)))).toBe(expected);
  });

  test('difference is asymmetric: both squares as the subject leaves nothing to cut', () => {
    expect(area(flat(pair, () => w.geom_apply(OP.difference, 2, 0, 0)))).toBe(7);
  });
});

describe('a distance composed onto a boolean', () => {
  // Doing it inside the module is what lets a host get "intersect, then grow"
  // in one crossing rather than two.
  test('grows the result: the unit square (1,1)-(2,2) plus its perimeter and four quarter circles', () => {
    const grown = area(flat(pair, () => w.geom_apply(OP.intersection, 1, 1, 16)));
    expect(Math.abs(grown - (1 + 4 + Math.PI))).toBeLessThan(0.02);
  });

  test('leaves a boolean result exactly as it was when zero', () => {
    expect(area(flat(pair, () => w.geom_apply(OP.union, 1, 0, 16)))).toBe(7);
  });

  test('erodes rather than grows when negative', () => {
    const eroded = area(flat(pair, () => w.geom_apply(OP.union, 1, -0.25, 16)));
    expect(eroded).toBeGreaterThan(0);
    expect(eroded).toBeLessThan(7);
  });
});

describe('inputs the ABI has to refuse rather than trap on', () => {
  // Counts come from the page and are u32, while `usize` is 32 bits on wasm32,
  // so 16 * coordinates overflows above 268,435,455. That used to trap the
  // module; it is now refused the same way an allocation failure is.
  test.for([
    ['16 * coordinates overflows', [268435457, 1, 1, 0, 0]],
    ['the index counts overflow between them', [0, 3000000000, 2000000000, 0, 0]],
    ['everything at the maximum', [4294967295, 4294967295, 4294967295, 4294967295, 0]],
  ])('%s', ([, counts]) => {
    expect(w.geom_input(...counts)).toBe(0);
  });

  test('and the module is still usable afterwards', () => {
    expect(area(flat(pair, () => w.geom_apply(OP.union, 1, 0, 0)))).toBe(7);
    w.geom_clear();
  });

  // An allocation the 512 MiB heap cannot satisfy has to come back as a status
  // code, not a trap, and the module has to keep working afterwards. Both are
  // claims the ABI makes; neither was exercised until now.
  //
  // A ring of 999,999 points is just inside `max_segments` and buffering it asks
  // for far more than the cap allows, so the request is refused outright rather
  // than the heap filling gradually — which makes this fast and deterministic.
  // 400,000 points fits today at 493 MiB, so do not lower the size to speed it
  // up. If this ever returns 0, the overlay got cheaper: raise the size rather
  // than deleting the test, because the property being checked is that a refused
  // allocation is *recoverable*, not that this input is too big.
  test('an allocation the heap cannot satisfy is a status, and the next call still works', () => {
    const n = 999999;
    const ring = new Float64Array(2 * n);
    for (let i = 0; i < n; i++) {
      const a = (2 * Math.PI * i) / n;
      ring[2 * i] = Math.cos(a) * 1e6;
      ring[2 * i + 1] = Math.sin(a) * 1e6;
    }
    ring[2 * (n - 1)] = ring[0];
    ring[2 * (n - 1) + 1] = ring[1];
    const ptr = w.geom_input(n, 1, 1, 0, 0);
    expect(ptr, 'the input block itself should still be accepted').not.toBe(0);
    new Float64Array(w.memory.buffer, ptr, 2 * n).set(ring);
    new Uint32Array(w.memory.buffer, ptr + 16 * n, 2).set([n, 1]);

    // A trap throws out of the call; status 1 is the recoverable answer.
    let status;
    expect(() => {
      status = w.geom_apply(OP.buffer, 1, 5000, 16);
    }, 'exhaustion trapped instead of returning a status').not.toThrow();
    expect(status, 'expected the allocation-failure status').toBe(1);
    w.geom_clear();

    // The whole point of status 1: the next call still works.
    expect(area(flat(pair, () => w.geom_apply(OP.union, 1, 0, 0)))).toBe(7);
    w.geom_clear();
  });
});
