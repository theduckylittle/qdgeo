// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
import { Map as MapLibreMap, Marker } from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { load } from 'qdgeo';
import { regular, star } from '../lib/shapes.js';

const geo = await load('./qdgeo.wasm');
const out = document.getElementById('out');

// Web Mercator, so buffer distances are in metres rather than degrees. Doing
// the geometry in a projected space and converting at the edge is the normal
// pattern: the library is planar and reads no CRS.
const R = 6378137;
const toMercator = ([lon, lat]) => [
  (R * lon * Math.PI) / 180,
  R * Math.log(Math.tan(Math.PI / 4 + (lat * Math.PI) / 360)),
];
const toLonLat = ([x, y]) => [
  (x / R) * (180 / Math.PI),
  (2 * Math.atan(Math.exp(y / R)) - Math.PI / 2) * (180 / Math.PI),
];

const feature = (polygons) => ({
  type: 'Feature',
  properties: {},
  geometry: {
    type: 'MultiPolygon',
    coordinates: polygons.map((p) => p.map((r) => r.map(toLonLat))),
  },
});
const collection = (features) => ({ type: 'FeatureCollection', features });

const origin = toMercator([4.895168, 52.370216]);
const offsets = [
  [0, 0],
  [0, 0],
];
const build = () => [
  [star(origin[0] - 700 + offsets[0][0], origin[1] + offsets[0][1], 1500, 620)],
  [regular(origin[0] + 900 + offsets[1][0], origin[1] + 200 + offsets[1][1], 1200, 6)],
];

// The style is inline rather than a URL, so `load` fires and the geometry works
// even with no network at all. The raster source is a nicety; if the tiles fail
// the background layer still gives the shapes something to sit on.
const map = new MapLibreMap({
  container: 'map',
  style: {
    version: 8,
    sources: {
      osm: {
        type: 'raster',
        tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
        tileSize: 256,
        attribution: '&copy; OpenStreetMap contributors',
      },
    },
    layers: [
      { id: 'background', type: 'background', paint: { 'background-color': '#e8e4dc' } },
      { id: 'osm', type: 'raster', source: 'osm', paint: { 'raster-opacity': 0.55 } },
    ],
  },
  center: toLonLat(origin),
  zoom: 11,
});

// One draggable marker per shape, which keeps the example free of any editing
// interaction code.
const handles = [];
map.on('load', () => {
  map.addSource('operands', { type: 'geojson', data: collection([]) });
  map.addSource('result', { type: 'geojson', data: collection([]) });
  map.addLayer({
    id: 'operands-fill',
    type: 'fill',
    source: 'operands',
    paint: { 'fill-color': '#3b6ea5', 'fill-opacity': 0.15 },
  });
  map.addLayer({
    id: 'operands-line',
    type: 'line',
    source: 'operands',
    paint: { 'line-color': '#3b6ea5', 'line-width': 1.5 },
  });
  map.addLayer({
    id: 'result-fill',
    type: 'fill',
    source: 'result',
    paint: { 'fill-color': '#2f6f4f', 'fill-opacity': 0.28 },
  });
  map.addLayer({
    id: 'result-line',
    type: 'line',
    source: 'result',
    paint: { 'line-color': '#2f6f4f', 'line-width': 3 },
  });

  const starts = [
    toLonLat([origin[0] - 700, origin[1]]),
    toLonLat([origin[0] + 900, origin[1] + 200]),
  ];
  starts.forEach((position, i) => {
    const marker = new Marker({ draggable: true, color: i ? '#b5651d' : '#3b6ea5' })
      .setLngLat(position)
      .addTo(map);
    marker.on('drag', () => {
      const moved = toMercator(marker.getLngLat().toArray());
      const home = toMercator(starts[i]);
      offsets[i] = [moved[0] - home[0], moved[1] - home[1]];
      update();
    });
    handles.push(marker);
  });
  update();
});

const op = () => document.querySelector('input[name=op]:checked').value;

function update() {
  if (!map.getSource('result')) return;
  const distance = Number(document.getElementById('distance').value);
  const buffering = op() === 'buffer';
  const [a, b] = build();
  map
    .getSource('operands')
    .setData(collection(buffering ? [feature([a])] : [feature([a]), feature([b])]));
  try {
    let result;
    // Each operation has its own method; the switch is the whole of what the
    // op selector means.
    switch (op()) {
      case 'buffer':
        result = geo.buffer([a], distance);
        break;
      case 'union':
        result = geo.union([a, b], { distance });
        break;
      case 'intersection':
        result = geo.intersection([a], [b], { distance });
        break;
      case 'difference':
        result = geo.difference([a], [b], { distance });
        break;
      case 'symmetricDifference':
        result = geo.symmetricDifference([a], [b], { distance });
        break;
    }
    // MapLibre wants GeoJSON, so this is the host that genuinely needs the
    // nested form — and `toArrays()` is where that cost is paid, visibly, by
    // the one demo that cannot avoid it.
    map.getSource('result').setData(collection(result.length ? [feature(result.toArrays())] : []));
    const rings = result.ringEnds.length;
    const points = result.coordinates.length / 2;
    out.innerHTML =
      `<b>${result.length}</b> polygon${result.length === 1 ? '' : 's'}, ` +
      `<b>${rings}</b> ring${rings === 1 ? '' : 's'}, <b>${points}</b> coordinates.` +
      (distance === 0
        ? ''
        : buffering
          ? ` Distance <b>${distance} m</b>${distance < 0 ? ' (shrinking)' : ''}.`
          : ` Then ${distance < 0 ? 'shrunk' : 'grown'} by <b>${Math.abs(distance)} m</b>.`);
  } catch (error) {
    map.getSource('result').setData(collection([]));
    out.innerHTML = `<span class="err">${error.message}</span>`;
  }
}

document.getElementById('distance').addEventListener('input', (event) => {
  document.getElementById('distance-value').textContent = `${event.target.value} m`;
  update();
});
for (const radio of document.querySelectorAll('input[name=op]')) {
  radio.addEventListener('change', () => {
    update();
  });
}
