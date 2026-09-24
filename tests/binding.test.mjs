// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The JavaScript binding, exercised through its named methods.
//
// `wasm.test.mjs` covers the raw exports; this covers `js/qdgeo.js`, which is
// what a host actually calls. The two are separate on purpose: a rename in the
// ABI should break one of them loudly rather than both vaguely.
import { afterAll, describe, expect, test } from 'vitest';
import { load, OP, STATUS, close, Result } from '../js/qdgeo.js';
import { area, nestedArea } from './support/area.mjs';

const geo = await load();
afterAll(() => geo.clear());

const square = (x, y, w) => [
  [
    [x, y],
    [x + w, y],
    [x + w, y + w],
    [x, y + w],
    [x, y],
  ],
];
const a = square(0, 0, 10);
const b = square(5, 5, 10);

describe('the five operations', () => {
  test('union, intersection, difference, symmetric difference', () => {
    expect(area(geo.union([a, b]))).toBeCloseTo(175, 9);
    expect(area(geo.intersection([a], [b]))).toBeCloseTo(25, 9);
    expect(area(geo.difference([a], [b]))).toBeCloseTo(75, 9);
    expect(area(geo.symmetricDifference([a], [b]))).toBeCloseTo(150, 9);
  });

  // Either operand may hold several shapes. This is what the ABI's `subject`
  // split buys, and why the binding works it out rather than asking for it.
  test('either operand may hold several shapes', () => {
    expect(area(geo.difference([a, b], [square(-1, -1, 100)]))).toBeCloseTo(0, 9);
    expect(area(geo.intersection([a, b], [square(5, 5, 5)]))).toBeCloseTo(25, 9);
  });

  test('buffer is n-ary, takes the longer form for non-areal input, and shrinks', () => {
    expect(Math.round(area(geo.buffer({ points: [[0, 0]] }, 10)))).toBe(314);
    const stadium = geo.buffer(
      {
        lines: [
          [
            [0, 0],
            [100, 0],
          ],
        ],
      },
      5,
    );
    expect(area(stadium)).toBeGreaterThan(1000);
    expect(area(geo.buffer([a], -2))).toBeLessThan(100);
  });

  test('the generic form and the named one are the same call', () => {
    expect(area(geo.apply(OP.union, [a, b]))).toBeCloseTo(area(geo.union([a, b])), 9);
    expect(area(geo.apply(OP.difference, [a], [b]))).toBeCloseTo(area(geo.difference([a], [b])), 9);
  });

  test('`distance` composes onto a boolean, so growing a result is one call', () => {
    expect(area(geo.union([a, b], { distance: 0 }))).toBeCloseTo(175, 9);
    expect(area(geo.union([a, b], { distance: 1 }))).toBeGreaterThan(175);
  });

  test('a failure is an Error carrying the status text, not a silent wrong answer', () => {
    expect(() => geo.buffer([a], 1, { steps: 0 })).toThrow(/invalid options/);
    expect(STATUS[6]).toBe('invalid options');
  });
});

describe('the result', () => {
  test('is the layout the library produced, not a nested rebuild of it', () => {
    const out = geo.union([a, b]);
    expect(out).toBeInstanceOf(Result);
    expect(out.coordinates).toBeInstanceOf(Float64Array);
    expect(out.ringEnds).toBeInstanceOf(Uint32Array);
    expect(out.length).toBe(1);
    expect(out.ringEnds.length).toBe(1);
    expect(out.coordinates.length).toBe(2 * out.ringEnds[0]);
    expect(out.ring(0)).toEqual([0, out.ringEnds[0]]);
  });

  test('survives the next call, because it owns its arrays', () => {
    const out = geo.union([a, b]);
    const before = out.coordinates.slice();
    geo.buffer([a], 3);
    expect(out.coordinates).toEqual(before);
  });

  test('is still a Result when it collapses to nothing', () => {
    const empty = geo.buffer([a], -50);
    expect(empty.length).toBe(0);
    expect(empty.toArrays()).toEqual([]);
  });

  test('keeps polygon boundaries: two disjoint shapes stay two', () => {
    const disjoint = geo.union([square(0, 0, 5), square(100, 100, 5)]);
    expect(disjoint.length).toBe(2);
    expect(geo.union(disjoint).length).toBe(2);
    expect(area(geo.union(disjoint))).toBeCloseTo(50, 9);
  });

  test('agrees with the nested form it builds on demand', () => {
    const out = geo.union([a, b]);
    expect(nestedArea(out.toArrays())).toBeCloseTo(area(out), 9);
  });
});

describe('the input forms', () => {
  // A shape may arrive flat, which is what OpenLayers and deck.gl already hold.
  // Same answer, and no exploding coordinates into pairs first.
  const flatA = { coordinates: [0, 0, 10, 0, 10, 10, 0, 10, 0, 0], ringEnds: [5] };
  const flatB = { coordinates: [5, 5, 15, 5, 15, 15, 5, 15, 5, 5], ringEnds: [5] };

  test('a shape may arrive flat', () => {
    expect(area(geo.union([flatA, flatB]))).toBeCloseTo(175, 9);
    expect(area(geo.difference([flatA], [flatB]))).toBeCloseTo(75, 9);
  });

  test('and the two forms mix freely', () => {
    expect(area(geo.union([flatA, b]))).toBeCloseTo(175, 9);
  });

  test('`close` meets the API contract that every ring is closed', () => {
    // The shape generators the demos use are not the library's job and live in
    // examples/.
    expect(
      close([
        [0, 0],
        [1, 0],
        [1, 1],
      ]).at(-1),
    ).toEqual([0, 0]);
  });
});

// A result is a collection of shapes, so it goes straight back in as an
// operand. This is the whole reason it has the shape it has: what comes out is
// what goes in, and chaining costs two index loops rather than a rebuild.
describe('chaining', () => {
  const shapes = [a, b];

  test('a result goes straight back in as an operand', () => {
    const grown = geo.buffer(geo.union(shapes), { distance: 15 });
    expect(area(grown)).toBeGreaterThan(175);
    expect(area(geo.buffer(geo.union(shapes), 15))).toBeCloseTo(area(grown), 9);
  });

  test('on either side of a binary operation', () => {
    const united = geo.union(shapes);
    expect(area(geo.intersection([square(0, 0, 8)], united))).toBeCloseTo(64, 9);
    expect(area(geo.difference(united, [square(0, 0, 8)]))).toBeCloseTo(111, 9);
    expect(area(geo.union([united, square(50, 50, 4)]))).toBeCloseTo(175 + 16, 9);
  });

  test('and several deep', () => {
    const deep = geo.difference(geo.buffer(geo.union(shapes), 2), geo.union([square(0, 0, 3)]));
    expect(deep.length).toBeGreaterThanOrEqual(1);
  });
});
