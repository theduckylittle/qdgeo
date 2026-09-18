// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
// Turning a qdgeo result into deck.gl's binary polygon format.
//
// This is the conversion the library's design is betting on: it hands back one
// coordinate array plus two index arrays, and a host that wants binary gets
// there without touching a single coordinate. The loops below run over rings
// and polygons — a few hundred iterations on a parcel union whose coordinate
// array holds tens of thousands of numbers.
//
// deck.gl wants:
//   length                how many polygons
//   startIndices          the vertex each polygon starts at, plus a final total
//   getPolygon            the flat positions, size 2
//   instanceVertexValid   1 everywhere except the last vertex of each ring
//
// The attribute is `instanceVertexValid`, as a `{ size, value }` pair holding a
// `Uint16Array` — not a bare `vertexValid`, which the published prose suggests
// and which the layer silently ignores. `GeoJsonLayer` builds the same
// structure in `geojson-layer-props.js`, and `SolidPolygonLayer` reads it at
// `props.data.attributes.instanceVertexValid.value`; that is the contract.

/** @param result {import('qdgeo').Result} */
export function toBinary(result) {
  const { coordinates, ringEnds, polygonEnds } = result;
  const vertices = coordinates.length / 2;

  // Where each polygon starts, in vertices. A polygon starts where its first
  // ring starts, which is where the previous polygon's last ring ended.
  const startIndices = new Uint32Array(polygonEnds.length + 1);
  for (let p = 0; p < polygonEnds.length; p++) {
    const firstRing = p === 0 ? 0 : polygonEnds[p - 1];
    startIndices[p] = firstRing === 0 ? 0 : ringEnds[firstRing - 1];
  }
  startIndices[polygonEnds.length] = vertices;

  // Every vertex is valid except the one closing each ring: that is how deck.gl
  // is told where a hole begins.
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
