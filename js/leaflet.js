// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// Leaflet's rings, from and to a qdgeo result.
//
// Optional and separate from `qdgeo.js`, and it imports Leaflet no more than it
// imports the WASM: the projection is passed in, so these are plain array
// walks. Use `L.CRS.EPSG3857.project` and `.unproject` for Web Mercator metres,
// or any other pair — the library reads no coordinate system.
//
// This exists for one reason. Leaflet's rings are **open**: its documentation
// is explicit that the first point should not be repeated, and qdgeo's rings
// are always closed. Getting that wrong is silent in a browser — an extra point
// draws a zero-length segment, a missing one draws a polygon that looks almost
// right — so `tests/leaflet.test.mjs` round-trips both directions.

/**
 * One shape's rings, open, as Leaflet's constructors want them.
 *
 * @param rings closed rings of `[x, y]`, shell first
 * @param unproject maps `[x, y]` to whatever Leaflet should receive
 */
export const openRings = (rings, unproject) =>
  rings.map((ring) => ring.slice(0, -1).map(unproject));

/**
 * A whole result, as Leaflet's `[[shell, ...holes], ...]`.
 *
 * @param result {import('./qdgeo.js').Result}
 * @param unproject maps `[x, y]` to whatever Leaflet should receive
 */
export const toLeaflet = (result, unproject) =>
  result.toArrays().map((rings) => openRings(rings, unproject));

/**
 * And back: an operand, with every ring closed again.
 *
 * Pass what `getLatLngs()` returns. It nests one level deep for a polygon and
 * two for a multipolygon, and the only way to tell them apart is to look — so
 * this returns a list of shapes either way, which is what an operation takes.
 *
 * @param latLngs what `L.Polygon.getLatLngs()` returned
 * @param project maps one of those points to `[x, y]`
 */
export function fromLeaflet(latLngs, project) {
  const shapes = Array.isArray(latLngs[0]?.[0]) ? latLngs : [latLngs];
  return shapes.map((shape) =>
    shape.map((ring) => {
      const closed = ring.map(project);
      closed.push(closed[0]);
      return closed;
    }),
  );
}
