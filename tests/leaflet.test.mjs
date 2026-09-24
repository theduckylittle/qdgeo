// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The Leaflet ring conversion the library ships as `qdgeo/leaflet`.
//
// Leaflet keeps rings open and qdgeo keeps them closed, and getting that wrong
// is silent in a browser: an extra point draws a zero-length segment, a missing
// one draws a polygon that looks almost right. So the round trip is asserted
// rather than eyeballed, and `examples/src/leaflet.js` imports exactly what is
// checked here.
import { existsSync } from 'node:fs';
import { describe, expect, test } from 'vitest';

// Leaflet lives in the examples' dependencies, which CI installs before this
// runs; skip rather than fail without them.
const leafletPath = '../examples/node_modules/leaflet/dist/leaflet-src.js';
const haveLeaflet = existsSync(new URL(leafletPath, import.meta.url));
// CI installs `examples/` before this runs, so a skip there means the workflow
// changed rather than that the adapter is genuinely untestable. Say so.
if (!haveLeaflet && process.env.CI)
  throw new Error('Leaflet is missing: CI must run `npm --prefix examples ci` before `npm test`');

// A skipped suite still has its body collected, so the whole thing — including
// importing Leaflet — has to sit behind the branch rather than behind `skipIf`.
if (!haveLeaflet) {
  describe.skip('Leaflet ring conversion (Leaflet is not installed)', () => {
    test('needs `npm --prefix examples ci`', () => {});
  });
} else {
  describe('Leaflet ring conversion', async () => {
    // Leaflet reads the browser's feature flags at import. It needs none of them
    // for `CRS` or `Polygon`, which are the only parts under test here.
    globalThis.window = globalThis;
    globalThis.screen = {};
    // Node defines `navigator` as a getter, so it has to be replaced rather than
    // assigned.
    Object.defineProperty(globalThis, 'navigator', {
      value: { userAgent: '', platform: '', maxTouchPoints: 0 },
      configurable: true,
    });
    globalThis.document = {
      documentElement: { style: {} },
      createElement: () => ({ style: {}, setAttribute() {}, appendChild() {} }),
    };

    const { default: L } = await import(leafletPath);
    const { load } = await import('../js/qdgeo.js');
    const { fromLeaflet, openRings, toLeaflet } = await import('../js/leaflet.js');

    // The adapter takes the projection rather than importing Leaflet, so this is
    // the pair a caller supplies.
    const project = (latLng) => {
      const { x, y } = L.CRS.EPSG3857.project(latLng);
      return [x, y];
    };
    const unproject = ([x, y]) => L.CRS.EPSG3857.unproject(L.point(x, y));
    const shapeOut = (shape) => openRings(shape, unproject);
    const geo = await load();

    // A square with a square hole, in Web Mercator metres near Amsterdam.
    const centre = project(L.latLng(52.370216, 4.895168));
    const box = (r) => {
      const [x, y] = centre;
      return [
        [x - r, y - r],
        [x + r, y - r],
        [x + r, y + r],
        [x - r, y + r],
        [x - r, y - r],
      ];
    };
    const shape = [box(1000), box(400).slice().reverse()];
    const rings = shapeOut(shape);

    test('out: Leaflet gets one point fewer per ring, and never the closing repeat', () => {
      expect(rings.length, 'shell and hole').toBe(2);
      for (const [i, ring] of rings.entries()) {
        expect(ring.length, 'the closing point is dropped').toBe(shape[i].length - 1);
        expect(
          [ring[0].lat, ring[0].lng],
          'Leaflet rings must not repeat the first point',
        ).not.toEqual([ring.at(-1).lat, ring.at(-1).lng]);
      }
    });

    test('and back: closed again, and the same coordinates through lat/lng', () => {
      const [back] = fromLeaflet(L.polygon(rings).getLatLngs(), project);
      expect(back.length).toBe(2);
      for (const [i, ring] of back.entries()) {
        expect(ring.length, 'the closing point is restored').toBe(shape[i].length);
        expect(ring[0], 'and it is the first point again').toEqual(ring.at(-1));
        for (const [j, [x, y]] of ring.entries()) {
          expect(Math.abs(x - shape[i][j][0]), `x ${x} drifted`).toBeLessThan(1e-6);
          expect(Math.abs(y - shape[i][j][1]), `y ${y} drifted`).toBeLessThan(1e-6);
        }
      }
    });

    // `getLatLngs` nests one level deep for a polygon and two for a multipolygon,
    // and `fromLeaflet` has to tell them apart to return an operand either way.
    test('a multipolygon is two shapes, and the first keeps its hole', () => {
      const multi = fromLeaflet(L.polygon([rings, shapeOut([box(300)])]).getLatLngs(), project);
      expect(multi.length, 'a multipolygon is two shapes').toBe(2);
      expect(multi[0].length, 'the first keeps its hole').toBe(2);
      expect(multi[1].length).toBe(1);
    });

    test('the whole path, as the demo runs it: Leaflet in, operation, Leaflet out', () => {
      const result = geo.union(fromLeaflet(L.polygon(rings).getLatLngs(), project), {
        distance: 0,
      });
      expect(result.length).toBe(1);
      expect(result.ringEnds.length, 'the hole survives').toBe(2);
      const drawn = toLeaflet(result, unproject);
      expect(drawn.length).toBe(1);
      expect(drawn[0].length).toBe(2);
      for (const ring of drawn[0]) {
        expect([ring[0].lat, ring[0].lng], 'the result is handed to Leaflet open too').not.toEqual([
          ring.at(-1).lat,
          ring.at(-1).lng,
        ]);
        expect(ring.every((p) => p instanceof L.LatLng)).toBe(true);
      }
    });

    test('and the projection is Leaflet’s own, not a reimplementation of it', () => {
      const [x, y] = project(L.latLng(0, 0));
      expect(Math.abs(x), 'the origin projects to the origin').toBeLessThan(1e-9);
      expect(Math.abs(y)).toBeLessThan(1e-9);
      expect(Math.abs(unproject(centre).lat - 52.370216), 'and unprojects back').toBeLessThan(1e-9);
    });
  });
}
