// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The ceiling: how big an input each operation takes before the 512 MiB
// instance fails, and what it does when it does.
//
// Opt-in, through `npm run stress` or `QDGEO_STRESS=1 npm test -- tests/stress`,
// because the biggest steps hold a quarter of a gigabyte and the run takes
// tens of seconds, which is not what `npm test` is for.
//
// Each operation gets a parcel-like fabric (`support/fabric.mjs`) that doubles
// in coordinates every step, on a fresh instance every step so the peak is
// that one call's and not the sum, until the first failure. Three things are
// asserted at every step, and the first two are the ones that matter:
//
// - a result is exact: the fabric's answers are closed-form, so the area is
//   checked to 1e-9, which no wrong topology survives;
// - a failure is a status, never a trap, and only one of the three statuses a
//   valid input may produce: out of memory, over a declared limit, or a
//   crossing `f64` cannot hold;
// - the step the ceiling sits on, and the peak heap at the last step that
//   passed, match the recorded baseline below. Memory is deterministic, so a
//   change either way is a finding: higher is worth recording, lower is a
//   regression.
//
// The fabric is run at UTM magnitudes, where the parcels that motivated this
// live and where a crossing is most likely to be unrepresentable.
import { readFileSync } from 'node:fs';
import { afterAll, describe, expect, test } from 'vitest';
import { load, QdgeoError } from '../js/qdgeo.js';
import {
  areaAbout,
  bufferedArea,
  fabric,
  overlapArea,
  squareArea,
  translate,
} from './support/fabric.mjs';

const MiB = 1024 * 1024;
const origin = [500_000, 5_000_000];
const steps = 8;
const distance = 20;
const shift = [15, 15];

// Cells per side at each step, growing by the square root of two so the
// coordinate count doubles. The last entry is a guard, not an expectation.
const sides = [64, 91, 128, 181, 256, 362, 512];

// The ceiling is the last side that passed, and `peak` is its heap in MiB.
// Re-measure with `npm run stress` and update here when the engine or the
// fabric changes; the commit that moves a number says why.
const baseline = {
  union: { ceiling: 256, peak: 260.4 },
  buffer: { ceiling: 256, peak: 260.4 },
  erode: { ceiling: 256, peak: 260.5 },
  intersection: { ceiling: 128, peak: 291.9 },
  makeValid: { ceiling: 256, peak: 324.5 },
};

const clean = new Set(['OUT_OF_MEMORY', 'LIMIT_EXCEEDED', 'UNREPRESENTABLE']);

const operations = {
  union: (f) => [(geo) => geo.union(f.polygons), squareArea(f)],
  buffer: (f) => [
    (geo) => geo.buffer(f.polygons, distance, { steps }),
    bufferedArea(f, distance, steps),
  ],
  erode: (f) => [
    (geo) => geo.buffer(f.polygons, -distance, { steps }),
    bufferedArea(f, -distance, steps),
  ],
  intersection: (f) => [
    (geo) => geo.intersection(f.polygons, translate(f.polygons, shift)),
    overlapArea(f, shift),
  ],
  makeValid: (f) => [(geo) => geo.makeValid(f.polygons), squareArea(f)],
};

const rows = [];

describe.skipIf(!process.env.QDGEO_STRESS)('the ceiling', () => {
  for (const [name, make] of Object.entries(operations)) {
    test(name, { timeout: 600_000 }, async () => {
      // Compiled once; each step instantiates it again, which costs well
      // under a millisecond and starts from an empty heap.
      const module = await WebAssembly.compile(
        readFileSync(new URL('../js/qdgeo.wasm', import.meta.url)),
      );
      let ceiling = 0;
      let peak = 0;
      for (const n of sides) {
        const f = fabric({ n, origin });
        const [run, want] = make(f);
        const geo = await load(module);
        const started = performance.now();
        let result;
        let failure;
        try {
          result = run(geo);
        } catch (err) {
          failure = err;
        }
        const ms = performance.now() - started;
        const heap = geo.w.memory.buffer.byteLength / MiB;
        const row = {
          operation: name,
          side: n,
          cells: f.cells,
          coordinates: f.polygons.coordinates.length / 2,
          ms: Math.round(ms),
          peak: +heap.toFixed(1),
          outcome: failure ? (failure.code ?? failure.constructor.name) : 'exact',
        };
        rows.push(row);
        if (failure) {
          // A trap, a RangeError from the host, or a status a valid input
          // should never produce all fail here with the message.
          expect(
            failure,
            `${name} at ${row.coordinates} coordinates: ${failure.message}`,
          ).toBeInstanceOf(QdgeoError);
          expect(clean.has(failure.code), `${name} failed with ${failure.code}`).toBe(true);
          break;
        }
        const got = areaAbout(result, origin);
        expect(
          Math.abs(got - want) / want,
          `${name} at ${row.coordinates} coordinates`,
        ).toBeLessThan(1e-9);
        ceiling = n;
        peak = heap;
      }
      expect(ceiling, `${name}: the ceiling moved`).toBe(baseline[name].ceiling);
      expect(peak, `${name}: more heap at the ceiling`).toBeLessThanOrEqual(
        baseline[name].peak + 0.5,
      );
    });
  }

  afterAll(() => {
    const line = (r) =>
      `| ${r.operation.padEnd(12)} | ${String(r.side).padStart(4)} | ${String(r.cells).padStart(7)} | ${String(r.coordinates).padStart(9)} | ${String(r.ms).padStart(6)} | ${String(r.peak).padStart(6)} | ${r.outcome} |`;
    console.log(
      [
        '',
        '| operation    | side |   cells | coordinates |     ms |    MiB | outcome |',
        '| ------------ | ---: | ------: | ----------: | -----: | -----: | --- |',
        ...rows.map(line),
        '',
      ].join('\n'),
    );
  });
});
