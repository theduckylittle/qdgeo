// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// deck.gl's binary polygon format, from a qdgeo result.
//
// Optional and separate from `qdgeo.js`: import it and you get these two
// functions, don't and nothing here reaches your bundle. It loads no WASM and
// depends on nothing, deck.gl included — it only builds plain typed arrays.
//
// This exists because deck.gl's binary contract is easy to get subtly wrong and
// the mistakes are silent: a wrong attribute name renders nothing, a wrong
// index renders a plausible but incorrect polygon. `tests/deck-binary.mjs`
// checks both functions against deck.gl's own tesselator.
//
// The conversion reads no coordinate. It walks rings and polygons — a few
// hundred iterations on a parcel union whose coordinate array holds tens of
// thousands of numbers — and hands the library's own positions straight over.

/**
 * A result as `SolidPolygonLayer` data. Pass `_normalize: false` alongside it,
 * which is what lets deck.gl skip its own reformatting.
 *
 * deck.gl wants `length` polygons, `startIndices` marking where each begins
 * (plus a final total), the flat positions as `getPolygon`, and
 * `instanceVertexValid`: 1 everywhere except the last vertex of each ring,
 * which is how it is told where a hole starts.
 *
 * The attribute is `instanceVertexValid`, as a `{ size, value }` pair holding a
 * `Uint16Array` — not a bare `vertexValid`, which the published prose suggests
 * and which the layer silently ignores. `GeoJsonLayer` builds the same
 * structure in `geojson-layer-props.js`; that is the contract.
 *
 * @param result {import('./qdgeo.js').Result}
 */
export function toBinary(result) {
  const { coordinates, ringEnds, polygonEnds } = result;
  const vertices = coordinates.length / 2;

  // A polygon starts where its first ring starts, which is where the previous
  // polygon's last ring ended.
  const startIndices = new Uint32Array(polygonEnds.length + 1);
  for (let p = 0; p < polygonEnds.length; p++) {
    const firstRing = p === 0 ? 0 : polygonEnds[p - 1];
    startIndices[p] = firstRing === 0 ? 0 : ringEnds[firstRing - 1];
  }
  startIndices[polygonEnds.length] = vertices;

  const vertexValid = new Uint16Array(vertices).fill(1);
  for (let r = 0; r < ringEnds.length; r++) vertexValid[ringEnds[r] - 1] = 0;

  return {
    length: polygonEnds.length,
    startIndices,
    attributes: {
      getPolygon: { value: coordinates, size: 2 },
      instanceVertexValid: { size: 1, value: vertexValid },
    },
  };
}

/**
 * The same result as ring outlines, as `PathLayer` data. Pass
 * `_pathType: 'open'` alongside it: the rings arrive closed, so every segment
 * including the last should be drawn as given.
 *
 * `SolidPolygonLayer` only fills, so a stroke is a second layer. One more index
 * array gets there — rings rather than polygons — over the same positions.
 *
 * @param result {import('./qdgeo.js').Result}
 */
export function toOutline(result) {
  const { coordinates, ringEnds } = result;
  const startIndices = new Uint32Array(ringEnds.length + 1);
  startIndices.set(ringEnds, 1);
  return {
    length: ringEnds.length,
    startIndices,
    attributes: { getPath: { value: coordinates, size: 2 } },
  };
}
