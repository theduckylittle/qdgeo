// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// The Leaflet ring conversion the library ships as `qdgeo/leaflet`.
//
// Leaflet keeps rings open and qdgeo keeps them closed, and getting that wrong
// is silent in a browser: an extra point draws a zero-length segment, a missing
// one draws a polygon that looks almost right. So the round trip is asserted
// rather than eyeballed, and `examples/src/leaflet.js` imports exactly what is
// checked here.
import assert from 'node:assert/strict';

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

// Leaflet lives in the examples' dependencies, which CI installs before this
// runs; skip rather than fail without them.
const { existsSync } = await import('node:fs');
const leafletPath = '../examples/node_modules/leaflet/dist/leaflet-src.js';
if (!existsSync(new URL(leafletPath, import.meta.url))) {
  console.log('Leaflet ring checks skipped (Leaflet not installed)');
  process.exit(0);
}

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

// Out: Leaflet gets one point fewer per ring, and never the closing repeat.
const rings = shapeOut(shape);
assert.equal(rings.length, 2, 'shell and hole');
for (const [i, ring] of rings.entries()) {
  assert.equal(ring.length, shape[i].length - 1, 'the closing point is dropped');
  assert.notDeepEqual(
    [ring[0].lat, ring[0].lng],
    [ring.at(-1).lat, ring.at(-1).lng],
    'Leaflet rings must not repeat the first point',
  );
}

// And back: closed again, and the same coordinates to within the round trip
// through latitude and longitude.
const [back] = fromLeaflet(L.polygon(rings).getLatLngs(), project);
assert.equal(back.length, 2);
for (const [i, ring] of back.entries()) {
  assert.equal(ring.length, shape[i].length, 'the closing point is restored');
  assert.deepEqual(ring[0], ring.at(-1), 'and it is the first point again');
  for (const [j, [x, y]] of ring.entries()) {
    assert.ok(Math.abs(x - shape[i][j][0]) < 1e-6, `x ${x} drifted`);
    assert.ok(Math.abs(y - shape[i][j][1]) < 1e-6, `y ${y} drifted`);
  }
}

// `getLatLngs` nests one level deep for a polygon and two for a multipolygon,
// and `fromLeaflet` has to tell them apart to return an operand either way.
const multi = fromLeaflet(L.polygon([rings, shapeOut([box(300)])]).getLatLngs(), project);
assert.equal(multi.length, 2, 'a multipolygon is two shapes');
assert.equal(multi[0].length, 2, 'the first keeps its hole');
assert.equal(multi[1].length, 1);

// The whole path, as the demo runs it: Leaflet in, operation, Leaflet out.
const result = geo.union(fromLeaflet(L.polygon(rings).getLatLngs(), project), { distance: 0 });
assert.equal(result.length, 1);
assert.equal(result.ringEnds.length, 2, 'the hole survives');
const drawn = toLeaflet(result, unproject);
assert.equal(drawn.length, 1);
assert.equal(drawn[0].length, 2);
for (const ring of drawn[0]) {
  assert.notDeepEqual(
    [ring[0].lat, ring[0].lng],
    [ring.at(-1).lat, ring.at(-1).lng],
    'the result is handed to Leaflet open too',
  );
  assert.ok(ring.every((p) => p instanceof L.LatLng));
}

// And the projection is Leaflet's own, not a reimplementation of it.
const [x, y] = project(L.latLng(0, 0));
assert.ok(Math.abs(x) < 1e-9 && Math.abs(y) < 1e-9, 'the origin projects to the origin');
assert.ok(Math.abs(unproject(centre).lat - 52.370216) < 1e-9, 'and unprojects back');

console.log('Leaflet ring checks passed (open out, closed in, holes, and a full round trip)');
