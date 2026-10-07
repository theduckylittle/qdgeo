// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The JavaScript binding, exercised through its named methods.
//
// `wasm.test.mjs` covers the raw exports; this covers `js/qdgeo.js`, which is
// what a host actually calls. The two are separate on purpose: a rename in the
// ABI should break one of them loudly rather than both vaguely.
import { afterAll, describe, expect, test } from 'vitest';
import { load, OP, STATUS, QdgeoError, close, Result } from '../js/qdgeo.js';
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

  test('a failure is a QdgeoError carrying a named code, not a silent wrong answer', () => {
    expect(() => geo.buffer([a], 1, { steps: 0 })).toThrow(/INVALID_OPTIONS/);
    let caught;
    try {
      geo.buffer([a], 1, { steps: 0 });
    } catch (err) {
      caught = err;
    }
    // The code is the contract, and it is a name, never a bare number:
    // INVALID_GEOMETRY means fix your input, UNREPRESENTABLE means f64 could
    // not hold the arrangement, OUT_OF_MEMORY means try larger batches.
    expect(caught).toBeInstanceOf(QdgeoError);
    expect(caught).toBeInstanceOf(Error);
    expect(caught.code).toBe('INVALID_OPTIONS');
    // The map ties the module's numeric statuses to the names, so a host on
    // the raw ABI can translate; 5 and 7 are the split that matters.
    expect(STATUS[6]).toBe('INVALID_OPTIONS');
    expect(STATUS[5]).toBe('INVALID_GEOMETRY');
    expect(STATUS[7]).toBe('UNREPRESENTABLE');
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

describe('the predicates', () => {
  const a = square(0, 0, 10);
  const b = square(5, 5, 10);
  const far = square(30, 30, 10);
  const beside = square(10, 0, 10);
  const inner = square(2, 2, 6);

  test('relate is the DE-9IM matrix as JTS prints it, or a pattern match', () => {
    expect(geo.relate([a], [b])).toBe('212101212');
    expect(geo.relate([a], [far])).toBe('FF2FF1212');
    expect(geo.relate([a], [inner])).toBe('212FF1FF2');
    expect(geo.relate([a], [b], 'T*T***T**')).toBe(true);
    expect(geo.relate([a], [far], 'T********')).toBe(false);
    expect(() => geo.relate([a], [b], 'T*')).toThrow(QdgeoError);
    expect(() => geo.relate([a], [b], 'T*X******')).toThrow(QdgeoError);
    // The group extension: one of the marked cells must be non-empty.
    expect(geo.relate([a], [square(10, 0, 10)], 'AA*AA****')).toBe(true);
    expect(geo.relate([a], [square(10, 0, 10)], 'FA*AA****')).toBe(true);
    expect(geo.relate([a], [b], '*********')).toBe(true);
  });

  test('every named predicate, on the textbook pairs', () => {
    expect(geo.intersects([a], [b])).toBe(true);
    expect(geo.intersects([a], [far])).toBe(false);
    expect(geo.disjoint([a], [far])).toBe(true);
    expect(geo.contains([a], [inner])).toBe(true);
    expect(geo.within([inner], [a])).toBe(true);
    expect(geo.covers([a], [inner])).toBe(true);
    expect(geo.coveredBy([inner], [a])).toBe(true);
    expect(geo.touches([a], [beside])).toBe(true);
    expect(geo.touches([a], [b])).toBe(false);
    expect(geo.overlaps([a], [b])).toBe(true);
    expect(
      geo.crosses([a], {
        lines: [
          [
            [-5, 5],
            [15, 5],
          ],
        ],
      }),
    ).toBe(true);
    expect(geo.equals([a], [square(0, 0, 10)])).toBe(true);
    expect(geo.equals([a], [b])).toBe(false);
  });

  test('an operand list may mix points, lines and shapes, told apart by nesting', () => {
    // A point, a line and a polygon in one list; the polygon contains both.
    const mixed = [
      [2, 2],
      [
        [1, 1],
        [3, 3],
      ],
      inner,
    ];
    expect(geo.contains([a], mixed)).toBe(true);
    expect(geo.contains([a], [[11, 11]])).toBe(false);
    // The named form says the same thing.
    expect(geo.relate([a], mixed)).toBe(
      geo.relate([a], {
        points: [[2, 2]],
        lines: [
          [
            [1, 1],
            [3, 3],
          ],
        ],
        polygons: [inner],
      }),
    );
    // And a result is an operand here too.
    expect(geo.contains(geo.union([a, b]), [inner])).toBe(true);
  });

  test('a list is read as a union: a line along the seam of two squares is inside the pair', () => {
    const seam = {
      lines: [
        [
          [10, 2],
          [10, 8],
        ],
      ],
    };
    expect(geo.contains([a, beside], seam)).toBe(true);
    expect(geo.contains([a], seam)).toBe(false);
    expect(geo.covers([a], seam)).toBe(true);
  });

  test('a point in a polygon and a point on a line, the two cases with their own path', () => {
    // Inside, in a hole, outside, and on an edge — the edge goes back to the
    // full arrangement, and must give the same kind of answer.
    const donut = [
      square(0, 0, 10)[0],
      [
        [3, 3],
        [3, 7],
        [7, 7],
        [7, 3],
        [3, 3],
      ],
    ];
    expect(geo.contains([donut], [[1, 1]])).toBe(true);
    expect(geo.contains([donut], [[5, 5]])).toBe(false);
    expect(geo.contains([donut], [[11, 5]])).toBe(false);
    expect(geo.contains([donut], [[10, 5]])).toBe(false);
    expect(geo.covers([donut], [[10, 5]])).toBe(true);
    expect(geo.relate([donut], [[10, 5]])).toBe('FF20F1FF2');
    // A point on an edge two polygons share is inside their union.
    expect(geo.contains([a, square(10, 0, 10)], [[10, 5]])).toBe(true);
    // Along a line: in its interior, at a free end, and where two lines join.
    const path = {
      lines: [
        [
          [0, 0],
          [4, 4],
          [8, 0],
        ],
        [
          [8, 0],
          [12, 0],
        ],
      ],
    };
    expect(geo.relate({ points: [[2, 2]] }, path)).toBe('0FFFFF102');
    expect(geo.relate({ points: [[0, 0]] }, path)).toBe('F0FFFF102');
    expect(geo.relate({ points: [[8, 0]] }, path)).toBe('0FFFFF102');
    expect(geo.intersects({ points: [[2, 2.5]] }, path)).toBe(false);
    expect(geo.touches({ points: [[12, 0]] }, path)).toBe(true);
    expect(geo.within({ points: [[3, 3]] }, path)).toBe(true);
  });

  test('invalid input is rejected, the same as for an operation', () => {
    const flat = [
      [
        [0, 0],
        [5, 0],
        [10, 0],
        [0, 0],
      ],
    ];
    expect(() => geo.intersects([a], [flat])).toThrow(QdgeoError);
    expect(() =>
      geo.relate([a], {
        lines: [
          [
            [1, 1],
            [1, 1],
          ],
        ],
      }),
    ).toThrow(QdgeoError);
  });
});

describe('makeValid', () => {
  const bowtie = [
    [
      [0, 0],
      [10, 10],
      [10, 0],
      [0, 5],
      [0, 0],
    ],
  ];

  // The other operations read a self-crossing ring by its winding, the way
  // JSTS's `buffer(0)` does, and keep only the lobes that wind the same way
  // as the whole. Repairing first is what keeps the rest.
  test('a bowtie keeps both lobes, where the operations read only one', () => {
    expect(area(geo.makeValid([bowtie]))).toBeCloseTo(41.666666666666664, 9);
    expect(area(geo.union([bowtie]))).toBeCloseTo(33.333333333333336, 9);
    expect(geo.makeValid([bowtie]).length).toBe(2);
  });

  test('holes are cut where they meet the shell and kept where they do not', () => {
    const shell = square(0, 0, 10)[0];
    expect(area(geo.makeValid([[shell, square(2, 2, 4)[0]]]))).toBeCloseTo(84, 9);
    expect(area(geo.makeValid([[shell, square(20, 20, 2)[0]]]))).toBeCloseTo(104, 9);
  });

  // The binding passes rings through as given, so the repair sees exactly
  // what a digitizing tool produced.
  test('an open ring is closed and a vertex that is not a number is removed', () => {
    const open = [
      [
        [0, 0],
        [10, 0],
        [10, 10],
        [0, 10],
      ],
    ];
    expect(area(geo.makeValid([open]))).toBeCloseTo(100, 9);
    const hole = [
      [
        [0, 0],
        [10, 0],
        [NaN, 3],
        [10, 10],
        [0, 10],
        [0, 0],
      ],
    ];
    expect(area(geo.makeValid([hole]))).toBeCloseTo(100, 9);
  });

  test('a ring with no area left is dropped, not an error', () => {
    const line = [
      [
        [0, 0],
        [5, 0],
        [10, 0],
        [0, 0],
      ],
    ];
    expect(geo.makeValid([line]).length).toBe(0);
  });

  test('valid input comes back unchanged, and the result chains', () => {
    expect(geo.equals(geo.makeValid([a, b]), geo.union([a, b]))).toBe(true);
    expect(area(geo.difference(geo.makeValid([bowtie]), [square(0, 0, 5)]))).toBeGreaterThan(0);
    expect(area(geo.makeValid([bowtie], { distance: 1 }))).toBeGreaterThan(41.67);
    expect(area(geo.apply(OP.makeValid, [bowtie]))).toBeCloseTo(41.666666666666664, 9);
  });
});
